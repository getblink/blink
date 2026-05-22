import XCTest
@testable import Blink

final class ReasoningLevelsTests: XCTestCase {
    func testTitlesIncludeOff() {
        XCTAssertEqual(ReasoningLevels.titles, ["Default", "Off", "Low", "Medium", "High"])
    }

    func testTitleForOffValue() {
        XCTAssertEqual(ReasoningLevels.title(for: "off"), "Off")
        XCTAssertEqual(ReasoningLevels.title(for: "OFF"), "Off")
    }

    func testValueForOffTitle() {
        XCTAssertEqual(ReasoningLevels.value(for: "Off"), "off")
    }

    func testTitleForNilIsDefault() {
        XCTAssertEqual(ReasoningLevels.title(for: nil), "Default")
    }

    func testValueForDefaultIsNil() {
        XCTAssertNil(ReasoningLevels.value(for: "Default"))
    }

    func testOffRoundTrips() {
        let title = ReasoningLevels.title(for: "off")
        XCTAssertEqual(ReasoningLevels.value(for: title), "off")
    }

    func testKnownLevelsRoundTrip() {
        for level in ["low", "medium", "high", "off"] {
            let title = ReasoningLevels.title(for: level)
            XCTAssertEqual(ReasoningLevels.value(for: title), level, "round-trip failed for \(level)")
        }
    }
}
