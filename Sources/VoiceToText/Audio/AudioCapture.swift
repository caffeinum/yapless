import AVFoundation
import Accelerate
import AudioToolbox
import CoreAudio

final class AudioCapture {
    /// A raw AUHAL bound to the chosen device by ID.
    ///
    /// AVAudioEngine can't do this: its input node always captures through a
    /// private `CADefaultDeviceAggregate` built from the SYSTEM DEFAULT input,
    /// and setting `kAudioOutputUnitProperty_CurrentDevice` on it is silently
    /// replaced by that aggregate (measured — it bound the bluetooth default
    /// instead of the requested mic). So picking a mic used to mean swapping
    /// the global default, which every other app saw, which a crash left
    /// swapped, and which cost 300-1350ms per start. AUHAL opens exactly the
    /// device it is given and starts in about half the time of the engine.
    private var inputUnit: AudioUnit?
    /// Device-rate, mono Float32 — what the AUHAL hands us.
    private var captureFormat: AVAudioFormat?
    private var maxFramesPerSlice: AVAudioFrameCount = 4096
    /// One converter for the whole recording: a sample-rate converter keeps
    /// filter state between buffers, and a fresh one per ~10ms slice would
    /// put a discontinuity at every slice boundary.
    private var converter: AVAudioConverter?
    /// The IO thread only renders and hands off; levels, FFT, file writes and
    /// the caption tail all happen here, in order.
    private let processingQueue = DispatchQueue(label: "yapless.audio.process", qos: .userInteractive)
    private var audioFile: AVAudioFile?
    private(set) var recordingURL: URL?

    var onAudioLevel: ((Float) -> Void)?
    var onFrequencySpectrum: (([Float]) -> Void)?
    /// Recording never started. Every one of these paths used to print and
    /// return, leaving the overlay up over a mic that wasn't running and no
    /// sound to say so — a failure that looked exactly like listening.
    var onStartFailure: ((String) -> Void)?
    /// Fires on main when the first slice arrives — the moment the mic is
    /// actually live, which is what a start cue should mean.
    var onFirstBuffer: (() -> Void)?
    /// Every converted 16k mono buffer, on the processing queue. Feeds streaming ASR.
    var onConvertedBuffer: ((AVAudioPCMBuffer) -> Void)?

    private let fftSize = 512
    private var fftSetup: vDSP_DFT_Setup?
    private let frequencyBands = 14

    private var completionHandler: ((URL) -> Void)?
    private let recordingFormat: AVAudioFormat
    /// The device to capture from. nil means the system default, resolved at
    /// start — either way the unit is bound to an explicit device ID.
    var preferredDevice: InputDeviceInfo?
    /// Raw-RMS level above which a buffer counts as voice, for the silence
    /// guard. NOT the same scale as `calculateRMS`, which returns a display
    /// level (rms * 5) — the guard is calibrated against raw RMS.
    var silenceFloor: Float = 0.01
    /// Seconds of voice-level audio in the current recording.
    private(set) var voicedSeconds: Double = 0

    /// Rolling tail of the recording (16k mono Int16), for live captions.
    /// The WAV on disk can't be read mid-write — its header says 0 bytes
    /// until the file is finalized — so captioning reads from here instead.
    private let tailLock = NSLock()
    private var tailSamples: [Int16] = []
    private let tailMaxSamples = 16_000 * 12
    /// Decaying reference level used to normalise the spectrum across frames.
    private var spectrumPeak: Float = 0
    private var lastSpectrumTime = Date()
    private var bufferCount: Int = 0
    private var sawFirstBuffer = false
    /// AUHAL hands over ~10ms slices; levels, the silence guard and the stats
    /// were tuned on the engine's ~100ms buffers, so slices are gathered back
    /// into blocks of that size before analysis. Processing queue only.
    private var block: AVAudioPCMBuffer?
    private var droppedSlices = 0
    private var bufferMaxSample: Float = 0
    private var bufferRMSSum: Float = 0
    private var lastStatsLog: Date = .distantPast
    /// Serialises start/stop so a stop that arrives mid-start still happens
    /// after it, now that start runs off the main thread.
    private let controlQueue = DispatchQueue(label: "yapless.audio.control", qos: .userInteractive)

