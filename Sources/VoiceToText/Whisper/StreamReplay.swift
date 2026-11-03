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
}
