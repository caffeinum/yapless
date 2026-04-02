import AppKit
import ArgumentParser
import Foundation

@main
struct VoiceToText: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "voice-to-text",
        abstract: "Lightweight voice-to-text for macOS with nice animations",
        version: "0.1.0"
    )

    @Flag(name: .shortAndLong, help: "Start recording immediately")
    var record = false

    @Flag(name: .shortAndLong, inversion: .prefixedNo, help: "Show animation overlay")
    var animate = true

    @Flag(name: .shortAndLong, help: "Paste result to active app")
    var paste = false

    @Flag(name: .shortAndLong, inversion: .prefixedNo, help: "Copy result to clipboard")
    var clipboard = true

    @Option(name: .shortAndLong, help: "Whisper model to use (tiny, base, small, medium, large)")
    var model: String = "base"

    @Option(name: .long, help: "Animation style (orb, waveform, glow, cursor)")
    var animationStyle: String?

    @Option(name: .long, help: "Path to config file")
    var config: String?

    @Option(name: .shortAndLong, help: "Transcribe an audio file (path or 'latest')")
    var transcribe: String?

    @Flag(name: .long, help: "Show animation showcase window")
    var showcase = false

    mutating func run() throws {
        if let transcribePath = transcribe {
            let audioURL: URL

            if transcribePath == "latest" {
                let recordingsDir = StorageConfig.recordingsDirectory
                let fm = FileManager.default
                guard let files = try? fm.contentsOfDirectory(at: recordingsDir, includingPropertiesForKeys: [.contentModificationDateKey]),
                      !files.isEmpty else {
                    print("No recordings found in \(recordingsDir.path)")
                    throw ExitCode.failure
                }
                let sorted = files.sorted { a, b in
                    let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return dateA > dateB
                }
                audioURL = sorted[0]
            } else {
                audioURL = URL(fileURLWithPath: transcribePath)
                guard FileManager.default.fileExists(atPath: audioURL.path) else {
                    print("File not found: \(transcribePath)")
                    throw ExitCode.failure
                }
            }

            let configPath = config ?? Config.defaultPath
            let appConfig: Config
            do {
                appConfig = try Config.load(from: configPath)
            } catch {
                print("Config load error: \(error)")
                appConfig = Config()
            }

            let whisperEngine = WhisperEngine(config: appConfig.whisper)
            let semaphore = DispatchSemaphore(value: 0)
            var result: Result<String, Error>?

            whisperEngine.transcribe(audioURL: audioURL) { r in
                result = r
                semaphore.signal()
            }

            semaphore.wait()

            switch result! {
            case .success(let text):
                print(text)
                if clipboard {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                throw ExitCode.success
            case .failure(let error):
                print("Transcription failed: \(error.localizedDescription)")
                throw ExitCode.failure
            }
        }

        if showcase {
            NSApplication.shared.setActivationPolicy(.regular)
            let showcaseController = ShowcaseWindowController()
            showcaseController.show()
            NSApplication.shared.run()
            return
        }

        // Hide from Dock and Menu Bar
        NSApplication.shared.setActivationPolicy(.accessory)

        // Load configuration
        let configPath = config ?? Config.defaultPath
        print("Loading config from: \(configPath)")
        let appConfig: Config
        do {
            appConfig = try Config.load(from: configPath)
        } catch {
            print("Config load error: \(error)")
            appConfig = Config()
        }
        print("Backend: \(appConfig.whisper.backend), API key present: \(appConfig.whisper.groqApiKey != nil)")

        // Override animation style if provided via CLI
        var finalConfig = appConfig
        if let style = animationStyle {
            finalConfig.animation.style = AnimationStyle(rawValue: style) ?? appConfig.animation.style
        }

        // Initialize the app controller
        let controller = AppController(config: finalConfig)

        if record {
            controller.startRecording()
        }

        // Run the main loop
        NSApplication.shared.run()
    }
}
