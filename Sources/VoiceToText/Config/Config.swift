import Foundation

enum AnimationStyle: String, Codable, CaseIterable {
    case orb = "orb"
    case waveform = "waveform"
    case glow = "glow"
    case siri = "siri"
    case cursor = "cursor"
    case dot = "dot"
    case pill = "pill"
    case equalizer = "equalizer"

    var description: String {
        switch self {
        case .orb: return "Gradient orb with floating blobs"
        case .waveform: return "Real-time audio waveform bars"
        case .glow: return "Apple Intelligence style border glow"
        case .siri: return "Multi-colored Siri wave lines"
        case .cursor: return "Cursor-following indicator"
        case .dot: return "Cursor becomes a black dot that pulses with voice"
        case .pill: return "Floating capsule showing the last ~1.7s of loudness, scrolling"
        case .equalizer: return "Floating capsule with fixed frequency bands, no scrolling"
        }
    }
}

struct AnimationConfig: Codable {
    var style: AnimationStyle = .dot
    var primaryColor: String = "#007AFF"  // Apple Blue
    var secondaryColor: String = "#5856D6" // Purple accent
    /// Capsule fill for the pill/equalizer styles. Dark values give the
    /// terminal look; the border tint follows primaryColor either way.
    var shellColor: String = "#FFFFFF"
    var opacity: Double = 0.9
    var size: Double = 120  // Base size in points
    var position: Position = .center

    enum Position: String, Codable {
        case center
        case topCenter
        case bottomCenter
        case cursor
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        style = try container.decodeIfPresent(AnimationStyle.self, forKey: .style) ?? .dot
        primaryColor = try container.decodeIfPresent(String.self, forKey: .primaryColor) ?? "#007AFF"
        secondaryColor = try container.decodeIfPresent(String.self, forKey: .secondaryColor) ?? "#5856D6"
        shellColor = try container.decodeIfPresent(String.self, forKey: .shellColor) ?? "#FFFFFF"
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.9
        size = try container.decodeIfPresent(Double.self, forKey: .size) ?? 120
        position = try container.decodeIfPresent(Position.self, forKey: .position) ?? .center
    }
}

/// Which microphone yapless is allowed to open.
///
/// Everything here is explicit: name the devices you want, or the ones you
/// don't. With nothing configured yapless takes the system default, exactly
/// as macOS reports it — no category rules, no guessing on your behalf.
struct AudioConfig: Codable {
    /// A device name/UID substring, or the literal "default" for whatever
    /// macOS currently considers the default input.
    var inputDevice: String? = nil
    /// Ordered allow-list; first entry that is actually present wins. When
    /// non-empty, nothing off the list is ever opened.
    var inputPriority: [String] = []
    /// Name/UID substrings that must never be opened, e.g. ["AirPods"].
    var excludeInputs: [String] = []
    /// Escape hatch, off by default: treat every bluetooth input as excluded
    /// without naming them. Prefer `excludeInputs` — this one acts on devices
    /// you never mentioned.
    var avoidBluetoothInput: Bool = false
    /// Raw-RMS level above which audio counts as voice. An absolute floor is a
    /// claim about one mic at one gain — hence config, not a constant.
    var silenceFloor: Double = 0.01
    /// A recording with less than this many seconds of voice is refused before
    /// transcription. 0 disables the guard.
    ///
    /// Measured over 527 of Aleks's recordings: 0.01/0.4s catches 13 of 30
    /// silence-hallucinations and refuses 1 of 157 genuine dictations. Peak
    /// level cannot do this job — hallucinations reach peak 0.168 while real
    /// speech goes down to 0.039 — but voiced DURATION separates them, because
    /// hallucinations come from brief noise bursts.
    var minVoicedSeconds: Double = 0.4

