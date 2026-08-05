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
    /// Raw-RMS level above which a buffer counts as voice, for the silence
    /// guard. NOT the same scale as `calculateRMS`, which returns a display
    /// level (rms * 5) — the guard is calibrated against raw RMS.
    var silenceFloor: Float = 0.01
    /// Seconds of voice-level audio in the current recording.
    private(set) var voicedSeconds: Double = 0
    /// Saved system default before we switched it; restored on stopRecording.
    private var savedSystemDefaultDeviceID: AudioDeviceID?
    /// Decaying reference level used to normalise the spectrum across frames.
    private var spectrumPeak: Float = 0
    private var lastSpectrumTime = Date()
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
            voicedSeconds = 0
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

    /// Set YAPLESS_DEBUG_SPECTRUM=1 to print what the bars are actually being
    /// fed — the only way to tell "the display is wrong" from "the mic is quiet"
    /// without standing in front of the screen.
    private static let debugSpectrum = ProcessInfo.processInfo.environment["YAPLESS_DEBUG_SPECTRUM"] == "1"
    private var lastSpectrumLog: Date = .distantPast

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        let level = calculateRMS(buffer: buffer)
        let spectrum = calculateSpectrum(buffer: buffer)

        if Self.debugSpectrum, Date().timeIntervalSince(lastSpectrumLog) > 0.25 {
            lastSpectrumLog = Date()
            let shown = spectrum[3..<min(13, spectrum.count)]
            let bars = shown.map { String(format: "%.2f", $0) }.joined(separator: " ")
            print(String(format: "spectrum rms=%.4f ref=%.4f | %@", level, spectrumPeak, bars))
        }

        // Diagnostic: track raw signal stats and log every ~1s so we know if mic is silent.
        if let channelData = buffer.floatChannelData?[0] {
            var peak: Float = 0
            vDSP_maxmgv(channelData, 1, &peak, vDSP_Length(buffer.frameLength))
            var rms: Float = 0
            vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(buffer.frameLength))
            bufferMaxSample = max(bufferMaxSample, peak)
            bufferRMSSum += rms
            bufferCount += 1

            if rms > silenceFloor, buffer.format.sampleRate > 0 {
                voicedSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
            }

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

        var framePeak: Float = 0
        vDSP_maxmgv(channelData, 1, &framePeak, vDSP_Length(buffer.frameLength))

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
        let binCount = fftSize / 2
        let binWidth = Float(buffer.format.sampleRate) / Float(fftSize)

        // Log-spaced across the speech range. The old mapping spread bands over
        // bin *indices*, which handed the top half of the bands everything above
        // ~1kHz — where voice has almost no energy — so those bars never moved.
        let lowestHz: Float = 80
        let highestHz = min(8000, Float(buffer.format.sampleRate) / 2 * 0.9)
        let ratio = highestHz / lowestHz

        for band in 0..<frequencyBands {
            let lowHz = lowestHz * pow(ratio, Float(band) / Float(frequencyBands))
            let highHz = lowestHz * pow(ratio, Float(band + 1) / Float(frequencyBands))

            let start = max(1, Int(lowHz / binWidth))
            let end = min(binCount, max(start + 1, Int(highHz / binWidth)))

            guard end > start else { continue }

            // `&magnitudes[start]` looks like C pointer arithmetic but isn't:
            // Swift hands an inout element a pointer to a TEMPORARY holding
            // that one value, so vDSP read `end - start` floats of whatever
            // followed it on the stack. That garbage is where the inf came
            // from — one inf in a band poisons the reference level and every
            // bar divides to zero. This is the actual "deeply wrong" bug.
            var sum: Float = 0
            magnitudes.withUnsafeBufferPointer { buffer in
                vDSP_sve(buffer.baseAddress! + start, 1, &sum, vDSP_Length(end - start))
            }

            // Voice rolls off with frequency; without a tilt the high bands are
            // permanently dwarfed by the fundamental.
            // Linear tilt, measured rather than guessed: with sqrt, only the
            // bottom 3 bars ever cleared the 30dB window on real speech.
            let centreHz = (lowHz + highHz) / 2
            let tilt = centreHz / lowestHz
            bands[band] = (sum / Float(end - start)) * tilt
        }

        var frameMax: Float = 0
        vDSP_maxv(bands, 1, &frameMax, vDSP_Length(frequencyBands))

        // Reference level: a slowly decaying peak, so the display adapts to how
        // hot the mic runs without chasing every syllable.
        let now = Date()
        let dt = Float(min(max(now.timeIntervalSince(lastSpectrumTime), 0.001), 0.25))
        lastSpectrumTime = now
        spectrumPeak = max(frameMax, spectrumPeak * exp(-dt / 3.0))

        // dB scale over a fixed 30dB window, then an absolute loudness gate.
        //
        // Per-band auto-gain was the wrong idea: giving every band its own
        // floor and ceiling means room tone gets stretched to full height, so
        // the display looks busy when nothing is happening and stops tracking
        // what you actually said. Measured against real recordings, this scheme
        // reads flat on silence and correlates 0.81 with loudness on speech;
        // the per-band version managed 0.48 and lit up 97% of silent frames.
        let reference = max(spectrumPeak, 1e-6)
        let span: Float = 30
        let gate = min(1, framePeak / 0.03)

        for i in 0..<frequencyBands {
            let relative = max(bands[i] / reference, 1e-5)
            let decibels = 20 * log10(relative)
            bands[i] = min(1, max(0, (decibels + span) / span)) * gate
        }

        return bands
    }

    struct InputDeviceInfo {
        let id: AudioDeviceID
        let name: String
        let uid: String
        let sampleRate: Double
        let channels: UInt32
        let transportType: UInt32

        /// Opening a bluetooth input forces the headset into its bidirectional
        /// call profile, which degrades playback and steals the headset from
        /// whatever else was using it (phone, iPad).
        var isBluetooth: Bool {
            transportType == kAudioDeviceTransportTypeBluetooth
                || transportType == kAudioDeviceTransportTypeBluetoothLE
        }

        /// Loopback/aggregate devices (BlackHole, Zoom, virtual cams) — real
        /// audio never comes from these unless asked for by name.
        var isVirtual: Bool {
            transportType == kAudioDeviceTransportTypeVirtual
                || transportType == kAudioDeviceTransportTypeAggregate
        }

        var transportLabel: String {
            switch transportType {
            case kAudioDeviceTransportTypeBuiltIn: return "built-in"
            case kAudioDeviceTransportTypeUSB: return "usb"
            case kAudioDeviceTransportTypeBluetooth: return "bluetooth"
            case kAudioDeviceTransportTypeBluetoothLE: return "bluetooth-le"
            case kAudioDeviceTransportTypeVirtual: return "virtual"
            case kAudioDeviceTransportTypeAggregate: return "aggregate"
            case kAudioDeviceTransportTypeContinuityCaptureWired,
                 kAudioDeviceTransportTypeContinuityCaptureWireless: return "continuity"
            default: return "other"
            }
        }
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

    /// How the input device was chosen — the caller decides what to do when
    /// the configured devices simply are not present.
    enum InputSelection {
        case chosen(InputDeviceInfo, reason: String)
        case unavailable(reason: String)
    }

    /// Resolve which mic to open from config, without ever opening one.
    ///
    /// Precedence: explicit `--input` (handled by the caller) → `inputPriority`
    /// allow-list → `inputDevice` → system default. Nothing is inferred: if the
    /// system default turns out to be excluded, yapless says so rather than
    /// quietly substituting a device the user never named.
    static func resolveInputDevice(config: AudioConfig) -> InputSelection {
        let devices = allInputDevices()

        if !config.inputPriority.isEmpty {
            for query in config.inputPriority {
                // "default" isn't naming a device, so exclusions still apply to
                // whatever it resolves to; a named entry means you want it.
                if query.lowercased() == AudioConfig.systemDefaultKeyword,
                   let fallback = defaultInputDeviceInfo() {
                    if exclusionRule(for: fallback, config: config) != nil { continue }
                    return .chosen(fallback, reason: "inputPriority → system default")
                }
                if let match = match(query, in: devices) {
                    return .chosen(match, reason: "inputPriority '\(query)'")
                }
            }
            // The list is an allow-list: never silently fall back to a device
            // the user deliberately left off it.
            return .unavailable(
                reason: "none of inputPriority \(config.inputPriority) are connected"
            )
        }

        if let requested = config.inputDevice, !requested.isEmpty {
            if requested.lowercased() == AudioConfig.systemDefaultKeyword {
                guard let info = defaultInputDeviceInfo() else {
                    return .unavailable(reason: "no system default input device")
                }
                if let rule = exclusionRule(for: info, config: config) {
                    return .unavailable(
                        reason: "inputDevice 'default' resolves to \(info.name), excluded by \(rule)"
                    )
                }
                return .chosen(info, reason: "config inputDevice 'default'")
            }
            guard let match = match(requested, in: devices) else {
                return .unavailable(reason: "config inputDevice '\(requested)' is not connected")
            }
            return .chosen(match, reason: "config inputDevice '\(requested)'")
        }

        guard let systemDefault = defaultInputDeviceInfo() else {
            return .unavailable(reason: "no system default input device")
        }

        if let rule = exclusionRule(for: systemDefault, config: config) {
            return .unavailable(
                reason: "system default is \(systemDefault.name), excluded by \(rule) — "
                    + "name the mic you want in audio.inputPriority"
            )
        }

        return .chosen(systemDefault, reason: "system default")
    }

    /// Why a device is off-limits, or nil if it isn't.
    private static func exclusionRule(for device: InputDeviceInfo, config: AudioConfig) -> String? {
        for excluded in config.excludeInputs {
            let lower = excluded.lowercased()
            if device.name.lowercased().contains(lower) || device.uid.lowercased().contains(lower) {
                return "excludeInputs '\(excluded)'"
            }
        }
        if config.avoidBluetoothInput && device.isBluetooth {
            return "avoidBluetoothInput"
        }
        return nil
    }

    private static func match(_ query: String, in devices: [InputDeviceInfo]) -> InputDeviceInfo? {
        let lower = query.lowercased()
        if let exact = devices.first(where: { $0.name.lowercased() == lower || $0.uid == query }) {
            return exact
        }
        return devices.first {
            $0.name.lowercased().contains(lower) || $0.uid.lowercased().contains(lower)
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
            channels: inputChannelCount(deviceID),
            transportType: uint32Property(deviceID, kAudioDevicePropertyTransportType) ?? 0
        )
    }

    private static func uint32Property(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value)
        return status == noErr ? value : nil
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
