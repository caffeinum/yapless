import Foundation

enum WhisperVariant {
    case whisperCpp
    case openaiWhisper
    case whisperKit
    case groq
}

/// Whisper transcription engine - supports multiple backends
final class WhisperEngine {
    private let config: WhisperConfig
    private var detectedVariant: WhisperVariant?
    private var whisperPath: String?
    private var groqApiKey: String?

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
        // Check for Groq API key first
        groqApiKey = config.groqApiKey ?? ProcessInfo.processInfo.environment["GROQ_API_KEY"]

        switch config.backend {
        case .groq:
            if groqApiKey != nil {
                detectedVariant = .groq
                print("Using Groq API for transcription")
                return
            }
            print("Groq API key not found, falling back to local")
            fallthrough

        case .auto:
            // Prefer Groq if API key available (fastest)
            if groqApiKey != nil {
                detectedVariant = .groq
                print("Using Groq API for transcription (auto-detected)")
                return
            }
            // Fall through to local detection
            fallthrough

        case .local, .openai:
            detectLocalWhisperBinary()
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
                self.detectedVariant = variant
                print("Using local whisper: \(variant) at \(path)")
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
                    self.detectedVariant = variant
                    print("Using local whisper: \(variant) at \(fullPath)")
                    return
                }
            }
        }
    }

    func transcribe(audioURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            completion(.failure(WhisperError.invalidAudioFile))
            return
        }

        guard let variant = detectedVariant else {
            completion(.failure(WhisperError.binaryNotFound))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                let text: String
                if variant == .groq {
                    text = try self.transcribeWithGroq(audioPath: audioURL.path)
                } else {
                    text = try self.transcribeLocally(variant: variant, audioPath: audioURL.path)
                }
                completion(.success(text))
            } catch {
                completion(.failure(error))
            }
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

        case .groq:
            fatalError("Should use transcribeWithGroq")
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
