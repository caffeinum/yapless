import AVFoundation
import Accelerate

/// Handles audio capture from the microphone
final class AudioCapture {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?

    /// Callback for real-time audio level updates (0.0 - 1.0)
    var onAudioLevel: ((Float) -> Void)?

    /// Callback when recording is complete
    private var completionHandler: ((URL) -> Void)?

    private let recordingFormat: AVAudioFormat

    init() {
        // Standard format for Whisper: 16kHz mono
        self.recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
    }

    /// Request microphone permission
    func requestPermission(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    /// Start recording audio
    func startRecording(completion: @escaping (URL) -> Void) {
        self.completionHandler = completion

        // Create temporary file for recording
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "voice-recording-\(UUID().uuidString).wav"
        recordingURL = tempDir.appendingPathComponent(filename)

        guard let recordingURL = recordingURL else { return }

        do {
            audioEngine = AVAudioEngine()
            guard let audioEngine = audioEngine else { return }

            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)

            // Create audio file
            audioFile = try AVAudioFile(
                forWriting: recordingURL,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 16000,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false
                ]
            )

            // Install tap on input node
            inputNode.installTap(
                onBus: 0,
                bufferSize: 512,  // balanced: ~30 updates/sec at 16kHz
                format: inputFormat
            ) { [weak self] buffer, _ in
                self?.processAudioBuffer(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()

            print("Recording started...")

        } catch {
            print("Failed to start recording: \(error)")
        }
    }

    /// Stop recording and return the audio file URL
    func stopRecording() {
        guard let audioEngine = audioEngine else { return }

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        self.audioEngine = nil

        print("Recording stopped")

        if let recordingURL = recordingURL {
            completionHandler?(recordingURL)
        }
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        // Calculate RMS for audio level visualization
        let level = calculateRMS(buffer: buffer)
        DispatchQueue.main.async { [weak self] in
            self?.onAudioLevel?(level)
        }

        // Convert and write to file
        guard let audioFile = audioFile else { return }

        // Convert to 16kHz mono if needed
        if let convertedBuffer = convertBuffer(buffer, to: recordingFormat) {
            do {
                try audioFile.write(from: convertedBuffer)
            } catch {
                print("Failed to write audio buffer: \(error)")
            }
        }
    }

    private func calculateRMS(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }

        let frameLength = Int(buffer.frameLength)
        var rms: Float = 0

        vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(frameLength))

        // Normalize and apply some smoothing
        let normalizedLevel = min(1.0, rms * 5)
        return normalizedLevel
    }

    private func convertBuffer(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            return nil
        }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: outputFrameCapacity
        ) else {
            return nil
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            print("Audio conversion error: \(error)")
            return nil
        }

        return outputBuffer
    }
}
