import XCTest
@testable import VoiceToText

final class VoiceToTextTests: XCTestCase {
    func testConfigDefaultValues() throws {
        let config = Config()

        XCTAssertEqual(config.animation.style, .orb)
        XCTAssertEqual(config.animation.primaryColor, "#007AFF")
        XCTAssertEqual(config.whisper.model, "base")
        XCTAssertTrue(config.output.copyToClipboard)
        XCTAssertTrue(config.output.pasteToActiveApp)
    }

    func testConfigEncoding() throws {
        let config = Config()
        let encoder = JSONEncoder()
        let data = try encoder.encode(config)

        XCTAssertNotNil(data)
        XCTAssertGreaterThan(data.count, 0)
    }

    func testConfigDecoding() throws {
        let json = """
        {
            "animation": {
                "style": "waveform",
                "primaryColor": "#FF0000"
            },
            "whisper": {
                "model": "small"
            }
        }
        """

        let decoder = JSONDecoder()
        let config = try decoder.decode(Config.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(config.animation.style, .waveform)
        XCTAssertEqual(config.animation.primaryColor, "#FF0000")
        XCTAssertEqual(config.whisper.model, "small")
    }

    func testAnimationStyles() throws {
        XCTAssertEqual(AnimationStyle.allCases.count, 4)
        XCTAssertEqual(AnimationStyle.orb.rawValue, "orb")
        XCTAssertEqual(AnimationStyle.waveform.rawValue, "waveform")
        XCTAssertEqual(AnimationStyle.glow.rawValue, "glow")
        XCTAssertEqual(AnimationStyle.cursor.rawValue, "cursor")
    }
}
