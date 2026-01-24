import Foundation

enum AnimationStyle: String, Codable, CaseIterable {
    case orb = "orb"
    case waveform = "waveform"
    case glow = "glow"
    case cursor = "cursor"

    var description: String {
        switch self {
        case .orb: return "Simple breathing orb"
        case .waveform: return "Real-time audio waveform"
        case .glow: return "Screen edge glow effect"
        case .cursor: return "Cursor-following indicator"
        }
    }
}

struct AnimationConfig: Codable {
    var style: AnimationStyle = .orb
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
}

struct WhisperConfig: Codable {
    var model: String = "base"
    var language: String? = nil  // Auto-detect if nil
    var translateToEnglish: Bool = false
    var vadEnabled: Bool = true  // Voice activity detection
    var vadThreshold: Double = 0.6
    var modelPath: String? = nil  // Custom model path, uses default if nil
}

struct OutputConfig: Codable {
    var copyToClipboard: Bool = true
    var pasteToActiveApp: Bool = true
    var playCompletionSound: Bool = true
    var showNotification: Bool = false
}

struct Config: Codable {
    var animation: AnimationConfig = AnimationConfig()
    var whisper: WhisperConfig = WhisperConfig()
    var output: OutputConfig = OutputConfig()

    static let defaultPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/voice-to-text/config.json").path
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
