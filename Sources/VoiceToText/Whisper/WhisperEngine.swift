import Foundation

/// Whisper transcription engine using whisper.cpp
final class WhisperEngine {
    private let config: WhisperConfig
    private let modelPath: String

    enum WhisperError: Error, LocalizedError {
        case modelNotFound(String)
        case transcriptionFailed(String)
        case invalidAudioFile

        var errorDescription: String? {
            switch self {
            case .modelNotFound(let path):
                return "Whisper model not found at: \(path)"
            case .transcriptionFailed(let message):
                return "Transcription failed: \(message)"
            case .invalidAudioFile:
                return "Invalid audio file"
            }
        }
    }

    init(config: WhisperConfig) {
        self.config = config

        // Determine model path
        if let customPath = config.modelPath {
            self.modelPath = customPath
        } else {
            // Default model locations
            let homeDir = FileManager.default.homeDirectoryForCurrentUser
            let modelName = "ggml-\(config.model).bin"

            // Check common locations
            let possiblePaths = [
                homeDir.appendingPathComponent(".local/share/whisper/\(modelName)").path,
                homeDir.appendingPathComponent(".cache/whisper/\(modelName)").path,
                "/usr/local/share/whisper/\(modelName)",
                "/opt/homebrew/share/whisper/\(modelName)"
            ]

            self.modelPath = possiblePaths.first {
                FileManager.default.fileExists(atPath: $0)
            } ?? possiblePaths[0]
        }
    }

    /// Transcribe audio file to text
    func transcribe(audioURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
        // Verify audio file exists
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            completion(.failure(WhisperError.invalidAudioFile))
            return
        }

        // Run transcription in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                let text = try self.runWhisperCpp(audioPath: audioURL.path)
                completion(.success(text))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func runWhisperCpp(audioPath: String) throws -> String {
        // First, try to find whisper-cpp binary
        let whisperPath = findWhisperBinary()

        guard let whisperPath = whisperPath else {
            // Fallback: try using embedded whisper.cpp library
            // For now, use CLI approach
            throw WhisperError.transcriptionFailed("whisper-cpp binary not found. Install with: brew install whisper-cpp")
        }

        // Build command
        var arguments = [
            "-m", modelPath,
            "-f", audioPath,
            "--output-txt",
            "--no-timestamps"
        ]

        // Add language if specified
        if let language = config.language {
            arguments += ["-l", language]
        }

        // Add translate flag if needed
        if config.translateToEnglish {
            arguments.append("--translate")
        }

        // Run whisper-cpp
        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        // Read output
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw WhisperError.transcriptionFailed(errorMessage)
        }

        // Read the generated txt file
        let txtPath = audioPath + ".txt"
        if FileManager.default.fileExists(atPath: txtPath) {
            let transcription = try String(contentsOfFile: txtPath, encoding: .utf8)
            // Clean up
            try? FileManager.default.removeItem(atPath: txtPath)
            return transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Fallback to stdout output
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func findWhisperBinary() -> String? {
        let possiblePaths = [
            "/opt/homebrew/bin/whisper",
            "/opt/homebrew/bin/whisper-cpp",
            "/usr/local/bin/whisper",
            "/usr/local/bin/whisper-cpp",
            "/opt/homebrew/bin/main",
            "/usr/local/bin/main"
        ]

        // Also check PATH
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let pathDirs = pathEnv.split(separator: ":").map(String.init)

        for dir in pathDirs {
            for name in ["whisper", "whisper-cpp"] {
                let whisperPath = "\(dir)/\(name)"
                if FileManager.default.fileExists(atPath: whisperPath) {
                    return whisperPath
                }
            }
        }

        return possiblePaths.first {
            FileManager.default.fileExists(atPath: $0)
        }
    }
}
