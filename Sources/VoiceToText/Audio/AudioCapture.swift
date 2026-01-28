import AVFoundation
import Accelerate

final class AudioCapture {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private(set) var recordingURL: URL?
    private var recordingTimestamp: String?

    var onAudioLevel: ((Float) -> Void)?
    var onFrequencySpectrum: (([Float]) -> Void)?

    private let fftSize = 512
    private var fftSetup: vDSP_DFT_Setup?
    private let frequencyBands = 14

    private var completionHandler: ((URL) -> Void)?
    private let recordingFormat: AVAudioFormat

    private var chunkTimer: Timer?
    private var lastChunkFrame: AVAudioFramePosition = 0
    private let chunkIntervalSeconds: Double = 15.0
    var onChunkReady: ((URL, Int) -> Void)?

    init() {
        // Standard format for Whisper: 16kHz mono
        self.recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        // Setup FFT
        fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD)
    }

    /// Request microphone permission
    func requestPermission(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    func startRecording(completion: @escaping (URL) -> Void) {
        self.completionHandler = completion

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let safeTimestamp = timestamp.replacingOccurrences(of: ":", with: "-")
        recordingTimestamp = safeTimestamp

        let fm = FileManager.default
        try? fm.createDirectory(at: StorageConfig.recordingsDirectory, withIntermediateDirectories: true)

        let filename = "\(safeTimestamp).wav"
        recordingURL = StorageConfig.recordingsDirectory.appendingPathComponent(filename)

        guard let recordingURL = recordingURL else { return }

        do {
            audioEngine = AVAudioEngine()
            guard let audioEngine = audioEngine else { return }

            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)

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

            lastChunkFrame = 0
            startChunkTimer()

            inputNode.installTap(
                onBus: 0,
                bufferSize: 512,
                format: inputFormat
            ) { [weak self] buffer, _ in
                self?.processAudioBuffer(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()

            print("Recording started to \(recordingURL.path)")

        } catch {
            print("Failed to start recording: \(error)")
        }
    }

    private func startChunkTimer() {
        chunkTimer = Timer.scheduledTimer(withTimeInterval: chunkIntervalSeconds, repeats: true) { [weak self] _ in
            self?.extractChunk()
        }
    }

    private func extractChunk() {
        guard let recordingURL = recordingURL,
              let audioFile = audioFile else { return }

        let currentFrame = audioFile.framePosition
        let framesToExtract = currentFrame - lastChunkFrame
        let chunkIndex = Int(lastChunkFrame / AVAudioFramePosition(16000 * chunkIntervalSeconds))
        let startFrame = lastChunkFrame

        guard framesToExtract >= 8000 else { return }

        lastChunkFrame = currentFrame

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            do {
                let sourceFile = try AVAudioFile(forReading: recordingURL)
                sourceFile.framePosition = startFrame

                let chunkURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("chunk-\(chunkIndex).wav")

                let chunkFile = try AVAudioFile(
                    forWriting: chunkURL,
                    settings: [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: 16000,
                        AVNumberOfChannelsKey: 1,
                        AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false,
                        AVLinearPCMIsBigEndianKey: false
                    ]
                )

                let bufferSize = AVAudioFrameCount(framesToExtract)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFile.processingFormat, frameCapacity: bufferSize) else {
                    return
                }
                try sourceFile.read(into: buffer, frameCount: bufferSize)
                try chunkFile.write(from: buffer)

                self.onChunkReady?(chunkURL, chunkIndex)
            } catch {
            }
        }
    }

    func stopRecording() {
        chunkTimer?.invalidate()
        chunkTimer = nil

        extractChunk()

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

        // Calculate frequency spectrum
        let spectrum = calculateSpectrum(buffer: buffer)

        DispatchQueue.main.async { [weak self] in
            self?.onAudioLevel?(level)
            self?.onFrequencySpectrum?(spectrum)
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

    private func calculateSpectrum(buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData?[0],
              let fftSetup = fftSetup else {
            return Array(repeating: 0, count: frequencyBands)
        }

        let frameLength = min(Int(buffer.frameLength), fftSize)

        // Prepare input - apply Hann window
        var windowedInput = [Float](repeating: 0, count: fftSize)
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        for i in 0..<frameLength {
            windowedInput[i] = channelData[i] * window[i]
        }

        // Split complex arrays for FFT
        var realIn = [Float](repeating: 0, count: fftSize)
        var imagIn = [Float](repeating: 0, count: fftSize)
        var realOut = [Float](repeating: 0, count: fftSize)
        var imagOut = [Float](repeating: 0, count: fftSize)

        realIn = windowedInput

        // Perform FFT
        vDSP_DFT_Execute(fftSetup, &realIn, &imagIn, &realOut, &imagOut)

        // Calculate magnitudes
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        for i in 0..<fftSize / 2 {
            magnitudes[i] = sqrt(realOut[i] * realOut[i] + imagOut[i] * imagOut[i])
        }

        // Group into frequency bands (logarithmic distribution)
        var bands = [Float](repeating: 0, count: frequencyBands)
        let nyquist = fftSize / 2

        for band in 0..<frequencyBands {
            // Logarithmic frequency distribution
            let lowBin = Int(pow(Float(nyquist), Float(band) / Float(frequencyBands)))
            let highBin = Int(pow(Float(nyquist), Float(band + 1) / Float(frequencyBands)))

            let start = max(1, lowBin)
            let end = min(nyquist, highBin)

            if end > start {
                var sum: Float = 0
                vDSP_sve(&magnitudes[start], 1, &sum, vDSP_Length(end - start))
                bands[band] = sum / Float(end - start)
            }
        }

        // Normalize bands
        var maxVal: Float = 0
        vDSP_maxv(bands, 1, &maxVal, vDSP_Length(frequencyBands))
        if maxVal > 0 {
            var scale = 1.0 / maxVal
            vDSP_vsmul(bands, 1, &scale, &bands, 1, vDSP_Length(frequencyBands))
        }

        // Apply gain for visibility
        for i in 0..<frequencyBands {
            bands[i] = min(1.0, bands[i] * 3.0)
        }

        return bands
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
