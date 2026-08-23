import Foundation

enum WhisperVariant {
    case whisperCpp
    case openaiWhisper
    case whisperKit
    case groq
    case deepInfra
    case fireworks
    case fal
    case replicate
}

/// Whisper transcription engine - supports multiple backends
final class WhisperEngine {
    private let config: WhisperConfig
    /// Ordered fallback chain: tried in sequence until one succeeds.
    private var providers: [WhisperVariant] = []
    private var whisperPath: String?
    private var groqApiKey: String?
    private var deepInfraToken: String?
    private var fireworksToken: String?
    private var falToken: String?
    private var replicateToken: String?

    enum WhisperError: Error, LocalizedError {
        case binaryNotFound
        case transcriptionFailed(String)
        /// Auth/billing/bad-request failures — retrying cannot fix these, so the
        /// chain skips straight to the next provider.
        case permanentFailure(String)
        case invalidAudioFile
        case apiKeyMissing

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "No whisper binary found. Install with: brew install openai-whisper"
            case .transcriptionFailed(let message):
                return "Transcription failed: \(message)"
            case .permanentFailure(let message):
                return "Transcription failed (not retryable): \(message)"
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
        let env = ProcessInfo.processInfo.environment
        groqApiKey = config.groqApiKey ?? env["GROQ_API_KEY"]
        deepInfraToken = config.deepInfraApiKey ?? env["DEEPINFRA_API_KEY"] ?? env["DEEPINFRA_TOKEN"]
        fireworksToken = config.fireworksApiKey ?? env["FIREWORKS_API_KEY"]
        falToken = config.falApiKey ?? env["FAL_KEY"] ?? env["FAL_API_KEY"]
        replicateToken = config.replicateApiToken ?? env["REPLICATE_API_TOKEN"]

