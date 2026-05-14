import AVFoundation
import Accelerate
import CoreAudio

final class AudioCapture {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private(set) var recordingURL: URL?

    var onAudioLevel: ((Float) -> Void)?
    var onFrequencySpectrum: (([Float]) -> Void)?

    private let fftSize = 512
    private var fftSetup: vDSP_DFT_Setup?
    private let frequencyBands = 14

    private var completionHandler: ((URL) -> Void)?
    private let recordingFormat: AVAudioFormat
    private var bufferCount: Int = 0
    private var bufferMaxSample: Float = 0
    private var bufferRMSSum: Float = 0
    private var lastStatsLog: Date = .distantPast

    init() {
        self.recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD)
    }

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

        let fm = FileManager.default
        try? fm.createDirectory(at: StorageConfig.recordingsDirectory, withIntermediateDirectories: true)

        let filename = "\(safeTimestamp).wav"
        recordingURL = StorageConfig.recordingsDirectory.appendingPathComponent(filename)

        guard let recordingURL = recordingURL else { return }

        if let info = Self.defaultInputDeviceInfo() {
            print("Input device: \(info.name) [uid=\(info.uid), id=\(info.id), \(Int(info.sampleRate))Hz, \(info.channels)ch]")
        } else {
            print("Input device: <unknown — could not query CoreAudio>")
        }

        do {
            audioEngine = AVAudioEngine()
            guard let audioEngine = audioEngine else { return }

            let inputNode = audioEngine.inputNode

            // Force the engine's input AUHAL to the current system default input.
            // Without this, AVAudioEngine can silently bind to a different/stale device.
            if let deviceID = Self.defaultInputDeviceInfo()?.id, let inputUnit = inputNode.audioUnit {
                var devID = deviceID
                let status = AudioUnitSetProperty(
                    inputUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &devID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                if status != noErr {
                    print("Warning: failed to bind input device (OSStatus \(status))")
                } else {
                    print("Bound AVAudioEngine input to device id \(deviceID)")
                }
            }

            let inputFormat = inputNode.outputFormat(forBus: 0)
            print("Input format: \(Int(inputFormat.sampleRate))Hz, \(inputFormat.channelCount)ch")

            guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
                print("ERROR: input format is invalid (\(inputFormat.channelCount)ch @ \(inputFormat.sampleRate)Hz). Mic likely not available — check Settings → Privacy → Microphone, or change default input device.")
                return
            }

            bufferCount = 0
            bufferMaxSample = 0
            bufferRMSSum = 0
            lastStatsLog = Date()

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

    func stopRecording() {
        guard let audioEngine = audioEngine else { return }

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        self.audioEngine = nil
        self.audioFile = nil  // dropping the reference flushes/finalizes the WAV header

        print("Recording stopped")

        if let recordingURL = recordingURL {
            completionHandler?(recordingURL)
        }
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        let level = calculateRMS(buffer: buffer)
        let spectrum = calculateSpectrum(buffer: buffer)

        // Diagnostic: track raw signal stats and log every ~1s so we know if mic is silent.
        if let channelData = buffer.floatChannelData?[0] {
            var peak: Float = 0
            vDSP_maxmgv(channelData, 1, &peak, vDSP_Length(buffer.frameLength))
            var rms: Float = 0
            vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(buffer.frameLength))
            bufferMaxSample = max(bufferMaxSample, peak)
            bufferRMSSum += rms
            bufferCount += 1

            let now = Date()
            if now.timeIntervalSince(lastStatsLog) >= 1.0 {
                let avgRMS = bufferRMSSum / Float(max(bufferCount, 1))
                print(String(format: "Audio stats: %d buffers, peak=%.5f, avgRMS=%.5f", bufferCount, bufferMaxSample, avgRMS))
                bufferCount = 0
                bufferMaxSample = 0
                bufferRMSSum = 0
                lastStatsLog = now
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.onAudioLevel?(level)
            self?.onFrequencySpectrum?(spectrum)
        }

        guard let audioFile = audioFile else { return }

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

        let normalizedLevel = min(1.0, rms * 5)
        return normalizedLevel
    }

    private func calculateSpectrum(buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData?[0],
              let fftSetup = fftSetup else {
            return Array(repeating: 0, count: frequencyBands)
        }

        let frameLength = min(Int(buffer.frameLength), fftSize)

        var windowedInput = [Float](repeating: 0, count: fftSize)
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        for i in 0..<frameLength {
            windowedInput[i] = channelData[i] * window[i]
        }

        var realIn = [Float](repeating: 0, count: fftSize)
        var imagIn = [Float](repeating: 0, count: fftSize)
        var realOut = [Float](repeating: 0, count: fftSize)
        var imagOut = [Float](repeating: 0, count: fftSize)

        realIn = windowedInput

        vDSP_DFT_Execute(fftSetup, &realIn, &imagIn, &realOut, &imagOut)

        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        for i in 0..<fftSize / 2 {
            magnitudes[i] = sqrt(realOut[i] * realOut[i] + imagOut[i] * imagOut[i])
        }

        var bands = [Float](repeating: 0, count: frequencyBands)
        let nyquist = fftSize / 2

        for band in 0..<frequencyBands {
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

        var maxVal: Float = 0
        vDSP_maxv(bands, 1, &maxVal, vDSP_Length(frequencyBands))
        if maxVal > 0 {
            var scale = 1.0 / maxVal
            vDSP_vsmul(bands, 1, &scale, &bands, 1, vDSP_Length(frequencyBands))
        }

        for i in 0..<frequencyBands {
            bands[i] = min(1.0, bands[i] * 3.0)
        }

        return bands
    }

    struct InputDeviceInfo {
        let id: AudioDeviceID
        let name: String
        let uid: String
        let sampleRate: Double
        let channels: UInt32
    }

    static func defaultInputDeviceInfo() -> InputDeviceInfo? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }

        return InputDeviceInfo(
            id: deviceID,
            name: stringProperty(deviceID, kAudioObjectPropertyName) ?? "<unnamed>",
            uid: stringProperty(deviceID, kAudioDevicePropertyDeviceUID) ?? "<no-uid>",
            sampleRate: doubleProperty(deviceID, kAudioDevicePropertyNominalSampleRate) ?? 0,
            channels: inputChannelCount(deviceID)
        )
    }

    private static func stringProperty(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &unmanaged)
        guard status == noErr, let cfString = unmanaged?.takeRetainedValue() else { return nil }
        return cfString as String
    }

    private static func doubleProperty(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> Double? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func inputChannelCount(_ device: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, bufferList) == noErr else {
            return 0
        }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(UInt32(0)) { $0 + $1.mNumberChannels }
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
