import AppKit
import AVFoundation

final class AppController {
    private let config: Config
    private let audioCapture: AudioCapture
    private let whisperEngine: WhisperEngine
    private let outputHandler: OutputHandler
    private var overlayWindow: OverlayWindow?
    private var previousApp: NSRunningApplication?

    private var isRecording = false
    private var shouldPressEnterAfterPaste = false
    private var currentRecordingURL: URL?
    private var recordingTimestamp: String?

    init(config: Config, inputDeviceQuery: String? = nil) {
        self.config = config
        self.audioCapture = AudioCapture()
        self.whisperEngine = WhisperEngine(config: config.whisper)
        self.outputHandler = OutputHandler(config: config.output)

        // --input wins outright: an explicit request is honoured even if it is
        // bluetooth. Otherwise the audio config decides.
        if let query = inputDeviceQuery {
            if let match = AudioCapture.findInputDevice(matching: query) {
                print("Selected input device by --input '\(query)': \(match.name) (id=\(match.id))")
                if match.isBluetooth {
                    print("WARNING: \(match.name) is bluetooth — opening it will switch the headset to call mode")
                }
                self.audioCapture.preferredDevice = match
            } else {
                Self.abortNoDevice("no input device matched '\(query)'")
            }
        } else {
            switch AudioCapture.resolveInputDevice(config: config.audio) {
            case .chosen(let device, let reason):
                print("Input device (\(reason)): \(device.name) [\(device.transportLabel), id=\(device.id)]")
                self.audioCapture.preferredDevice = device
            case .unavailable(let reason):
                Self.abortNoDevice(reason)
            }
        }

        setupCallbacks()
    }

    /// A misconfigured mic must be loud — silently recording from the wrong
    /// device produces a transcript of the wrong room.
    ///
    /// Exits immediately rather than scheduling a terminate: an async teardown
    /// still lets startRecording run first, which would open the very device
    /// the config just ruled out.
    private static func abortNoDevice(_ reason: String) -> Never {
        print("ERROR: \(reason). Available inputs:")
        for d in AudioCapture.allInputDevices() {
            print("  - \(d.name) [\(d.transportLabel)]")
        }
        exit(EXIT_FAILURE)
    }

    private func setupCallbacks() {
        audioCapture.onAudioLevel = { [weak self] level in
            self?.overlayWindow?.updateAudioLevel(level)
        }
        audioCapture.onFrequencySpectrum = { [weak self] bands in
            self?.overlayWindow?.updateSpectrum(bands)
        }
    }

    func startRecording() {
        guard !isRecording else { return }

        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        print("Mic auth status: \(Self.describe(status))")

        switch status {
        case .authorized:
            beginRecording()
        case .notDetermined:
            print("Requesting microphone access…")
            audioCapture.requestPermission { [weak self] granted in
                if granted {
                    self?.beginRecording()
                } else {
                    self?.failPermission()
                }
            }
        case .denied, .restricted:
            failPermission()
        @unknown default:
            failPermission()
        }
    }

    private static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    private func failPermission() {
        let path = Bundle.main.executablePath ?? "yapless"
        print("ERROR: microphone access denied.")
        print("Open System Settings → Privacy & Security → Microphone and enable:")
        print("  \(path)")
        print("Then re-run yapless. (May require dragging the binary in if it does not appear.)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(nil)
        }
    }

    /// Headless mode: record for a fixed duration, no overlay, no keyboard capture. For testing or CLI use.
    func startHeadlessRecording(duration: Double) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .authorized || status == .notDetermined else {
            failPermission()
            return
        }

        func proceed() {
            isRecording = true
            let timestamp = ISO8601DateFormatter().string(from: Date())
            recordingTimestamp = timestamp.replacingOccurrences(of: ":", with: "-")

            audioCapture.startRecording { [weak self] audioURL in
                self?.processRecording(at: audioURL)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                guard let self = self, self.isRecording else { return }
                print("Headless: duration elapsed, stopping")
                self.isRecording = false
                self.audioCapture.stopRecording()
            }
        }