        // Build an ordered fallback chain. Cloud providers (fast) come first,
        // local whisper is always appended last so transcription still works
        // when the network or the API is down.
        switch config.backend {
        case .auto:
            // Preference order by cost/speed; each link is skipped if no key.
            if groqApiKey != nil { providers.append(.groq) }
            if deepInfraToken != nil { providers.append(.deepInfra) }
            if fireworksToken != nil { providers.append(.fireworks) }
            if replicateToken != nil { providers.append(.replicate) }
            if falToken != nil { providers.append(.fal) }
            detectLocalWhisperBinary()

        case .groq:
            appendCloudOrWarn(.groq, present: groqApiKey != nil, envHint: "GROQ_API_KEY")
        case .deepinfra:
            appendCloudOrWarn(.deepInfra, present: deepInfraToken != nil, envHint: "DEEPINFRA_API_KEY")
        case .fireworks:
            appendCloudOrWarn(.fireworks, present: fireworksToken != nil, envHint: "FIREWORKS_API_KEY")
        case .fal:
            appendCloudOrWarn(.fal, present: falToken != nil, envHint: "FAL_KEY")
        case .replicate:
            appendCloudOrWarn(.replicate, present: replicateToken != nil, envHint: "REPLICATE_API_TOKEN")

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

    /// Cloud variants hit the network, so they get retried with backoff.
    private func isCloudVariant(_ variant: WhisperVariant) -> Bool {
        switch variant {
        case .groq, .deepInfra, .fireworks, .fal, .replicate:
            return true
        case .openaiWhisper, .whisperCpp, .whisperKit:
            return false
        }
    }

    /// For an explicit cloud backend: use it if credentialed, otherwise warn,
    /// then always append local whisper as the safety net.
    private func appendCloudOrWarn(_ variant: WhisperVariant, present: Bool, envHint: String) {
        if present {
            providers.append(variant)
        } else {
            fputs("\(variant) selected but no credential found (set \(envHint)), using local whisper\n", stderr)
        }
        detectLocalWhisperBinary()
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

        let cloud = providers.filter { isCloudVariant($0) }
        let local = providers.filter { !isCloudVariant($0) }

        // Race only when there are actually two lanes to race.
        if config.raceLocal && !cloud.isEmpty && !local.isEmpty {
            race(audioURL: audioURL, cloud: cloud, local: local,
                 maxRetries: maxRetries, completion: completion)
            return
        }

        walk(providers, audioURL: audioURL, maxRetries: maxRetries, completion: completion)
    }

    /// Cloud and local at the same time; first success wins, and the loser is
    /// left to finish into the void rather than being killed mid-write.
    ///
    /// Local whisper is ~10x slower than groq, so on a healthy network the
    /// cloud always wins and this costs only CPU. It earns its keep when the
    /// network is slow or gone — the case where waiting is worst.
    private func race(audioURL: URL, cloud: [WhisperVariant], local: [WhisperVariant],
                      maxRetries: Int, completion: @escaping (Result<String, Error>) -> Void) {
        let gate = DispatchQueue(label: "yapless.transcribe.race")
        var settled = false
        var firstError: Error?
        var finished = 0

        func report(_ lane: String, _ result: Result<String, Error>) {
            gate.async {
                guard !settled else {
                    if case .success = result {
                        fputs("[race] \(lane) finished too, discarded\n", stderr)
                    }
                    return
                }
                finished += 1

                switch result {
                case .success(let text):
                    settled = true
                    fputs("[race] \(lane) won\n", stderr)
                    completion(.success(text))
                case .failure(let error):
                    fputs("[race] \(lane) lost: \(error.localizedDescription)\n", stderr)
                    if firstError == nil { firstError = error }
                    // Only give up once BOTH lanes are out.
                    if finished == 2 {
                        settled = true
                        completion(.failure(firstError ?? error))
                    }
                }
            }
        }

        fputs("[race] cloud \(cloud) vs local \(local)\n", stderr)
        walk(cloud, audioURL: audioURL, maxRetries: maxRetries) { report("cloud", $0) }
        walk(local, audioURL: audioURL, maxRetries: 1) { report("local", $0) }
    }

    private func walk(_ chain: [WhisperVariant], audioURL: URL, maxRetries: Int,
                      completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            var lastError: Error?
            let delays = [0.0, 1.0, 2.0, 4.0]

            // Walk the fallback chain. Groq gets retried (transient network/API
            // errors); local backends are deterministic, so we try them once
            // before moving on.
            for variant in chain {
                let isCloud = self.isCloudVariant(variant)
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
                        case .deepInfra:
                            text = try self.transcribeWithDeepInfra(audioPath: audioURL.path)
                        case .fireworks:
                            text = try self.transcribeWithFireworks(audioPath: audioURL.path)
                        case .fal:
                            text = try self.transcribeWithFal(audioPath: audioURL.path)
                        case .replicate:
                            text = try self.transcribeWithReplicate(audioPath: audioURL.path)
                        default:
                            text = try self.transcribeLocally(variant: variant, audioPath: audioURL.path)
                        }
                        // An empty transcript is a failure, not a result. Local
                        // backends already throw here; cloud ones can return
                        // 200 with {"text": ""}, and in a race that empty string
                        // would settle first and discard a lane that heard words.
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            throw WhisperError.transcriptionFailed("\(variant) returned an empty transcript")
                        }
                        fputs("Transcribed via \(variant)\n", stderr)
                        completion(.success(text))
                        return
                    } catch {
                        lastError = error
                        fputs("[\(variant)] attempt \(attempt + 1) failed: \(error.localizedDescription)\n", stderr)

                        if case WhisperError.permanentFailure = error {
                            fputs("[\(variant)] not retryable, skipping remaining attempts\n", stderr)
                            break
                        }
                    }
                }

