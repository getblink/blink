import XCTest
@testable import Blink

final class TLDROverlayTextTests: XCTestCase {
    func testDisplayTextNormalizesLineEndingsAndTrimsOuterWhitespace() {
        let raw = "  Headline.\r\n\r\nSupporting detail.  \r\n"

        let parsed = TLDROverlayText(raw)

        XCTAssertEqual(parsed.raw, raw)
        XCTAssertEqual(parsed.displayText, "Headline.\n\nSupporting detail.")
        // Two paragraphs show in full — no collapse affordance.
        XCTAssertEqual(parsed.collapsedText, "Headline.\n\nSupporting detail.")
        XCTAssertFalse(parsed.isCollapsedAtParagraphBreak)
    }

    func testTwoParagraphSummaryShowsInFull() {
        let parsed = TLDROverlayText("Headline.\n\nSupporting detail.")

        XCTAssertEqual(parsed.collapsedDisplayText, parsed.displayText)
        XCTAssertFalse(parsed.isCollapsedAtParagraphBreak)
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

    func testCollapsedDisplayTextStopsAtSecondParagraphBreakAndShowsAffordance() {
        let parsed = TLDROverlayText("Headline.\n\nDetail one.\n\nDetail two.")

        XCTAssertEqual(parsed.collapsedText, "Headline.\n\nDetail one.")
        XCTAssertEqual(parsed.collapsedDisplayText, "Headline.\n\nDetail one.\n\nShow more")
        XCTAssertTrue(parsed.isCollapsedAtParagraphBreak)
    }

    func testFourParagraphSummaryStillCollapsesToFirstTwo() {
        let parsed = TLDROverlayText("A.\n\nB.\n\nC.\n\nD.")

        XCTAssertEqual(parsed.collapsedText, "A.\n\nB.")
        XCTAssertEqual(parsed.collapsedDisplayText, "A.\n\nB.\n\nShow more")
        XCTAssertTrue(parsed.isCollapsedAtParagraphBreak)
    }

    func testSingleParagraphSummaryDoesNotShowAffordance() {
        let parsed = TLDROverlayText("One paragraph that wraps but has no blank-line break.")

        XCTAssertEqual(parsed.collapsedDisplayText, parsed.displayText)
        XCTAssertFalse(parsed.isCollapsedAtParagraphBreak)
    }

    func testWhitespaceOnlyParagraphBreakDoesNotCollapseEmptyRemainder() {
        let parsed = TLDROverlayText("Headline.\n \n   ")

        XCTAssertEqual(parsed.collapsedDisplayText, "Headline.")
        XCTAssertFalse(parsed.isCollapsedAtParagraphBreak)
    }
}