    static let systemDefaultKeyword = "default"

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputDevice = try container.decodeIfPresent(String.self, forKey: .inputDevice)
        inputPriority = try container.decodeIfPresent([String].self, forKey: .inputPriority) ?? []
        excludeInputs = try container.decodeIfPresent([String].self, forKey: .excludeInputs) ?? []
        avoidBluetoothInput = try container.decodeIfPresent(Bool.self, forKey: .avoidBluetoothInput) ?? false
        silenceFloor = try container.decodeIfPresent(Double.self, forKey: .silenceFloor) ?? 0.01
        minVoicedSeconds = try container.decodeIfPresent(Double.self, forKey: .minVoicedSeconds) ?? 0.4
    }
}

enum TranscriptionBackend: String, Codable {
    case auto       // Auto-detect best available
    case groq       // Groq API (fastest, cloud)
    case deepinfra  // DeepInfra API (whisper-large-v3, OpenAI-compatible, cheapest)
    case fireworks  // Fireworks AI API (whisper-v3, OpenAI-compatible)
    case fal        // fal.ai Wizper (whisper-v3-large, serverless GPU)
    case replicate  // Replicate API (incredibly-fast-whisper, cloud)
    case openai     // OpenAI Whisper API (cloud)
    case local      // Local whisper (openai-whisper, whisper-cpp, whisperkit)
}

struct WhisperConfig: Codable {
    var backend: TranscriptionBackend = .auto
    var model: String = "base"
    var language: String? = nil  // Auto-detect if nil
    var translateToEnglish: Bool = false
    var vadEnabled: Bool = true  // Voice activity detection
    var vadThreshold: Double = 0.6
    var modelPath: String? = nil  // Custom model path, uses default if nil
    /// Words whisper keeps getting wrong — names, jargon, product names.
    /// Sent as the decoder's initial prompt, which biases spelling.
    var vocabulary: [String] = []
    /// Freeform initial prompt, prepended to `vocabulary`.
    var prompt: String? = nil
    var groqApiKey: String? = nil  // Groq API key, or use GROQ_API_KEY env var
    var deepInfraApiKey: String? = nil  // DeepInfra key, or use DEEPINFRA_API_KEY env var
    var fireworksApiKey: String? = nil  // Fireworks key, or use FIREWORKS_API_KEY env var
    var falApiKey: String? = nil  // fal.ai key, or use FAL_KEY env var
    var replicateApiToken: String? = nil  // Replicate token, or use REPLICATE_API_TOKEN env var

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        backend = try container.decodeIfPresent(TranscriptionBackend.self, forKey: .backend) ?? .auto
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? "base"
        language = try container.decodeIfPresent(String.self, forKey: .language)
        translateToEnglish = try container.decodeIfPresent(Bool.self, forKey: .translateToEnglish) ?? false
        vadEnabled = try container.decodeIfPresent(Bool.self, forKey: .vadEnabled) ?? true
        vadThreshold = try container.decodeIfPresent(Double.self, forKey: .vadThreshold) ?? 0.6
        modelPath = try container.decodeIfPresent(String.self, forKey: .modelPath)
        vocabulary = try container.decodeIfPresent([String].self, forKey: .vocabulary) ?? []
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        groqApiKey = try container.decodeIfPresent(String.self, forKey: .groqApiKey)
        deepInfraApiKey = try container.decodeIfPresent(String.self, forKey: .deepInfraApiKey)
        fireworksApiKey = try container.decodeIfPresent(String.self, forKey: .fireworksApiKey)
        falApiKey = try container.decodeIfPresent(String.self, forKey: .falApiKey)
        replicateApiToken = try container.decodeIfPresent(String.self, forKey: .replicateApiToken)
    }
}

struct OutputConfig: Codable {
    var copyToClipboard: Bool = true
    var pasteToActiveApp: Bool = true
    var playCompletionSound: Bool = true

