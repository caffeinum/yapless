import AppKit
import AVFoundation

/// Main controller that orchestrates recording, transcription, and UI
final class AppController {
    private let config: Config
    private let audioCapture: AudioCapture
    private let whisperEngine: WhisperEngine
    private let outputHandler: OutputHandler
    private var overlayWindow: OverlayWindow?

    private var isRecording = false

    init(config: Config) {
        self.config = config
        self.audioCapture = AudioCapture()
        self.whisperEngine = WhisperEngine(config: config.whisper)
        self.outputHandler = OutputHandler(config: config.output)

        setupAudioLevelCallback()
    }

    private func setupAudioLevelCallback() {
        audioCapture.onAudioLevel = { [weak self] level in
            self?.overlayWindow?.updateAudioLevel(level)
        }
    }

    func startRecording() {
        guard !isRecording else { return }
        isRecording = true

        // Show overlay animation
        if config.animation.style != .cursor || true { // Always show for now
            showOverlay()
        }

        // Start audio capture
        audioCapture.startRecording { [weak self] audioURL in
            self?.processRecording(at: audioURL)
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false

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
        overlayWindow?.onStopRequested = { [weak self] in
            self?.stopRecording()
        }
        overlayWindow?.showRecordingState()
    }

    private func hideOverlay() {
        overlayWindow?.animateCompletion { [weak self] in
            self?.overlayWindow?.close()
            self?.overlayWindow = nil
        }
    }

    private func processRecording(at audioURL: URL) {
        overlayWindow?.showProcessingState()

        whisperEngine.transcribe(audioURL: audioURL) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let text):
                    self?.handleTranscriptionResult(text)
                case .failure(let error):
                    self?.handleTranscriptionError(error)
                }
            }
        }
    }

    private func handleTranscriptionResult(_ text: String) {
        overlayWindow?.showCompletionState()

        outputHandler.handle(text: text) { [weak self] in
            self?.hideOverlay()

            // Exit after completion
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func handleTranscriptionError(_ error: Error) {
        print("Transcription error: \(error.localizedDescription)")
        hideOverlay()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(nil)
        }
    }
}
