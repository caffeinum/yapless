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

    @Option(name: .long, help: "Animation style (dot, pill, equalizer, orb, waveform, glow, siri, cursor)")
    var animationStyle: String?

    @Option(name: .long, help: "Path to config file")
    var config: String?

    @Option(name: .shortAndLong, help: "Transcribe an audio file (path or 'latest')")
    var transcribe: String?

    @Option(name: .long, help: "Transcription backend (auto, groq, deepinfra, fireworks, fal, replicate, local). Overrides config.")
    var backend: String?

    @Option(name: [.customShort("i"), .long], help: "Input device name (substring match, e.g. 'AirPods' or 'MacBook')")
    var input: String?

    @Flag(name: .long, help: "List available input devices and exit")
    var listInputs: Bool = false

    @Option(name: .long, help: "Record for a fixed duration (seconds) without overlay/keyboard capture, then transcribe and exit")
    var duration: Double?

    @Option(name: .long, help: "Shell command handed the transcript on stdin (overrides config output.command)")
    var outputCommand: String?

    @Flag(name: .long, help: "Show animation showcase window")
    var showcase = false

    @Flag(name: .long, help: "Re-launch in its own session and exit immediately (for launchers that time out, e.g. Raycast)")
    var detach = false

    /// Relaunch ourselves in a new session, then let the caller's process exit.
    ///
    /// Raycast kills a script command that outlives its timeout; a plain
    /// background job is still in that process group, so it dies too.
    /// POSIX_SPAWN_SETSID puts the recording process in its own session, where
    /// the launcher can neither wait on it nor kill it.
    private func relaunchDetached() throws {
        guard let executable = Bundle.main.executablePath else {
            throw ValidationError("could not resolve own executable path to detach")
        }

        let arguments = [executable] + CommandLine.arguments.dropFirst().filter { $0 != "--detach" }
        var environment = ProcessInfo.processInfo.environment
        environment["YAPLESS_DETACHED"] = "1"

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        // The launcher's pipes die with it; writing to a closed pipe would kill
        // the detached run with SIGPIPE mid-transcription. Log to a file instead.
        let logURL = StorageConfig.dataDirectory.appendingPathComponent("detached.log")
        try? FileManager.default.createDirectory(
            at: StorageConfig.dataDirectory, withIntermediateDirectories: true
        )

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 1, logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&fileActions, 1, 2)

        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &fileActions, &attr, argv, envp)
        guard status == 0 else {
            throw ValidationError("detach failed: posix_spawn returned \(status)")
        }
        // Raycast surfaces anything a script prints as a HUD. Only say this
        // when a human is actually looking at a terminal.
        if isatty(STDOUT_FILENO) == 1 {
            print("yapless detached (pid \(pid)) — log: \(logURL.path)")
        }
    }

    /// Apply the `--backend` CLI flag over whatever the config file specified.
    private func applyBackendOverride(_ appConfig: inout Config) {
        guard let backend = backend else { return }
        guard let parsed = TranscriptionBackend(rawValue: backend) else {
            fputs("Unknown backend '\(backend)', ignoring (valid: auto, groq, deepinfra, fireworks, fal, replicate, openai, local)\n", stderr)
            return
        }
        appConfig.whisper.backend = parsed
    }

    mutating func run() throws {
        // Line-buffer stdout/stderr so diagnostics survive abrupt exits and pipes.
        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IOLBF, 0)

        if detach && ProcessInfo.processInfo.environment["YAPLESS_DETACHED"] == nil {
            try relaunchDetached()
            throw ExitCode.success
        }

        if listInputs {
            let devices = AudioCapture.allInputDevices()
            if devices.isEmpty {
                print("No input devices found.")
            } else {
                let defaultID = AudioCapture.defaultInputDeviceInfo()?.id
                print("Available input devices:")
                for d in devices {
                    let marker = d.id == defaultID ? " (default)" : ""
                    let warning = d.isBluetooth ? "  ⚠︎ bluetooth — opening this switches the headset to call mode" : ""
                    print("  \(d.name) [\(d.transportLabel), id=\(d.id), \(Int(d.sampleRate))Hz, \(d.channels)ch]\(marker)\(warning)")
                }
            }
            throw ExitCode.success
        }

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
            var appConfig: Config
            do {
                appConfig = try Config.load(from: configPath)
            } catch {
                print("Config load error: \(error)")
                appConfig = Config()
            }
            applyBackendOverride(&appConfig)

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

                // Re-transcribing feeds the sink too, otherwise "why didn't it
                // send?" depends on which entry point you happened to use.
                let sinkCommand = outputCommand ?? appConfig.output.command
                if let sinkCommand = sinkCommand, !sinkCommand.isEmpty {
                    var sinkConfig = appConfig.output
                    sinkConfig.command = sinkCommand
                    sinkConfig.copyToClipboard = false
                    sinkConfig.pasteToActiveApp = false
                    sinkConfig.playCompletionSound = false

                    let sink = OutputHandler(config: sinkConfig)
                    let done = DispatchSemaphore(value: 0)
                    sink.handle(text: text) { done.signal() }
                    // handle() hops to main for its completion, which never runs
                    // here — this path owns the main thread. Wait on the child
                    // directly instead.
                    _ = done.wait(timeout: .now() + sinkConfig.commandTimeout + 1)
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
        var appConfig: Config
        do {
            appConfig = try Config.load(from: configPath)
        } catch {
            print("Config load error: \(error)")
            appConfig = Config()
        }
        applyBackendOverride(&appConfig)
        print("Backend: \(appConfig.whisper.backend), API key present: \(appConfig.whisper.groqApiKey != nil)")

        // Apply CLI overrides over whatever the config file specified
        var finalConfig = appConfig
        if let style = animationStyle {
            finalConfig.animation.style = AnimationStyle(rawValue: style) ?? appConfig.animation.style
        }
        if let outputCommand = outputCommand {
            finalConfig.output.command = outputCommand
        }

        // Initialize the app controller
        let controller = AppController(config: finalConfig, inputDeviceQuery: input)

        if let duration = duration {
            print("Headless recording for \(duration)s (no overlay, no keyboard capture)")
            controller.startHeadlessRecording(duration: duration)
        } else if record {
            controller.startRecording()
        }

        // Run the main loop
        NSApplication.shared.run()
    }
}
