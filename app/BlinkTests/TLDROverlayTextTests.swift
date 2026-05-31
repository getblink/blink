import XCTest
@testable import Blink

final class TLDROverlayTextTests: XCTestCase {
    func testDisplayTextRemovesSeparatorAndKeepsExpandedDetail() {
        let raw = "Headline stands alone.\n\n---\n\nSupporting detail.\n\nNext beat."

        let parsed = TLDROverlayText(raw)

        XCTAssertEqual(parsed.collapsed, "Headline stands alone.")
        XCTAssertEqual(parsed.expanded, "Supporting detail.\n\nNext beat.")
        XCTAssertEqual(parsed.displayText, "Headline stands alone.\n\nSupporting detail.\n\nNext beat.")
    }

    func testDisplayTextAcceptsWhitespaceAndCRLFSeparators() {
        let raw = "Headline.\r\n\r\n  ---  \r\n\r\nDetail."

        XCTAssertEqual(TLDROverlayText.displayText(for: raw), "Headline.\n\nDetail.")
    }

    func testDisplayTextLeavesPlainSummaryAlone() {
        XCTAssertEqual(
            TLDROverlayText.displayText(for: "  Nothing new here.  \n"),
            "Nothing new here."
        )
    }

    func testDisplayTextRemovesMultipleStandaloneSeparators() {
        let raw = "Headline.\n\n---\n\nDetail one.\n\n---\n\nDetail two."

        XCTAssertEqual(
            TLDROverlayText.displayText(for: raw),
            "Headline.\n\nDetail one.\n\nDetail two."
        )
    }
}
