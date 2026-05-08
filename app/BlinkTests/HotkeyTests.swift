import Carbon.HIToolbox
import CoreGraphics
import Foundation
import XCTest
@testable import Blink

final class HotkeyTests: XCTestCase {
    func testDefaultIsControlOptionSpace() {
        XCTAssertEqual(Hotkey.default.keyCode, CGKeyCode(kVK_Space))
        XCTAssertEqual(Hotkey.default.flags, [.maskControl, .maskAlternate])
    }

    func testParsesCanonicalForm() {
        let hotkey = Hotkey.parse("ctrl+opt+space")
        XCTAssertEqual(hotkey, Hotkey.default)
    }

    func testParsesAliasesAndCase() {
        XCTAssertEqual(Hotkey.parse("Control+Option+Space"), Hotkey.default)
        XCTAssertEqual(Hotkey.parse("control alt space"), Hotkey.default)
        XCTAssertEqual(Hotkey.parse("⌃⌥space"), Hotkey.default)
    }

    func testParsesCommandShiftLetter() {
        let hotkey = Hotkey.parse("cmd+shift+t")
        XCTAssertEqual(hotkey?.keyCode, CGKeyCode(kVK_ANSI_T))
        XCTAssertEqual(hotkey?.flags, [.maskCommand, .maskShift])
    }

    func testParsesSpecialKeys() {
        XCTAssertEqual(Hotkey.parse("cmd+shift+space")?.keyCode, CGKeyCode(kVK_Space))
        XCTAssertEqual(Hotkey.parse("ctrl+0")?.keyCode, CGKeyCode(kVK_ANSI_0))
    }

    func testRejectsBareKey() {
        XCTAssertNil(Hotkey.parse("f"))
    }

    func testRejectsUnknownKey() {
        XCTAssertNil(Hotkey.parse("ctrl+nope"))
    }

    func testRejectsTwoNonModifiers() {
        XCTAssertNil(Hotkey.parse("ctrl+f+g"))
    }

    func testRejectsEmpty() {
        XCTAssertNil(Hotkey.parse(""))
        XCTAssertNil(Hotkey.parse("   "))
    }

    func testLoadFallsBackWhenSettingsMissing() {
        XCTAssertEqual(Hotkey.loadFromSettings(at: nil), .default)
    }

    func testLoadReadsHotkeyField() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blink-hotkey-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        try Data(#"{"hotkey":"cmd+shift+t"}"#.utf8).write(to: url)

        let hotkey = Hotkey.loadFromSettings(at: url)
        XCTAssertEqual(hotkey.keyCode, CGKeyCode(kVK_ANSI_T))
        XCTAssertEqual(hotkey.flags, [.maskCommand, .maskShift])
    }

    func testLoadFallsBackOnInvalidHotkeyString() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blink-hotkey-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        try Data(#"{"hotkey":"bogus"}"#.utf8).write(to: url)

        XCTAssertEqual(Hotkey.loadFromSettings(at: url), .default)
    }

    func testDisplayString() {
        XCTAssertEqual(Hotkey.default.displayString, "⌃⌥Space")
        XCTAssertEqual(
            Hotkey(keyCode: CGKeyCode(kVK_ANSI_T), flags: [.maskCommand, .maskShift]).displayString,
            "⇧⌘T"
        )
    }
}
