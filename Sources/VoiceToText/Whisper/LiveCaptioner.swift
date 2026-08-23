import Foundation

/// Live captions while recording: every `interval`, transcribe the last few
/// seconds of audio with whisper.cpp and feed the overlay a caption line.
///
/// Re-transcribing a sliding window gives slightly different text each pass,
/// and a caption that rewrites itself is worse than none. So nothing is shown
/// until two consecutive passes agree on it (LocalAgreement-2): a word enters
/// `committed` only when the previous hypothesis and the current one both
/// start with it, and `committed` is append-only — displayed text never
/// changes, it only grows. The cost is a ~one-pass lag behind speech.
///
/// This is a preview. The pasted text always comes from the full
/// transcription at stop; nothing here touches that path.
final class LiveCaptioner {
    private let binaryPath: String
    private let modelPath: String
    private let language: String?
    private let prompt: String?
    private let interval: TimeInterval
    private let windowSeconds: Double

    private let queue = DispatchQueue(label: "yapless.captions", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var busy = false

    private var committed: [String] = []
    private var pendingWords: [String] = []

    private let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("yapless-caption-\(ProcessInfo.processInfo.processIdentifier).wav")

    var onCaption: ((String) -> Void)?

    init(binaryPath: String, modelPath: String, language: String?, prompt: String?,
         interval: TimeInterval = 1.5, windowSeconds: Double = 12) {
        self.binaryPath = binaryPath
        self.modelPath = modelPath
        self.language = language
        self.prompt = prompt
        self.interval = interval
        self.windowSeconds = windowSeconds
    }

    /// `audioProvider` returns the last N seconds of audio as a complete WAV,
    /// or nil if there isn't enough yet. Called on the caption queue.
    func start(audioProvider: @escaping () -> Data?) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self = self, !self.busy else { return }
            self.busy = true
            defer { self.busy = false }
            guard let wav = audioProvider() else { return }
            self.pass(wav: wav)
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        try? FileManager.default.removeItem(at: tempURL)
    }

    private func pass(wav: Data) {
        do {
            try wav.write(to: tempURL)
        } catch {
            return
        }
        guard let hypothesis = transcribe(tempURL.path) else { return }
        let words = hypothesis.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return }
        merge(words)
    }

    /// LocalAgreement-2 over a sliding window. The window's leading edge moves
    /// between passes, so the hypothesis is first aligned against what's
    /// already committed before comparing with the previous pass.
    ///
    /// The alignment tolerates noise on both sides: the window edge mangles
    /// the hypothesis's first words (`skip`), and a re-transcription sometimes
    /// drops a word we already committed (`drop`) — without that tolerance one
    /// vanished "yes," stalls the caption for the rest of the recording
    /// (measured, not hypothetical).
    private func merge(_ hypothesis: [String]) {
        var new = hypothesis
        var best = 0  // anchor length of the winning alignment
        var bestCut = 0  // words of the hypothesis consumed by it
        for drop in 0...min(3, committed.count) {
            let base = drop == 0 ? committed : Array(committed.dropLast(drop))
            for skip in 0...min(6, max(hypothesis.count - 1, 0)) {
                let maxK = min(base.count, hypothesis.count - skip)
                guard maxK > 0 else { continue }
                for k in stride(from: maxK, through: 1, by: -1) {
                    let window = hypothesis[skip..<(skip + k)]
                    guard zip(base.suffix(k), window).allSatisfy({ Self.same($0, $1) }) else { continue }
                    // A 1-word anchor is only trusted for the exact alignment.
                    if (k >= 2 || (drop == 0 && skip == 0)) && k > best {
                        best = k
                        bestCut = skip + k
                    }
                    break
                }
            }
        }
        if best > 0 { new = Array(hypothesis.dropFirst(bestCut)) }

        // Commit the words this pass and the previous one agree on.
        var agreed = 0
        while agreed < min(pendingWords.count, new.count),
              Self.same(pendingWords[agreed], new[agreed]) {
            agreed += 1
        }
        if agreed > 0 {
            committed.append(contentsOf: new.prefix(agreed))
            let text = committed.joined(separator: " ")
            DispatchQueue.main.async { [weak self] in self?.onCaption?(text) }
        }
        pendingWords = Array(new.dropFirst(agreed))
    }

    /// Word equality for agreement: case and trailing punctuation don't count
    /// as disagreement, or "hello," vs "hello" would stall the caption.
    private static func same(_ a: String, _ b: String) -> Bool {
        norm(a) == norm(b)
    }

    private static func norm(_ w: String) -> String {
        w.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    private func transcribe(_ path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        var args = ["-m", modelPath, "-f", path, "--no-timestamps", "-np"]
        if let language = language { args += ["-l", language] }
        if let prompt = prompt { args += ["--prompt", prompt] }
        process.arguments = args

        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()

        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        return String(data: data, encoding: .utf8)?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