    // One sound per event, each a system sound name (Purr, Tink, Bottle, Pop,
    // Morse, …) or an absolute path to a file. nil/empty silences that one
    // event. Distinct events get distinct sounds or they teach nothing.
    /// Recording has begun — the mic is live.
    var startSound: String? = nil
    /// You stopped talking; transcription is running.
    var processingSound: String? = nil
    /// Text is ready. Gated by playCompletionSound.
    var completionSound: String? = "Tink"
    /// Refused before transcription: not enough voice in the recording.
    var refusedSound: String? = "Funk"
    /// Transcription itself failed — every provider exhausted.
    var errorSound: String? = "Funk"
    var showNotification: Bool = false
    /// Shell command handed the final transcript on stdin. Additive — it runs
    /// alongside clipboard/paste rather than replacing them. nil = off.
    var command: String? = nil
    /// How long to wait for that command before killing it. yapless exits
    /// straight after, so this is the whole budget the sink gets.
    var commandTimeout: Double = 5.0

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        copyToClipboard = try container.decodeIfPresent(Bool.self, forKey: .copyToClipboard) ?? true
        pasteToActiveApp = try container.decodeIfPresent(Bool.self, forKey: .pasteToActiveApp) ?? true
        playCompletionSound = try container.decodeIfPresent(Bool.self, forKey: .playCompletionSound) ?? true
        startSound = try container.decodeIfPresent(String.self, forKey: .startSound)
        processingSound = try container.decodeIfPresent(String.self, forKey: .processingSound)
        completionSound = try container.decodeIfPresent(String.self, forKey: .completionSound) ?? "Tink"
        refusedSound = try container.decodeIfPresent(String.self, forKey: .refusedSound) ?? "Funk"
        errorSound = try container.decodeIfPresent(String.self, forKey: .errorSound) ?? "Funk"
        showNotification = try container.decodeIfPresent(Bool.self, forKey: .showNotification) ?? false
        command = try container.decodeIfPresent(String.self, forKey: .command)
        commandTimeout = try container.decodeIfPresent(Double.self, forKey: .commandTimeout) ?? 5.0
    }
}

struct StorageConfig: Codable {
    var saveHistory: Bool = true  // save recordings and transcriptions to ~/.local/share/yapless/

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        saveHistory = try container.decodeIfPresent(Bool.self, forKey: .saveHistory) ?? true
    }

    static var dataDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".local/share/yapless")
    }

    static var recordingsDirectory: URL {
        dataDirectory.appendingPathComponent("recordings")
    }

    static var transcriptionsDirectory: URL {
        dataDirectory.appendingPathComponent("transcriptions")
    }
}

struct Config: Codable {
    var animation: AnimationConfig = AnimationConfig()
    var whisper: WhisperConfig = WhisperConfig()
    var output: OutputConfig = OutputConfig()
    var storage: StorageConfig = StorageConfig()
    var audio: AudioConfig = AudioConfig()

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        audio = try container.decodeIfPresent(AudioConfig.self, forKey: .audio) ?? AudioConfig()
        animation = try container.decodeIfPresent(AnimationConfig.self, forKey: .animation) ?? AnimationConfig()
        whisper = try container.decodeIfPresent(WhisperConfig.self, forKey: .whisper) ?? WhisperConfig()
        output = try container.decodeIfPresent(OutputConfig.self, forKey: .output) ?? OutputConfig()
        storage = try container.decodeIfPresent(StorageConfig.self, forKey: .storage) ?? StorageConfig()
    }

    static let defaultPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/yapless/config.json").path
    }()

    static func load(from path: String) throws -> Config {
        let url = URL(fileURLWithPath: path)

        // Return default config if file doesn't exist
        guard FileManager.default.fileExists(atPath: path) else {
            return Config()
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(Config.self, from: data)
    }

    func save(to path: String) throws {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()

        // Create directory if needed
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url)
    }

    static var example: Config {
        var config = Config()
        config.animation.style = .orb
        config.animation.primaryColor = "#FF6B6B"
        config.whisper.model = "small"
        config.whisper.language = "en"
        return config
    }
}
