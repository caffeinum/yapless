import Foundation

enum AnimationStyle: String, Codable, CaseIterable {
    case orb = "orb"
    case waveform = "waveform"
    case glow = "glow"
    case siri = "siri"
    case cursor = "cursor"

    var description: String {
        switch self {
        case .orb: return "Gradient orb with floating blobs"
        case .waveform: return "Real-time audio waveform bars"
        case .glow: return "Apple Intelligence style border glow"
        case .siri: return "Multi-colored Siri wave lines"
        case .cursor: return "Cursor-following indicator"
        }
    }
}

struct AnimationConfig: Codable {
    var style: AnimationStyle = .glow
    var primaryColor: String = "#007AFF"  // Apple Blue
    var secondaryColor: String = "#5856D6" // Purple accent
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
        style = try container.decodeIfPresent(AnimationStyle.self, forKey: .style) ?? .glow
        primaryColor = try container.decodeIfPresent(String.self, forKey: .primaryColor) ?? "#007AFF"
        secondaryColor = try container.decodeIfPresent(String.self, forKey: .secondaryColor) ?? "#5856D6"
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.9
        size = try container.decodeIfPresent(Double.self, forKey: .size) ?? 120
        position = try container.decodeIfPresent(Position.self, forKey: .position) ?? .center
    }
}

enum TranscriptionBackend: String, Codable {
    case auto       // Auto-detect best available
    case groq       // Groq API (fastest, cloud)
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
    var groqApiKey: String? = nil  // Groq API key, or use GROQ_API_KEY env var

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
        groqApiKey = try container.decodeIfPresent(String.self, forKey: .groqApiKey)
    }
}

struct OutputConfig: Codable {
    var copyToClipboard: Bool = true
    var pasteToActiveApp: Bool = true
    var playCompletionSound: Bool = true
    var showNotification: Bool = false

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        copyToClipboard = try container.decodeIfPresent(Bool.self, forKey: .copyToClipboard) ?? true
        pasteToActiveApp = try container.decodeIfPresent(Bool.self, forKey: .pasteToActiveApp) ?? true
        playCompletionSound = try container.decodeIfPresent(Bool.self, forKey: .playCompletionSound) ?? true
        showNotification = try container.decodeIfPresent(Bool.self, forKey: .showNotification) ?? false
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

    static var draftsDirectory: URL {
        dataDirectory.appendingPathComponent("drafts")
    }
}

struct Config: Codable {
    var animation: AnimationConfig = AnimationConfig()
    var whisper: WhisperConfig = WhisperConfig()
    var output: OutputConfig = OutputConfig()
    var storage: StorageConfig = StorageConfig()

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
