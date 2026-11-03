import Speech
import AVFoundation

@main struct SA {
    static func main() async throws {
        let args = CommandLine.arguments
        let url = URL(fileURLWithPath: args[1])
        let locale = Locale(identifier: args.count > 2 ? args[2] : "en_US")
        let dictation = ProcessInfo.processInfo.environment["SA_DICTATION"] == "1"
        let module: any SpeechModule
        let results: AsyncThrowingStream<String, Error>
        if dictation {
            let t = DictationTranscriber(locale: locale, preset: .longDictation)
            module = t
            results = AsyncThrowingStream { c in Task { do { for try await r in t.results where r.isFinal { c.yield(String(r.text.characters)) }; c.finish() } catch { c.finish(throwing: error) } } }
        } else {
            let t = SpeechTranscriber(locale: locale, preset: .transcription)
            module = t
            results = AsyncThrowingStream { c in Task { do { for try await r in t.results where r.isFinal { c.yield(String(r.text.characters)) }; c.finish() } catch { c.finish(throwing: error) } } }
        }
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            FileHandle.standardError.write("installing assets…\n".data(using: .utf8)!)
            try await req.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        if let words = ProcessInfo.processInfo.environment["SA_CONTEXT"] {
            let ctx = AnalysisContext()
            ctx.contextualStrings[.general] = words.components(separatedBy: ",")
            try await analyzer.setContext(ctx)
        }
        let file = try AVAudioFile(forReading: url)
        let collect = Task { var out = ""; for try await s in results { out += s }; return out }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        print(try await collect.value)
    }
}
