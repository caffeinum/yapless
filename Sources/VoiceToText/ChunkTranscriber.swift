import Foundation

final class ChunkTranscriber {
    private let whisperConfig: WhisperConfig
    private let draftURL: URL
    private var pendingChunks: [(URL, Int)] = []
    private var isProcessing = false
    private let queue = DispatchQueue(label: "chunk-transcriber", qos: .utility)
    private var transcribedChunks: [Int: String] = [:]

    init(whisperConfig: WhisperConfig, timestamp: String) {
        self.whisperConfig = whisperConfig

        let fm = FileManager.default
        try? fm.createDirectory(at: StorageConfig.draftsDirectory, withIntermediateDirectories: true)

        self.draftURL = StorageConfig.draftsDirectory.appendingPathComponent("draft-\(timestamp).txt")
        try? "".write(to: draftURL, atomically: true, encoding: .utf8)
    }

    func enqueue(chunkURL: URL, index: Int) {
        queue.async { [weak self] in
            self?.pendingChunks.append((chunkURL, index))
            self?.processNext()
        }
    }

    private func processNext() {
        guard !isProcessing, !pendingChunks.isEmpty else { return }

        isProcessing = true
        let (chunkURL, index) = pendingChunks.removeFirst()

        transcribeChunk(at: chunkURL, index: index) { [weak self] result in
            self?.queue.async {
                if let text = result {
                    self?.transcribedChunks[index] = text
                    self?.writeDraft()
                }

                try? FileManager.default.removeItem(at: chunkURL)

                self?.isProcessing = false
                self?.processNext()
            }
        }
    }

    private func transcribeChunk(at url: URL, index: Int, completion: @escaping (String?) -> Void) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            completion(nil)
            return
        }

        if let apiKey = whisperConfig.groqApiKey ?? ProcessInfo.processInfo.environment["GROQ_API_KEY"] {
            transcribeWithGroq(audioPath: url.path, apiKey: apiKey, timeout: 10.0, completion: completion)
        } else {
            completion(nil)
        }
    }

    private func transcribeWithGroq(audioPath: String, apiKey: String, timeout: TimeInterval, completion: @escaping (String?) -> Void) {
        guard let audioData = try? Data(contentsOf: URL(fileURLWithPath: audioPath)) else {
            completion(nil)
            return
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"chunk.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("whisper-large-v3-turbo\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            guard error == nil,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else {
                completion(nil)
                return
            }
            completion(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        task.resume()
    }

    private func writeDraft() {
        let sortedChunks = transcribedChunks.sorted { $0.key < $1.key }
        let fullText = sortedChunks.map { $0.value }.joined(separator: " ")
        try? fullText.write(to: draftURL, atomically: true, encoding: .utf8)
        print("Draft updated: \(fullText.prefix(50))...")
    }

    func getDraftText() -> String? {
        try? String(contentsOf: draftURL, encoding: .utf8)
    }

    func stop() {
        queue.sync {
            for (url, _) in pendingChunks {
                try? FileManager.default.removeItem(at: url)
            }
            pendingChunks.removeAll()
        }
    }
}
