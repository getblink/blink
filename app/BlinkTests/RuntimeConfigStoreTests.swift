import Foundation
import XCTest
@testable import Blink

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
        XCTAssertEqual(config.lensAnimationSpeed, RuntimeConfigFile.defaultLensAnimationSpeed)
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
            thinkingLevel: nil,
            nudgesEnabled: true,
            lastNudgeAt: nil,
            recentNudgeDismissals: [],
            nudgeCooldownMinutes: 30
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
                thinkingLevel: level,
                nudgesEnabled: true,
                lastNudgeAt: nil,
                recentNudgeDismissals: [],
                nudgeCooldownMinutes: 30
            )

            let encoded = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(RuntimeConfigFile.self, from: encoded)
            XCTAssertEqual(decoded.thinkingLevel, level)
        }
    }

    func testRuntimeConfigFileDefaultsAppThinkingLevelsWhenMissing() throws {
        let data = """
        { "version": 1 }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(RuntimeConfigFile.self, from: data)
        XCTAssertEqual(config.appThinkingLevels, [:])
    }

    func testRuntimeConfigFileDecodesAndRoundTripsAppThinkingLevels() throws {
        let data = """
        {
          "version": 1,
          "app_thinking_levels": { "com.google.Chrome": "high", "com.tinyspeck.slackmacgap": "off" }
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(RuntimeConfigFile.self, from: data)
        XCTAssertEqual(config.appThinkingLevels["com.google.Chrome"], "high")
        XCTAssertEqual(config.appThinkingLevels["com.tinyspeck.slackmacgap"], "off")

        let reEncoded = try JSONEncoder().encode(config)
        let reDecoded = try JSONDecoder().decode(RuntimeConfigFile.self, from: reEncoded)
        XCTAssertEqual(reDecoded.appThinkingLevels, config.appThinkingLevels)

        // Snake_case on disk so the Python side can read it.
        let object = try JSONSerialization.jsonObject(with: reEncoded) as? [String: Any]
        XCTAssertNotNil(object?["app_thinking_levels"])
    }

    func testRuntimeConfigFileDefaultsStyleWhenMissing() throws {
        let data = """
        {
          "version": 1,
          "auto_paste": true,
          "model": "gemini-3-flash-preview"
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(RuntimeConfigFile.self, from: data)

        XCTAssertEqual(config.style, .default)
        XCTAssertEqual(config.style.initiative, "balanced")
        XCTAssertEqual(config.style.aboutMe, "")
    }

    func testRuntimeConfigFileDecodesAndRoundTripsStyle() throws {
        let data = """
        {
          "version": 1,
          "style": {
            "initiative": "agentic",
            "tone": "casual",
            "length": "terse",
            "directness": "direct",
            "voice_mirror": "mirror",
            "about_me": "I'm a backend engineer."
          }
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(RuntimeConfigFile.self, from: data)
        XCTAssertEqual(config.style.initiative, "agentic")
        XCTAssertEqual(config.style.tone, "casual")
        XCTAssertEqual(config.style.length, "terse")
        XCTAssertEqual(config.style.directness, "direct")
        XCTAssertEqual(config.style.voiceMirror, "mirror")
        XCTAssertEqual(config.style.aboutMe, "I'm a backend engineer.")

        let reEncoded = try JSONEncoder().encode(config)
        let reDecoded = try JSONDecoder().decode(RuntimeConfigFile.self, from: reEncoded)
        XCTAssertEqual(reDecoded.style, config.style)

        // The on-disk key is snake_case to stay readable from Python.
        let object = try JSONSerialization.jsonObject(with: reEncoded) as? [String: Any]
        let styleDict = object?["style"] as? [String: Any]
        XCTAssertEqual(styleDict?["voice_mirror"] as? String, "mirror")
        XCTAssertEqual(styleDict?["about_me"] as? String, "I'm a backend engineer.")
    }

    func testStylePrefsDefaultsIndividualFieldsWhenMissing() throws {
        let data = """
        { "initiative": "agentic" }
        """.data(using: .utf8)!

        let style = try JSONDecoder().decode(StylePrefs.self, from: data)
        XCTAssertEqual(style.initiative, "agentic")
        XCTAssertEqual(style.tone, "balanced")
        XCTAssertEqual(style.aboutMe, "")
    }
}
