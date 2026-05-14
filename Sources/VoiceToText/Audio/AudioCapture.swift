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
    /// If set, overrides the system default input for this capture.
    var preferredDevice: InputDeviceInfo?
    /// Saved system default before we switched it; restored on stopRecording.
    private var savedSystemDefaultDeviceID: AudioDeviceID?
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

        let resolvedDevice = preferredDevice ?? Self.defaultInputDeviceInfo()
        if let info = resolvedDevice {
            let source = preferredDevice != nil ? "override" : "system default"
            print("Input device (\(source)): \(info.name) [uid=\(info.uid), id=\(info.id), \(Int(info.sampleRate))Hz, \(info.channels)ch]")
        } else {
            print("Input device: <unknown — could not query CoreAudio>")
        }

        // If the user requested a specific input via --input, switch the SYSTEM default
        // BEFORE the engine is created. AVAudioEngine.inputNode is bound to the system
        // default at engine init; rebinding later via AudioUnitSetProperty corrupts the
        // tap. We restore the previous default in stopRecording.
        if let override = preferredDevice {
            let currentDefault = Self.currentDefaultInputDeviceID()
            if currentDefault == override.id {
                // Already on the target — DO NOT re-set, that triggers a device reset
                // which confuses AVAudioEngine's format detection (saw 24000Hz device
                // get reported as 48000Hz, then zero buffers).
                print("System default already on \(override.name) — skipping swap")
                savedSystemDefaultDeviceID = nil
            } else {
                savedSystemDefaultDeviceID = currentDefault
                if !Self.setDefaultInputDevice(override.id) {
                    print("ERROR: could not switch system default input to \(override.name) — aborting")
                    return
                }
                let deadline = Date().addingTimeInterval(1.0)
                var actualID = Self.currentDefaultInputDeviceID()
                while actualID != override.id && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.02)
                    actualID = Self.currentDefaultInputDeviceID()
                }
                if actualID == override.id {
                    // Give the device a moment to stabilize after the switch.
                    Thread.sleep(forTimeInterval: 0.25)
                    print("Switched system default input to: \(override.name) (will restore on stop)")
                } else {
                    print("ERROR: system default did not switch to \(override.name) within 1s — aborting")
                    restoreSystemDefaultIfNeeded()
                    return
                }
            }
        }

        do {
            audioEngine = AVAudioEngine()
            guard let audioEngine = audioEngine else { return }

            let inputNode = audioEngine.inputNode
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
        guard let audioEngine = audioEngine else {
            restoreSystemDefaultIfNeeded()
            return
        }

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        self.audioEngine = nil
        self.audioFile = nil  // dropping the reference flushes/finalizes the WAV header

        restoreSystemDefaultIfNeeded()
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

    private func restoreSystemDefaultIfNeeded() {
        guard let saved = savedSystemDefaultDeviceID else { return }
        savedSystemDefaultDeviceID = nil
        if Self.setDefaultInputDevice(saved) {
            let name = Self.stringProperty(saved, kAudioObjectPropertyName) ?? "<unnamed>"
            print("Restored system default input to: \(name)")
        } else {
            print("WARNING: failed to restore system default input device")
        }
    }

    static func currentDefaultInputDeviceID() -> AudioDeviceID? {
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
        return (status == noErr && deviceID != 0) ? deviceID : nil
    }

    @discardableResult
    static func setDefaultInputDevice(_ id: AudioDeviceID) -> Bool {
        var devID = id
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &devID
        )
        return status == noErr
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
        return makeInfo(for: deviceID)
    }

    static func allInputDevices() -> [InputDeviceInfo] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceIDs) == noErr else {
            return []
        }
        return deviceIDs.compactMap { id in
            guard inputChannelCount(id) > 0 else { return nil }  // input-capable only
            return makeInfo(for: id)
        }
    }

    /// Find an input device by case-insensitive substring match on its name.
    static func findInputDevice(matching query: String) -> InputDeviceInfo? {
        let lower = query.lowercased()
        let devices = allInputDevices()
        // Prefer exact match first, then substring.
        if let exact = devices.first(where: { $0.name.lowercased() == lower }) {
            return exact
        }
        return devices.first { $0.name.lowercased().contains(lower) }
    }

    private static func makeInfo(for deviceID: AudioDeviceID) -> InputDeviceInfo {
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
