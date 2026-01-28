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

    init(config: Config) {
        self.config = config
        self.audioCapture = AudioCapture()
        self.whisperEngine = WhisperEngine(config: config.whisper)
        self.outputHandler = OutputHandler(config: config.output)

        setupCallbacks()
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
        isRecording = true

        previousApp = NSWorkspace.shared.frontmostApplication
        NSCursor.pointingHand.push()

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let safeTimestamp = timestamp.replacingOccurrences(of: ":", with: "-")
        recordingTimestamp = safeTimestamp

        if config.animation.style != .cursor || true {
            showOverlay()
        }

        audioCapture.startRecording { [weak self] audioURL in
            self?.processRecording(at: audioURL)
        }
    }

    func stopRecording(pressEnter: Bool = false) {
        guard isRecording else { return }
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
    }

    private func cancelTranscription() {
        print("Transcription cancelled (draft preserved)")
        NSCursor.pop()
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
        NSCursor.pop()

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
        NSCursor.pop()
        hideOverlay()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(nil)
        }
    }
}
