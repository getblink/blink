import XCTest
@testable import Blink

final class TLDROverlayTextTests: XCTestCase {
    func testDisplayTextNormalizesLineEndingsAndTrimsOuterWhitespace() {
        let raw = "  Headline.\r\n\r\nSupporting detail.  \r\n"

        let parsed = TLDROverlayText(raw)

        XCTAssertEqual(parsed.raw, raw)
        XCTAssertEqual(parsed.displayText, "Headline.\n\nSupporting detail.")
    }

    func testDisplayTextLeavesPlainSummaryAloneExceptOuterWhitespace() {
        XCTAssertEqual(
            TLDROverlayText.displayText(for: "  Nothing new here.  \n"),
            "Nothing new here."
        )
    }

    func testDisplayTextPreservesInteriorParagraphs() {
        let raw = "Headline.\n\nDetail one.\n\nDetail two."

        XCTAssertEqual(
            TLDROverlayText.displayText(for: raw),
            raw
        )
    }
}
