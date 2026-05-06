import Foundation
import XCTest
@testable import TLDR

final class RuntimeConfigStoreTests: XCTestCase {
    func testRuntimeConfigFileDefaultsNewPrivacyFieldsWhenMissing() throws {
        let data = """
        {
          "version": 1,
          "auto_paste": false,
          "model": "gemini-2.0-flash"
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(RuntimeConfigFile.self, from: data)

        XCTAssertEqual(config.version, 1)
        XCTAssertEqual(config.autoPaste, false)
        XCTAssertEqual(config.model, "gemini-2.0-flash")
        XCTAssertEqual(config.allowEventLogging, true)
        XCTAssertEqual(config.allowContentRetention, false)
        XCTAssertEqual(config.soundsEnabled, true)
        XCTAssertNil(config.thinkingLevel)
    }

    func testRuntimeConfigFileDecodesThinkingLevel() throws {
        let data = """
        {
          "version": 1,
          "thinking_level": "high"
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(RuntimeConfigFile.self, from: data)

        XCTAssertEqual(config.thinkingLevel, "high")
    }

    func testRuntimeConfigFileRoundTripsAbsentThinkingLevelAsMissingKey() throws {
        let original = RuntimeConfigFile(
            version: 1,
            autoPaste: true,
            model: "gemini-3-flash-preview",
            allowEventLogging: true,
            allowContentRetention: false,
            soundsEnabled: true,
            thinkingLevel: nil
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuntimeConfigFile.self, from: encoded)
        XCTAssertNil(decoded.thinkingLevel)

        // The encoder should omit the key entirely (not emit `null`) so the
        // on-disk file stays clean for users who never touch the picker.
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertNotNil(object)
        XCTAssertNil(object?["thinking_level"])
        XCTAssertFalse(object?.keys.contains("thinking_level") ?? true)
    }

    func testRuntimeConfigFileRoundTripsThinkingLevel() throws {
        for level in ["low", "medium", "high"] {
            let original = RuntimeConfigFile(
                version: 1,
                autoPaste: true,
                model: "gemini-3-flash-preview",
                allowEventLogging: true,
                allowContentRetention: false,
                soundsEnabled: true,
                thinkingLevel: level
            )

            let encoded = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(RuntimeConfigFile.self, from: encoded)
            XCTAssertEqual(decoded.thinkingLevel, level)
        }
    }
}
