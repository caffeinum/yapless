import Foundation

enum WhisperVariant {
    case whisperCpp
    case openaiWhisper
    case whisperKit
    case groq
    case replicate
}

/// Whisper transcription engine - supports multiple backends
final class WhisperEngine {
    private let config: WhisperConfig
    /// Ordered fallback chain: tried in sequence until one succeeds.
    private var providers: [WhisperVariant] = []
    private var whisperPath: String?
    private var groqApiKey: String?
    private var replicateToken: String?

    enum WhisperError: Error, LocalizedError {
        case binaryNotFound
        case transcriptionFailed(String)
        case invalidAudioFile
        case apiKeyMissing

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "No whisper binary found. Install with: brew install openai-whisper"
            case .transcriptionFailed(let message):
                return "Transcription failed: \(message)"
            case .invalidAudioFile:
                return "Invalid audio file"
            case .apiKeyMissing:
                return "Groq API key not found. Set GROQ_API_KEY env var or add to config"
            }
        }
    }

    init(config: WhisperConfig) {
        self.config = config
        detectBackend()
    }

    private func detectBackend() {
        // Resolve cloud credentials (config takes precedence over env).
        groqApiKey = config.groqApiKey ?? ProcessInfo.processInfo.environment["GROQ_API_KEY"]
        replicateToken = config.replicateApiToken ?? ProcessInfo.processInfo.environment["REPLICATE_API_TOKEN"]

        // Build an ordered fallback chain. Cloud providers (fast) come first,
        // local whisper is always appended last so transcription still works
        // when the network or the API is down.
        switch config.backend {
        case .auto:
            if groqApiKey != nil { providers.append(.groq) }
            if replicateToken != nil { providers.append(.replicate) }
            detectLocalWhisperBinary()

        case .groq:
            if groqApiKey != nil {
                providers.append(.groq)
            } else {
                fputs("Groq API key not found, using local whisper\n", stderr)
            }
            detectLocalWhisperBinary()

        case .replicate:
            if replicateToken != nil {
                providers.append(.replicate)
            } else {
                fputs("Replicate token not found (set REPLICATE_API_TOKEN), using local whisper\n", stderr)
            }
            detectLocalWhisperBinary()

        case .local, .openai:
            // OpenAI API isn't wired up yet; treat as local-only.
            detectLocalWhisperBinary()
        }

        if providers.isEmpty {
            fputs("No transcription backend available (no Groq key, no local whisper binary)\n", stderr)
        } else {
            fputs("Transcription chain: \(providers.map { "\($0)" }.joined(separator: " → "))\n", stderr)
        }
    }

    private func detectLocalWhisperBinary() {
        let candidates: [(String, WhisperVariant)] = [
            ("/opt/homebrew/bin/whisper", .openaiWhisper),
            ("/usr/local/bin/whisper", .openaiWhisper),
            ("/opt/homebrew/bin/whisper-cpp", .whisperCpp),
            ("/usr/local/bin/whisper-cpp", .whisperCpp),
            ("/opt/homebrew/bin/whisperkit-cli", .whisperKit),
            ("/usr/local/bin/whisperkit-cli", .whisperKit),
        ]

        for (path, variant) in candidates {
            if FileManager.default.fileExists(atPath: path) {
                self.whisperPath = path
                self.providers.append(variant)
                fputs("Found local whisper: \(variant) at \(path)\n", stderr)
                return
            }
        }

        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let pathDirs = pathEnv.split(separator: ":").map(String.init)

        let searchOrder: [(String, WhisperVariant)] = [
            ("whisper", .openaiWhisper),
            ("whisper-cpp", .whisperCpp),
            ("whisperkit-cli", .whisperKit),
        ]

        for dir in pathDirs {
            for (name, variant) in searchOrder {
                let fullPath = "\(dir)/\(name)"
                if FileManager.default.fileExists(atPath: fullPath) {
                    self.whisperPath = fullPath
                    self.providers.append(variant)
                    fputs("Found local whisper: \(variant) at \(fullPath)\n", stderr)
                    return
                }
            }
        }
    }

    func transcribe(audioURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
        transcribe(audioURL: audioURL, maxRetries: 3, completion: completion)
    }

    func transcribe(audioURL: URL, maxRetries: Int, completion: @escaping (Result<String, Error>) -> Void) {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            completion(.failure(WhisperError.invalidAudioFile))
            return
        }

        guard !providers.isEmpty else {
            completion(.failure(WhisperError.binaryNotFound))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            var lastError: Error?
            let delays = [0.0, 1.0, 2.0, 4.0]

            // Walk the fallback chain. Groq gets retried (transient network/API
            // errors); local backends are deterministic, so we try them once
            // before moving on.
            for variant in self.providers {
                let isCloud = (variant == .groq || variant == .replicate)
                let attempts = isCloud ? maxRetries : 1

                for attempt in 0..<attempts {
                    if attempt > 0 {
                        fputs("Retry attempt \(attempt) after \(delays[attempt])s...\n", stderr)
                        Thread.sleep(forTimeInterval: delays[attempt])
                    }

                    do {
                        let text: String
                        switch variant {
                        case .groq:
                            text = try self.transcribeWithGroq(audioPath: audioURL.path)
                        case .replicate:
                            text = try self.transcribeWithReplicate(audioPath: audioURL.path)
                        default:
                            text = try self.transcribeLocally(variant: variant, audioPath: audioURL.path)
                        }
                        completion(.success(text))
                        return
                    } catch {
                        lastError = error
                        fputs("[\(variant)] attempt \(attempt + 1) failed: \(error.localizedDescription)\n", stderr)
                    }
                }

                if self.providers.count > 1 {
                    fputs("[\(variant)] exhausted, falling back to next provider...\n", stderr)
                }
            }

            completion(.failure(lastError ?? WhisperError.transcriptionFailed("All providers exhausted")))
        }
    }

    // MARK: - Groq API

    private func transcribeWithGroq(audioPath: String) throws -> String {
        guard let apiKey = groqApiKey else {
            throw WhisperError.apiKeyMissing
        }

        let audioData = try Data(contentsOf: URL(fileURLWithPath: audioPath))
        let boundary = UUID().uuidString

        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // Add file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        // Add model (groq whisper-large-v3 for best accuracy)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("whisper-large-v3\r\n".data(using: .utf8)!)

        // Add language if specified
        if let language = config.language {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(language)\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        var result: String?
        var requestError: Error?
        let semaphore = DispatchSemaphore(value: 0)

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error = error {
                requestError = error
                return
            }

            guard let data = data else {
                requestError = WhisperError.transcriptionFailed("No data received")
                return
            }

            // Parse response
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["text"] as? String {
                result = text
            } else if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let error = errorJson["error"] as? [String: Any],
                      let message = error["message"] as? String {
                requestError = WhisperError.transcriptionFailed(message)
            } else {
                let responseStr = String(data: data, encoding: .utf8) ?? "Unknown response"
                requestError = WhisperError.transcriptionFailed(responseStr)
            }
        }
        task.resume()
        semaphore.wait()

        if let error = requestError {
            throw error
        }

        return result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - Replicate API

    /// incredibly-fast-whisper on Replicate. Uploads the audio inline as a
    /// base64 data URI, creates a prediction, then polls until it completes.
    private func transcribeWithReplicate(audioPath: String) throws -> String {
        guard let token = replicateToken else {
            throw WhisperError.apiKeyMissing
        }

        // Pinned version of vaibhavs10/incredibly-fast-whisper.
        let version = "3ab86df6c8f54c11309d4d1f930ac292bad43ace52d10c80d87eb258b3c9f79c"

        let audioData = try Data(contentsOf: URL(fileURLWithPath: audioPath))
        let mime = mimeType(forPath: audioPath)
        let dataURI = "data:\(mime);base64,\(audioData.base64EncodedString())"

        var input: [String: Any] = [
            "audio": dataURI,
            "task": "transcribe",
            "timestamp": "chunk",
            "batch_size": 64,
            "diarise_audio": false
        ]
        if let language = config.language {
            input["language"] = language
        }

        let createBody = try JSONSerialization.data(withJSONObject: [
            "version": version,
            "input": input
        ])

        // Create the prediction.
        var createReq = URLRequest(url: URL(string: "https://api.replicate.com/v1/predictions")!)
        createReq.httpMethod = "POST"
        createReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        createReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        createReq.httpBody = createBody

        var prediction = try replicateRequest(createReq)

        // Poll until the prediction reaches a terminal state.
        let terminal: Set<String> = ["succeeded", "failed", "canceled"]
        var status = prediction["status"] as? String ?? "starting"
        var polls = 0
        let maxPolls = 120  // ~3 min at 1.5s

        while !terminal.contains(status) {
            if polls >= maxPolls {
                throw WhisperError.transcriptionFailed("Replicate prediction timed out")
            }
            Thread.sleep(forTimeInterval: 1.5)
            polls += 1

            guard let urls = prediction["urls"] as? [String: Any],
                  let getURL = urls["get"] as? String,
                  let url = URL(string: getURL) else {
                throw WhisperError.transcriptionFailed("Replicate response missing poll URL")
            }
            var pollReq = URLRequest(url: url)
            pollReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            prediction = try replicateRequest(pollReq)
            status = prediction["status"] as? String ?? status
        }

        guard status == "succeeded" else {
            let detail = prediction["error"] as? String ?? status
            throw WhisperError.transcriptionFailed("Replicate \(status): \(detail)")
        }

        return try parseReplicateOutput(prediction["output"])
    }

    /// Run a Replicate request synchronously and decode the JSON body.
    private func replicateRequest(_ request: URLRequest) throws -> [String: Any] {
        var json: [String: Any]?
        var requestError: Error?
        let semaphore = DispatchSemaphore(value: 0)

        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            defer { semaphore.signal() }
            if let error = error { requestError = error; return }
            guard let data = data else {
                requestError = WhisperError.transcriptionFailed("No data from Replicate")
                return
            }
            if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                json = parsed
            } else {
                let body = String(data: data, encoding: .utf8) ?? "Unknown response"
                requestError = WhisperError.transcriptionFailed(body)
            }
        }
        task.resume()
        semaphore.wait()

        if let error = requestError { throw error }
        guard let json = json else {
            throw WhisperError.transcriptionFailed("Empty Replicate response")
        }
        // Surface API-level errors (e.g. invalid token, bad version).
        if let detail = json["detail"] as? String, json["status"] == nil, json["output"] == nil {
            throw WhisperError.transcriptionFailed(detail)
        }
        return json
    }

    /// incredibly-fast-whisper returns `{ text, chunks }`; tolerate string/array too.
    private func parseReplicateOutput(_ output: Any?) throws -> String {
        if let text = output as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let dict = output as? [String: Any], let text = dict["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let array = output as? [String] {
            return array.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw WhisperError.transcriptionFailed("Unexpected Replicate output format")
    }

    private func mimeType(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "ogg": return "audio/ogg"
        default: return "audio/wav"
        }
    }

    // MARK: - Local Transcription

    private func transcribeLocally(variant: WhisperVariant, audioPath: String) throws -> String {
        guard let whisperPath = whisperPath else {
            throw WhisperError.binaryNotFound
        }

        let arguments: [String]

        switch variant {
        case .openaiWhisper:
            let outputDir = FileManager.default.temporaryDirectory.path
            arguments = [
                audioPath,
                "--model", config.model,
                "--output_format", "txt",
                "--output_dir", outputDir
            ] + (config.language.map { ["--language", $0] } ?? [])

        case .whisperCpp:
            let modelPath = findWhisperCppModel()
            arguments = [
                "-m", modelPath,
                "-f", audioPath,
                "--output-txt",
                "--no-timestamps"
            ] + (config.language.map { ["-l", $0] } ?? [])

        case .whisperKit:
            arguments = [
                "transcribe",
                "--audio-path", audioPath,
                "--model-prefix", "openai",
                "--model", config.model
            ] + (config.language.map { ["--language", $0] } ?? [])

        case .groq, .replicate:
            fatalError("Cloud variant routed to transcribeLocally")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw WhisperError.transcriptionFailed(errorMessage)
        }

        // For openai-whisper, read the output txt file
        if variant == .openaiWhisper {
            let audioFilename = (audioPath as NSString).lastPathComponent
            let baseName = (audioFilename as NSString).deletingPathExtension
            let txtPath = FileManager.default.temporaryDirectory.appendingPathComponent("\(baseName).txt").path

            if FileManager.default.fileExists(atPath: txtPath) {
                let text = try String(contentsOfFile: txtPath, encoding: .utf8)
                try? FileManager.default.removeItem(atPath: txtPath)
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // For whisper.cpp, check for generated txt file
        if variant == .whisperCpp {
            let txtPath = audioPath + ".txt"
            if FileManager.default.fileExists(atPath: txtPath) {
                let text = try String(contentsOfFile: txtPath, encoding: .utf8)
                try? FileManager.default.removeItem(atPath: txtPath)
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func findWhisperCppModel() -> String {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let modelName = "ggml-\(config.model).bin"

        let possiblePaths = [
            homeDir.appendingPathComponent(".local/share/whisper/\(modelName)").path,
            homeDir.appendingPathComponent(".cache/whisper/\(modelName)").path,
            "/usr/local/share/whisper/\(modelName)",
            "/opt/homebrew/share/whisper/\(modelName)"
        ]

        return possiblePaths.first {
            FileManager.default.fileExists(atPath: $0)
        } ?? possiblePaths[0]
    }
}