    init() {
        self.recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD)
    }

    /// The IO callback holds an unretained pointer to self.
    deinit { teardownInputUnit() }

    func requestPermission(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    /// Bring the mic up without waiting for the UI.
    ///
    /// CoreAudio setup is ~190ms of HAL work that has nothing to do with
    /// drawing an overlay, so the two run concurrently and the microphone is
    /// live sooner. Ordering against stop is the controlQueue's job.
    func startRecordingInBackground(completion: @escaping (URL) -> Void) {
        controlQueue.async { [weak self] in
            self?.startRecording(completion: completion)
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

        guard let recordingURL = recordingURL else {
            reportStartFailure("could not build a path for the recording")
            return
        }

        guard let device = preferredDevice ?? Self.defaultInputDeviceInfo() else {
            reportStartFailure("no input device — CoreAudio reports no system default input")
            return
        }
        let source = preferredDevice != nil ? "override" : "system default"
        print("Input device (\(source)): \(device.name) [uid=\(device.uid), id=\(device.id), \(Int(device.sampleRate))Hz, \(device.channels)ch]")

        bufferCount = 0
        sawFirstBuffer = false
        droppedSlices = 0
        block = nil
        bufferMaxSample = 0
        bufferRMSSum = 0
        voicedSeconds = 0
        lastStatsLog = Date()
        tailLock.lock(); tailSamples.removeAll(keepingCapacity: true); tailLock.unlock()

        do {
            let unit = try Self.makeInputUnit(for: device.id)
            inputUnit = unit

            let deviceFormat = try Self.streamFormat(unit, scope: kAudioUnitScope_Input, element: 1)
            print("Input format: \(Int(deviceFormat.mSampleRate))Hz, \(deviceFormat.mChannelsPerFrame)ch")
            guard deviceFormat.mChannelsPerFrame > 0, deviceFormat.mSampleRate > 0 else {
                throw CaptureError(
                    "input format invalid (\(deviceFormat.mChannelsPerFrame)ch @ \(Int(deviceFormat.mSampleRate))Hz) — "
                    + "mic likely unavailable; check Settings → Privacy → Microphone"
                )
            }

            // Mono at the device rate: AUHAL maps the first device channel to
            // it. It will not resample on the input side, so 16k happens in
            // the converter below.
            guard let capture = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: deviceFormat.mSampleRate,
                channels: 1, interleaved: false
            ) else {
                throw CaptureError("could not describe a \(Int(deviceFormat.mSampleRate))Hz mono capture format")
            }
            var clientFormat = capture.streamDescription.pointee
            try Self.check(
                AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                     &clientFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                "set capture format"
            )
            captureFormat = capture

            guard let converter = AVAudioConverter(from: capture, to: recordingFormat) else {
                throw CaptureError("no converter from \(Int(capture.sampleRate))Hz to 16kHz")
            }
            self.converter = converter

            var maxFrames: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            try Self.check(
                AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                     &maxFrames, &size),
                "read max frames per slice"
            )
            maxFramesPerSlice = maxFrames

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

            var callback = AURenderCallbackStruct(
                inputProc: audioCaptureInputProc,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try Self.check(
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                     &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                "set input callback"
            )
            try Self.check(AudioUnitInitialize(unit), "initialize input unit")
            try Self.check(AudioOutputUnitStart(unit), "start input unit")

            print("Recording started to \(recordingURL.path)")
        } catch {
            teardownInputUnit()
            audioFile = nil
            reportStartFailure("failed to start recording: \(error)")
        }
    }

    struct CaptureError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw CaptureError("\(step) failed (OSStatus \(status))") }
    }

    /// Input-only AUHAL on `deviceID`. Output is disabled before the device is
    /// set, so nothing is ever opened for playback.
    private static func makeInputUnit(for deviceID: AudioDeviceID) throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CaptureError("no HAL output audio unit on this system")
        }
        var instance: AudioUnit?
        try check(AudioComponentInstanceNew(component, &instance), "create input unit")
        guard let unit = instance else { throw CaptureError("create input unit returned nil") }

        do {
            var enable: UInt32 = 1
            var disable: UInt32 = 0
            let flagSize = UInt32(MemoryLayout<UInt32>.size)
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                                           &enable, flagSize), "enable input")
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                                           &disable, flagSize), "disable output")
            var device = deviceID
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                           &device, UInt32(MemoryLayout<AudioDeviceID>.size)),
                      "bind input unit to device \(deviceID)")
            return unit
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    private static func streamFormat(_ unit: AudioUnit, scope: AudioUnitScope, element: AudioUnitElement) throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, scope, element, &format, &size),
                  "read device stream format")
        return format
    }

    /// Runs on the HAL IO thread: pull the slice out of the unit and queue it.
    fileprivate func renderInput(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        bus: UInt32,
        frames: UInt32
    ) -> OSStatus {
        guard let unit = inputUnit, let format = captureFormat,
              frames <= maxFramesPerSlice,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            processingQueue.async { [weak self] in self?.droppedSlices += 1 }
            return kAudioUnitErr_CannotDoInCurrentContext
        }
        buffer.frameLength = frames
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, buffer.mutableAudioBufferList)
        guard status == noErr else {
            processingQueue.async { [weak self] in self?.droppedSlices += 1 }
            return status
        }
        processingQueue.async { [weak self] in self?.gather(buffer) }
        return noErr
    }

    private func reportStartFailure(_ reason: String) {
        print("ERROR: \(reason)")
        let handler = onStartFailure
        DispatchQueue.main.async { handler?(reason) }
    }

    func stopRecording() {
        // Blocks only if a start is still in flight — correct ordering beats a
        // stop that races an engine which isn't running yet.
        controlQueue.sync { self.stopRecordingLocked() }
    }

    private func stopRecordingLocked() {
        guard inputUnit != nil else { return }

        teardownInputUnit()
        // Every slice the IO thread queued lands before the file is closed.
        processingQueue.sync {
            self.flushBlock()
            self.flushConverter()
            if self.droppedSlices > 0 {
                print("WARNING: \(self.droppedSlices) audio slices dropped — the recording has gaps")
            }
            self.audioFile = nil  // dropping the reference finalizes the WAV header
        }
        converter = nil
        print("Recording stopped")

        if let recordingURL = recordingURL {
            // Everything downstream touches UI, so hand back on main.
            let handler = completionHandler
            DispatchQueue.main.async { handler?(recordingURL) }
        }
    }

    private func teardownInputUnit() {
        guard let unit = inputUnit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        inputUnit = nil
    }

    /// Set YAPLESS_DEBUG_SPECTRUM=1 to print what the bars are actually being
    /// fed — the only way to tell "the display is wrong" from "the mic is quiet"
    /// without standing in front of the screen.
    private static let debugSpectrum = ProcessInfo.processInfo.environment["YAPLESS_DEBUG_SPECTRUM"] == "1"
    private var lastSpectrumLog: Date = .distantPast

    private func gather(_ slice: AVAudioPCMBuffer) {
        if !sawFirstBuffer {
            sawFirstBuffer = true
            print("First audio buffer")
            let handler = onFirstBuffer
            DispatchQueue.main.async { handler?() }
        }
        let blockFrames = AVAudioFrameCount(slice.format.sampleRate / 10)
        if block == nil {
            block = AVAudioPCMBuffer(pcmFormat: slice.format, frameCapacity: blockFrames + maxFramesPerSlice)
        }
        guard let block = block, let dst = block.floatChannelData?[0], let src = slice.floatChannelData?[0] else {
            fatalError("could not allocate a \(blockFrames)-frame analysis block")
        }
        (dst + Int(block.frameLength)).update(from: src, count: Int(slice.frameLength))
        block.frameLength += slice.frameLength
        if block.frameLength >= blockFrames { flushBlock() }
    }

    private func flushBlock() {
        guard let full = block, full.frameLength > 0 else { return }
        block = nil
        processAudioBuffer(full)
    }

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

        guard let converted = convert(buffer, endOfStream: false) else { return }
        store(converted)
    }

    /// Converter output → the WAV and the caption tail. Processing queue only.
    private func store(_ converted: AVAudioPCMBuffer) {
        guard converted.frameLength > 0, let audioFile = audioFile else { return }
        do {
            try audioFile.write(from: converted)
        } catch {
            print("Failed to write audio buffer: \(error)")
        }
        appendToTail(converted)
        onConvertedBuffer?(converted)
    }

    /// The resampler holds a few ms of history; drain it so the end of the
    /// last word reaches the file.
    private func flushConverter() {
        guard let converted = convert(nil, endOfStream: true) else { return }
        store(converted)
    }

    /// Device rate → 16k mono through the recording-long converter. `nil`
    /// with endOfStream drains it.
    private func convert(_ buffer: AVAudioPCMBuffer?, endOfStream: Bool) -> AVAudioPCMBuffer? {
        guard let converter = converter else { return nil }
        let ratio = recordingFormat.sampleRate / converter.inputFormat.sampleRate
        let inputFrames = Double(buffer?.frameLength ?? 0)
        // Slack for the samples the resampler was holding from the last call.
        let capacity = AVAudioFrameCount((inputFrames * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: recordingFormat, frameCapacity: capacity) else {
            print("Audio conversion error: could not allocate \(capacity)-frame buffer")
            return nil
        }

        var pending = buffer
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if let next = pending {
                pending = nil
                outStatus.pointee = .haveData
                return next
            }
            outStatus.pointee = endOfStream ? .endOfStream : .noDataNow
            return nil
        }
        if status == .error {
            print("Audio conversion error: \(error.map { "\($0)" } ?? "unknown")")
            return nil
        }
        return output
    }

    /// Captions feed whisper a 16-bit WAV; the recording path is Float32.
    private func appendToTail(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        var scaled = [Float](repeating: 0, count: count)
        var scale: Float = 32767
        var low: Float = -32768
        var high: Float = 32767
        vDSP_vsmul(data, 1, &scale, &scaled, 1, vDSP_Length(count))
        vDSP_vclip(scaled, 1, &low, &high, &scaled, 1, vDSP_Length(count))
        var samples = [Int16](repeating: 0, count: count)
        vDSP_vfixr16(scaled, 1, &samples, 1, vDSP_Length(count))

        tailLock.lock()
        tailSamples.append(contentsOf: samples)
        if tailSamples.count > tailMaxSamples {
            tailSamples.removeFirst(tailSamples.count - tailMaxSamples)
        }
        tailLock.unlock()
    }

    /// The last `seconds` of the recording as a complete, self-contained WAV.
    /// Returns nil until there's at least a second of audio to work with.
    func tailWAVData(seconds: Double) -> Data? {
        tailLock.lock()
        let wanted = min(tailSamples.count, Int(seconds * 16_000))
        let samples = Array(tailSamples.suffix(wanted))
        tailLock.unlock()

        guard samples.count >= 16_000 else { return nil }

        let byteCount = samples.count * 2
        var data = Data(capacity: 44 + byteCount)
        func put(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put(16)
        put16(1); put16(1)              // PCM, mono
        put(16_000); put(32_000)        // sample rate, byte rate
        put16(2); put16(16)             // block align, bits
        data.append(contentsOf: Array("data".utf8)); put(UInt32(byteCount))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
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

    /// Last resolution, remembered so the next launch doesn't re-derive it.
    ///
    /// Enumerating every device costs ~85 CoreAudio property reads (~190ms of
    /// IPC to coreaudiod) to answer a question whose answer almost never
    /// changes. The cache is validated with ONE read — does that device ID
    /// still carry that UID — and any mismatch falls back to the full walk.
    private struct DeviceCache: Codable {
        let query: String
        let id: UInt32
        let uid: String
        let name: String
        let sampleRate: Double
        let channels: UInt32
        let transportType: UInt32

        var info: InputDeviceInfo {
            InputDeviceInfo(id: id, name: name, uid: uid, sampleRate: sampleRate,
                            channels: channels, transportType: transportType)
        }
    }

    private static var deviceCacheURL: URL {
        StorageConfig.dataDirectory.appendingPathComponent("input-device-cache.json")
    }

    /// Everything about the config that could change the answer. A config edit
    /// changes this string, which invalidates the cache without a version bump.
    private static func cacheKey(_ config: AudioConfig) -> String {
        [
            config.inputDevice ?? "",
            config.inputPriority.joined(separator: "|"),
            config.excludeInputs.joined(separator: "|"),
            String(config.avoidBluetoothInput)
        ].joined(separator: "\u{1}")
    }

    private static func cachedDevice(for config: AudioConfig) -> InputDeviceInfo? {
        guard let data = try? Data(contentsOf: deviceCacheURL),
              let cache = try? JSONDecoder().decode(DeviceCache.self, from: data),
              cache.query == cacheKey(config) else { return nil }

        // One property read: device IDs are reused across reboots and
        // reconnects, so the UID is what actually identifies the hardware.
        guard stringProperty(cache.id, kAudioDevicePropertyDeviceUID) == cache.uid else {
            return nil
        }
        return cache.info
    }

    private static func remember(_ device: InputDeviceInfo, for config: AudioConfig) {
        let cache = DeviceCache(
            query: cacheKey(config), id: device.id, uid: device.uid, name: device.name,
            sampleRate: device.sampleRate, channels: device.channels,
            transportType: device.transportType
        )
        try? FileManager.default.createDirectory(
            at: StorageConfig.dataDirectory, withIntermediateDirectories: true
        )
        try? JSONEncoder().encode(cache).write(to: deviceCacheURL)
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
        if let cached = cachedDevice(for: config) {
            return .chosen(cached, reason: "cached")
        }

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
                    remember(match, for: config)
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
            remember(match, for: config)
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
}

/// HAL input callback. A C function pointer can't capture, so the capture
/// object rides in the refCon.
private func audioCaptureInputProc(
    refCon: UnsafeMutableRawPointer,
    flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    timeStamp: UnsafePointer<AudioTimeStamp>,
    bus: UInt32,
    frames: UInt32,
    data: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let capture = Unmanaged<AudioCapture>.fromOpaque(refCon).takeUnretainedValue()
    return capture.renderInput(flags: flags, timeStamp: timeStamp, bus: bus, frames: frames)
}
