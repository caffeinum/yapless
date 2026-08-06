import AppKit
import AVFoundation

final class AppController {
    private let config: Config
    private let audioCapture: AudioCapture
    /// Built on first use, which is after the recording ends. Resolving
    /// credentials and hunting for local whisper binaries costs ~40ms and
    /// nothing on the record path needs it — the microphone should be live
    /// before we care how the audio will eventually be transcribed.
    private lazy var whisperEngine = WhisperEngine(config: config.whisper)
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

        audioCapture.silenceFloor = Float(config.audio.silenceFloor)
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

        // Mic first, UI second: the engine takes ~190ms of CoreAudio setup and
        // the overlay ~100ms of SwiftUI, and neither needs the other. Starting
        // the capture first means words spoken at the very beginning land.
        audioCapture.startRecordingInBackground { [weak self] audioURL in
            self?.processRecording(at: audioURL)
        }

        Self.play(config.output.startSound, label: "startSound")
        showOverlay()
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

        if let sink = config.output.command, !sink.isEmpty {
            overlayWindow?.setSinkLabel(sink)
        }

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

    /// Marks the moment the wait begins. Fires only once the recording has
    /// been accepted, so a refusal doesn't get both this and the error sound.
    private func playProcessingSound() {
        Self.play(config.output.processingSound, label: "processingSound")
    }

    private func playErrorSound() {
        Self.play(config.output.errorSound, label: "errorSound")
    }

    private func playRefusedSound() {
        Self.play(config.output.refusedSound, label: "refusedSound")
    }

    /// A system sound name, or an absolute path to a file. Empty/nil is
    /// silence; an unresolvable name warns, because a sound that never plays
    /// looks exactly like a feature that isn't working.
    private static func play(_ name: String?, label: String) {
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }

        let sound = name.hasPrefix("/")
            ? NSSound(contentsOfFile: name, byReference: true)
            : NSSound(named: name)

        if sound == nil {
            print("WARNING: \(label) '\(name)' not found — no sound played")
        }
        sound?.play()
    }

    /// Why this recording shouldn't be transcribed, or nil to proceed.
    ///
    /// Whisper invents confident sentences from silence ("Thank you for
    /// watching!") — well-formed text no downstream filter can catch. The only
    /// evidence that it isn't speech is the audio underneath it, which is why
    /// this lives here. Record path only: `--transcribe` never reaches it, so
    /// naming a recording explicitly always overrides the heuristic.
    private func silenceRefusal() -> String? {
        let required = config.audio.minVoicedSeconds
        guard required > 0 else { return nil }

        let voiced = audioCapture.voicedSeconds
        guard voiced < required else { return nil }

        return String(
            format: "only %.2fs of voice-level audio (need %.2fs above rms %.3f)",
            voiced, required, config.audio.silenceFloor
        )
    }

    /// Refusals must be impossible to miss: an invisible one is indistinguishable
    /// from a bug and survives for weeks. The audio is kept either way, so a
    /// wrong threshold costs a `--transcribe`, not the user's words.
    private func refuseSilentRecording(reason: String, audioURL: URL) {
        print("Refused: \(reason)")
        print("Audio kept — recover with: yapless --transcribe \(audioURL.path)")

        playRefusedSound()
        overlayWindow?.setMicLabel("no speech detected — not sent")
        overlayWindow?.showErrorState()

        if config.animation.style != .dot {
            NSCursor.pop()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.hideOverlay()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApplication.shared.terminate(nil)
            }
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

        // Logged on every run, not just refusals: tuning the threshold later
        // needs the distribution of accepted recordings too.
        print(String(format: "Voiced audio: %.2fs (threshold %.2fs above rms %.3f)",
                     audioCapture.voicedSeconds,
                     config.audio.minVoicedSeconds,
                     config.audio.silenceFloor))

        if let reason = silenceRefusal() {
            refuseSilentRecording(reason: reason, audioURL: audioURL)
            return
        }

        overlayWindow?.showProcessingState()
        playProcessingSound()

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
        // Previously silent: a failed transcription looked identical to a
        // successful one that produced nothing.
        playErrorSound()
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