        if status == .notDetermined {
            audioCapture.requestPermission { granted in
                if granted { proceed() } else { self.failPermission() }
            }
        } else {
            proceed()
        }
    }

    private func beginRecording() {
        isRecording = true

        previousApp = NSWorkspace.shared.frontmostApplication
        if config.animation.style != .dot {
            NSCursor.pointingHand.push()
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let safeTimestamp = timestamp.replacingOccurrences(of: ":", with: "-")
        recordingTimestamp = safeTimestamp

        showOverlay()

        audioCapture.startRecording { [weak self] audioURL in
            self?.processRecording(at: audioURL)
        }
    }

    func stopRecording(pressEnter: Bool = false) {
        guard isRecording else { return }
        print("AppController.stopRecording called (pressEnter=\(pressEnter))")
        isRecording = false
        shouldPressEnterAfterPaste = pressEnter

        audioCapture.stopRecording()
        overlayWindow?.showProcessingState()
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func showOverlay() {
        overlayWindow = OverlayWindow(config: config.animation)
        overlayWindow?.onStopRequested = { [weak self] pressEnter in
            self?.stopRecording(pressEnter: pressEnter)
        }
        overlayWindow?.onCancelRequested = { [weak self] in
            self?.cancelTranscription()
        }
        overlayWindow?.showRecordingState()

        let info = audioCapture.preferredDevice ?? AudioCapture.defaultInputDeviceInfo()
        if let info = info {
            overlayWindow?.setMicLabel("mic: \(info.name)")
        } else {
            overlayWindow?.setMicLabel("mic: <unknown>")
        }
    }

    private func cancelTranscription() {
        print("Transcription cancelled (draft preserved)")
        if config.animation.style != .dot {
            NSCursor.pop()
        }
        hideOverlay()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApplication.shared.terminate(nil)
        }
    }

    private func hideOverlay() {
        overlayWindow?.animateCompletion { [weak self] in
            self?.overlayWindow?.close()
            self?.overlayWindow = nil
        }
    }

    private func processRecording(at audioURL: URL) {
        currentRecordingURL = audioURL
        overlayWindow?.showProcessingState()

        whisperEngine.transcribe(audioURL: audioURL) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let text):
                    self?.saveHistoryIfEnabled(text: text, audioURL: audioURL)
                    self?.handleTranscriptionResult(text)
                case .failure(let error):
                    self?.handleTranscriptionError(error)
                }
            }
        }
    }

    private func saveHistoryIfEnabled(text: String, audioURL: URL) {
        guard config.storage.saveHistory else { return }
        guard let timestamp = recordingTimestamp else { return }

        let fm = FileManager.default

        do {
            try fm.createDirectory(at: StorageConfig.transcriptionsDirectory, withIntermediateDirectories: true)

            let transcriptionDest = StorageConfig.transcriptionsDirectory.appendingPathComponent("\(timestamp).txt")
            try text.write(to: transcriptionDest, atomically: true, encoding: .utf8)

            print("Saved transcription to \(transcriptionDest.path)")
        } catch {
            print("Failed to save transcription: \(error.localizedDescription)")
        }
    }

    private func handleTranscriptionResult(_ text: String) {
        overlayWindow?.showCompletionState()

        // Restore cursor
        if config.animation.style != .dot {
            NSCursor.pop()
        }

        // Restore focus to original app before pasting
        if let app = previousApp {
            app.activate(options: [])
        }

        // Small delay to let the app activate
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }
            self.outputHandler.handle(text: text, pressEnter: self.shouldPressEnterAfterPaste) {
                self.hideOverlay()

                // Exit after completion
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    private func handleTranscriptionError(_ error: Error) {
        print("Transcription error: \(error.localizedDescription)")
        overlayWindow?.showErrorState()
        if config.animation.style != .dot {
            NSCursor.pop()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.hideOverlay()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
