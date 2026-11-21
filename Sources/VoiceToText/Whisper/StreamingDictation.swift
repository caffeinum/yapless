import AVFoundation
import CoreML
import FluidAudio
import Foundation

/// One recording's streaming transcription on a resident FluidAudio model.
///
/// Audio arriving before the model is loaded is queued, not dropped, so the
/// first words survive the 0.2-1s load (30-90s the very first time, while
/// CoreML compiles). Words are committed only once a later word follows them
/// — the last word of a partial can still be mid-token ("sc" → "screen").
final class StreamingDictation {
    /// Main queue. `committed` only grows; `tentative` is the unconfirmed tail.
    var onUpdate: ((_ committed: [String], _ tentative: String) -> Void)?
    /// Main queue. Words that just became committed.
    var onCommit: (([String]) -> Void)?

    private let variant: StreamingModelVariant
    private let stream: AsyncStream<AVAudioPCMBuffer>
    private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    private var worker: Task<String, Error>?
    private var committed: [String] = []
    private var diverged = false
    /// Main queue. False until the model is loaded — after a CoreML cache
    /// eviction that takes 1-2 minutes, which nobody should wait for at stop.
    private(set) var isLoaded = false

    init(modelName: String) throws {
        guard let variant = StreamingModelVariant(rawValue: modelName) else {
            throw NSError(domain: "yapless.live", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "unknown liveModel '\(modelName)'; one of \(StreamingModelVariant.allCases.map(\.rawValue))"])
        }
        self.variant = variant
        (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
    }

    func start() {
        let config = MLModelConfiguration()
        // Measured: ~1.2s cpu per 28.7s clip on the ANE, ~10s on GPU, ~25s on CPU.
        config.computeUnits = .cpuAndNeuralEngine
        let manager = variant.createManager(configuration: config)
        let name = variant.rawValue

        worker = Task.detached(priority: .userInitiated) { [weak self, stream] in
            let t0 = Date()
            try await manager.loadModels()
            print(String(format: "live: %@ loaded in %.2fs", name, Date().timeIntervalSince(t0)))
            DispatchQueue.main.async { self?.isLoaded = true }

            var last = ""
            var lastChange = Date()
            var settled = false
            for await buffer in stream {
                try await manager.appendAudio(buffer)
                try await manager.processBufferedAudio()
                let partial = await manager.getPartialTranscript()
                if partial != last {
                    last = partial
                    lastChange = Date()
                    settled = false
                    self?.handle(partial: partial, includeLast: false)
                } else if !settled, Date().timeIntervalSince(lastChange) >= Self.settleSeconds {
                    // A whole model step went by without the last word changing,
                    // so it is not a fragment: type it instead of waiting for
                    // the next word or for stop.
                    settled = true
                    self?.handle(partial: partial, includeLast: true)
                }
            }

            // Without trailing silence the last word or two never decode.
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
            let pad = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
            pad.frameLength = 16_000
            memset(pad.floatChannelData![0], 0, 16_000 * MemoryLayout<Float>.size)
            try await manager.appendAudio(pad)
            try await manager.processBufferedAudio()
            return try await manager.finish().trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Audio thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        continuation.yield(buffer)
    }

    /// Ends the stream and delivers the final transcript on the main queue.
    func finish(completion: @escaping (Result<String, Error>) -> Void) {
        continuation.finish()
        guard let worker else {
            return completion(.failure(NSError(domain: "yapless.live", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "streaming never started"])))
        }
        Task {
            let result = await worker.result
            DispatchQueue.main.async { completion(result) }
        }
    }

    func cancel() {
        continuation.finish()
        worker?.cancel()
    }

    /// Longer than one 1120ms model step, so an unchanged partial means the
    /// model has seen audio past the last word.
    static let settleSeconds: TimeInterval = 1.5

    private func handle(partial: String, includeLast: Bool) {
        DispatchQueue.main.async { [self] in
            let words = partial.split(whereSeparator: \.isWhitespace).map(String.init)
            if !diverged {
                switch Self.newlyCommitted(words: words, committed: committed, includeLast: includeLast) {
                case .some(let fresh) where !fresh.isEmpty:
                    committed += fresh
                    onCommit?(fresh)
                case .some:
                    break
                case .none:
                    // Append-only engine, so this should not happen; if it does,
                    // stop committing rather than type text that disagrees.
                    diverged = true
                    print("live: partial diverged from committed words — committing stopped, stop-time reconcile will finish")
                }
            }
            let tail = words.count > committed.count ? words[committed.count...].joined(separator: " ") : ""
            onUpdate?(committed, tail)
        }
    }

    /// Words of `words` past `committed`, holding back the last one unless
    /// `includeLast`. nil when the partial no longer starts with what was committed.
    static func newlyCommitted(words: [String], committed: [String], includeLast: Bool = false) -> [String]? {
        let stable = includeLast ? words[...] : words.dropLast()
        guard stable.count >= committed.count else {
            return zip(stable, committed).allSatisfy { normalize($0) == normalize($1) } ? [] : nil
        }
        for (a, b) in zip(stable, committed) where normalize(a) != normalize(b) { return nil }
        return Array(stable[committed.count...])
    }

    static func normalize(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }
}
