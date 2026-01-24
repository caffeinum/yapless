import AppKit
import ArgumentParser

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

    mutating func run() throws {
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

// Entry point
VoiceToText.main()
