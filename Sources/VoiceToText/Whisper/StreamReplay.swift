import AVFoundation
import Foundation

/// `--stream-file`: drive StreamingDictation from a saved recording at
/// real-time pace, printing each commit with its lag behind the audio. The
/// live path's behaviour, reproducible without a mic or a focused field.
enum StreamReplay {
    static func run(path: String, model: String) throws {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let format = file.processingFormat
        let chunk = AVAudioFrameCount(format.sampleRate / 10)
        let dictation = try StreamingDictation(modelName: model)

        let start = Date()
        var fed = 0.0
        var done = false
        var final: Result<String, Error>?

        dictation.onCommit = { words in
            print(String(format: "%6.2fs  audio %6.2fs  + %@", Date().timeIntervalSince(start), fed, words.joined(separator: " ")))
        }
        dictation.start()

        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
                      (try? file.read(into: buffer, frameCount: chunk)) != nil,
                      buffer.frameLength > 0 else { break }
                dictation.append(buffer)
                fed += Double(buffer.frameLength) / format.sampleRate
                let ahead = fed - Date().timeIntervalSince(start)
                if ahead > 0 { Thread.sleep(forTimeInterval: ahead) }
            }
            let stopped = Date()
            DispatchQueue.main.async {
                dictation.finish { result in
                    print(String(format: "final after %.2fs:", Date().timeIntervalSince(stopped)))
                    final = result
                    done = true
                }
            }
        }

        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        print(try final!.get())
    }

    /// `--warm-live`: load the streaming model and exit, so CoreML's compiled
    /// cache is hot for the next recording. Compiling takes 40-140s and a
    /// recording process exits long before that, so without a separate warm-up
    /// a cold cache would stay cold forever. One warm-up at a time.
    static func warm(model: String) throws {
        let path = StorageConfig.dataDirectory.appendingPathComponent("warm-live.lock").path
        let fd = open(path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { throw NSError(domain: "yapless.live", code: 3, userInfo: [NSLocalizedDescriptionKey: "cannot open \(path)"]) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            print("live: warm-up already running")
            return
        }
        let dictation = try StreamingDictation(modelName: model)
        var done = false
        dictation.start()
        dictation.finish { result in
            if case .failure(let error) = result { print("live: warm-up failed: \(error.localizedDescription)") }
            done = true
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        print("live: warm-up done")
    }
}