                if chain.count > 1 {
                    fputs("[\(variant)] exhausted, falling back to next provider...\n", stderr)
                }
            }

            completion(.failure(lastError ?? WhisperError.transcriptionFailed("All providers exhausted")))
        }
    }

    // MARK: - OpenAI-compatible APIs (Groq, DeepInfra)

    private func transcribeWithGroq(audioPath: String) throws -> String {
        guard let apiKey = groqApiKey else { throw WhisperError.apiKeyMissing }
        return try transcribeOpenAICompatible(
            audioPath: audioPath,
            endpoint: "https://api.groq.com/openai/v1/audio/transcriptions",
            apiKey: apiKey,
            model: "whisper-large-v3"
        )
    }

    private func transcribeWithDeepInfra(audioPath: String) throws -> String {
        guard let apiKey = deepInfraToken else { throw WhisperError.apiKeyMissing }
        // ~40-80x cheaper than OpenAI/Deepgram. Using large-v3 (not turbo) for accuracy.
        return try transcribeOpenAICompatible(
            audioPath: audioPath,
            endpoint: "https://api.deepinfra.com/v1/openai/audio/transcriptions",
            apiKey: apiKey,
            model: "openai/whisper-large-v3"
        )
    }

    private func transcribeWithFireworks(audioPath: String) throws -> String {
        guard let apiKey = fireworksToken else { throw WhisperError.apiKeyMissing }
        // OpenAI-compatible ASR. whisper-v3 (large), not the turbo variant.
        return try transcribeOpenAICompatible(
            audioPath: audioPath,
            endpoint: "https://audio-prod.us-virginia-1.direct.fireworks.ai/v1/audio/transcriptions",
            apiKey: apiKey,
            model: "whisper-v3"
        )
    }

    /// Shared multipart transcription for OpenAI-compatible `/audio/transcriptions`
    /// endpoints. Groq and DeepInfra differ only by base URL, key, and model name.
    /// Whisper's initial prompt: a sentence of context the decoder conditions on.
    /// Listing hard words there is how you teach it "cotal", not "coastal".
    private var initialPrompt: String? {
        let vocabulary = config.vocabulary.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let parts = [config.prompt, vocabulary.isEmpty ? nil : vocabulary.joined(separator: ", ")]
        let joined = parts.compactMap { $0 }.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    private func transcribeOpenAICompatible(audioPath: String, endpoint: String, apiKey: String, model: String) throws -> String {
        let audioData = try Data(contentsOf: URL(fileURLWithPath: audioPath))
        let boundary = UUID().uuidString

        var request = URLRequest(url: URL(string: endpoint)!)
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

        // Add model
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(model)\r\n".data(using: .utf8)!)

        // Add language if specified
        if let language = config.language {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(language)\r\n".data(using: .utf8)!)
        }

        if let prompt = initialPrompt {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(prompt)\r\n".data(using: .utf8)!)
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
        var httpStatus = 0
        let semaphore = DispatchSemaphore(value: 0)

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error = error { requestError = error; return }
            httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data = data else {
                requestError = WhisperError.transcriptionFailed("No data from Replicate (HTTP \(httpStatus))")
                return
            }
            if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                json = parsed
            } else {
                let body = String(data: data, encoding: .utf8) ?? "Unknown response"
                requestError = WhisperError.transcriptionFailed("HTTP \(httpStatus): \(body)")
            }
        }
        task.resume()
        semaphore.wait()

        if let error = requestError { throw error }
        guard let json = json else {
            throw WhisperError.transcriptionFailed("Empty Replicate response (HTTP \(httpStatus))")
        }

        // Any non-2xx is an API error, not a prediction. Replicate's error bodies
        // carry `status` as an Int http code (e.g. 402 insufficient credit), which
        // looks just like a prediction's `status` string — so key off HTTP, not
        // the payload shape, or the real reason gets swallowed and resurfaces
        // later as a bogus "missing poll URL".
        if httpStatus >= 400 {
            let title = json["title"] as? String
            let detail = json["detail"] as? String
            let joined = [title, detail].compactMap { $0 }.joined(separator: ": ")
            let message = joined.isEmpty ? "Replicate HTTP \(httpStatus)" : "HTTP \(httpStatus) — \(joined)"

            // 401/402/403/404/422 stay broken until the account changes; only
            // rate limits and server errors are worth a retry.
            if [401, 402, 403, 404, 422].contains(httpStatus) {
                throw WhisperError.permanentFailure(message)
            }
            throw WhisperError.transcriptionFailed(message)
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

    // MARK: - fal.ai Wizper

    /// Wizper is fal's Whisper-v3-large. Synchronous `fal.run` endpoint: send the
    /// audio inline as a base64 data URI, get `{ text, chunks }` back directly.
    private func transcribeWithFal(audioPath: String) throws -> String {
        guard let token = falToken else { throw WhisperError.apiKeyMissing }

        let audioData = try Data(contentsOf: URL(fileURLWithPath: audioPath))
        let mime = mimeType(forPath: audioPath)
        let dataURI = "data:\(mime);base64,\(audioData.base64EncodedString())"

        var input: [String: Any] = [
            "audio_url": dataURI,
            "task": "transcribe",
            "version": "3"  // all Wizper versions are whisper-large
        ]
        if let language = config.language {
            input["language"] = language
        }
        let body = try JSONSerialization.data(withJSONObject: input)

        var request = URLRequest(url: URL(string: "https://fal.run/fal-ai/wizper")!)
        request.httpMethod = "POST"
        request.setValue("Key \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 180

        var result: String?
        var requestError: Error?
        let semaphore = DispatchSemaphore(value: 0)

        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            defer { semaphore.signal() }
            if let error = error { requestError = error; return }
            guard let data = data else {
                requestError = WhisperError.transcriptionFailed("No data from fal")
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let body = String(data: data, encoding: .utf8) ?? "Unknown response"
                requestError = WhisperError.transcriptionFailed(body)
                return
            }
            if let text = json["text"] as? String {
                result = text
            } else if let detail = json["detail"] as? String {
                requestError = WhisperError.transcriptionFailed(detail)
            } else {
                requestError = WhisperError.transcriptionFailed("Unexpected fal response: \(json)")
            }
        }
        task.resume()
        semaphore.wait()

        if let error = requestError { throw error }
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
            ]
            + (config.language.map { ["--language", $0] } ?? [])
            + (initialPrompt.map { ["--initial_prompt", $0] } ?? [])

        case .whisperCpp:
            let modelPath = findWhisperCppModel()
            arguments = [
                "-m", modelPath,
                "-f", audioPath,
                "--output-txt",
                "--no-timestamps"
            ]
            + (config.language.map { ["-l", $0] } ?? [])
            + (initialPrompt.map { ["--prompt", $0] } ?? [])

        case .whisperKit:
            arguments = [
                "transcribe",
                "--audio-path", audioPath,
                "--model-prefix", "openai",
                "--model", config.model
            ] + (config.language.map { ["--language", $0] } ?? [])

        case .groq, .deepInfra, .fireworks, .fal, .replicate:
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

        // openai-whisper and whisper-cpp write the transcript to a FILE. If that
        // file is missing the run failed — openai-whisper exits 0 even when it
        // could not decode the audio ("Skipping foo.wav due to RuntimeError:
        // Failed to load audio: dyld…"), and that message goes to stdout. The
        // old code fell through and returned stdout as the transcript, so a
        // failed run got pasted — or piped onward — as if it were speech.
        let diagnostics = { () -> String in
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(data: errorData, encoding: .utf8) ?? ""
            return [output, stderrText]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " | ")
        }

        if let txtPath = transcriptFilePath(for: variant, audioPath: audioPath) {
            guard FileManager.default.fileExists(atPath: txtPath) else {
                throw WhisperError.transcriptionFailed(
                    "\(variant) produced no transcript file (exit \(process.terminationStatus)): \(diagnostics())"
                )
            }
            let text = try String(contentsOfFile: txtPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.removeItem(atPath: txtPath)

            guard !text.isEmpty else {
                throw WhisperError.transcriptionFailed("\(variant) returned an empty transcript")
            }
            return text
        }

        // whisperKit prints to stdout; nothing there means nothing was heard.
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw WhisperError.transcriptionFailed(
                "\(variant) returned no transcript: \(diagnostics())"
            )
        }
        return text
    }

    /// Where this backend writes its transcript, or nil if it prints to stdout.
    private func transcriptFilePath(for variant: WhisperVariant, audioPath: String) -> String? {
        switch variant {
        case .openaiWhisper:
            let baseName = ((audioPath as NSString).lastPathComponent as NSString).deletingPathExtension
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("\(baseName).txt").path
        case .whisperCpp:
            return audioPath + ".txt"
        default:
            return nil
        }
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
