import XCTest
@testable import Blink

/// Coverage for `WindowAXTreeCapture.collapseTandemRuns`, the duplication folder
/// that runs before the budget windower. Cases mirror the shapes seen in real
/// Chromium captures: a tab strip emitted several times, the whole browser frame
/// mounted under two parents at different depths, and nested repeats.
final class WindowAXTreeCollapseTests: XCTestCase {
    func testLeavesNonDuplicatedTreeUnchanged() {
        let lines = [
            "window \"A\"",
            "  group \"B\"",
            "    text \"x\"",
        ]
        let result = WindowAXTreeCapture.collapseTandemRuns(lines, anchorIndex: 2)
        XCTAssertEqual(result.lines, lines)
        XCTAssertEqual(result.anchorIndex, 2)
    }

    func testReturnsUnchangedForEmptyOrSingleLine() {
        XCTAssertEqual(WindowAXTreeCapture.collapseTandemRuns([]).lines, [])
        XCTAssertEqual(WindowAXTreeCapture.collapseTandemRuns(["only"]).lines, ["only"])
    }

    func testCollapsesAdjacentIdenticalSiblingsWithInlineMarker() {
        var lines = ["window \"A\""]
        lines.append(contentsOf: Array(repeating: "  tab \"T\"", count: 4))

        let result = WindowAXTreeCapture.collapseTandemRuns(lines)

        XCTAssertEqual(result.lines.count, 2)
        XCTAssertEqual(result.lines[0], "window \"A\"")
        XCTAssertTrue(result.lines[1].hasPrefix("  tab \"T\""))
        XCTAssertTrue(result.lines[1].hasSuffix("[×4]"))
    }

    func testCollapsesRepeatedMultiLineBlock() {
        let block = ["  bar \"1\"", "  bar \"2\"", "  bar \"3\""]
        let lines = ["root"] + block + block

        let result = WindowAXTreeCapture.collapseTandemRuns(lines)

        // root + one copy of the 3-line block + one marker line.
        XCTAssertEqual(result.lines.count, 5)
        XCTAssertEqual(Array(result.lines[1...3]), block)
        XCTAssertTrue(result.lines[4].contains("3-line block"))
        XCTAssertTrue(result.lines[4].contains("×2"))
    }

    func testMatchesAcrossDifferentParentDepths() {
        // Same two-button block once under a deep "area" (indent 2) and again as a
        // direct child of "win" (indent 1) — the browser-frame-under-two-parents
        // shape. Indent-normalized equality must fold them.
        let lines = [
            "win",
            "  area",
            "    btn \"a\"",
            "    btn \"b\"",
            "  btn \"a\"",
            "  btn \"b\"",
        ]

        let result = WindowAXTreeCapture.collapseTandemRuns(lines)

        XCTAssertEqual(result.lines.count, 5)
        XCTAssertEqual(result.lines[0], "win")
        XCTAssertEqual(result.lines[1], "  area")
        // The kept copy is the first (deeper) one; the shallow duplicate is gone.
        XCTAssertEqual(result.lines[2], "    btn \"a\"")
        XCTAssertEqual(result.lines[3], "    btn \"b\"")
        XCTAssertTrue(result.lines[4].contains("2-line block"))
        XCTAssertFalse(result.lines.contains("  btn \"a\""))
    }

    func testFoldsNestedRepeats() {
        // A 4-line block (a header + three identical tabs) repeated twice. The
        // outer ×2 and the inner tab ×3 must both fold in one pass.
        let block = [
            "  bar \"x\"",
            "    tab \"1\"",
            "    tab \"1\"",
            "    tab \"1\"",
        ]
        let lines = ["win"] + block + block

        let result = WindowAXTreeCapture.collapseTandemRuns(lines)

        let joined = result.lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("[×3]"), "inner tabs should fold: \(joined)")
        XCTAssertTrue(joined.contains("4-line block"), "outer block should fold: \(joined)")
        // win, bar x, one tab + [×3], one outer marker.
        XCTAssertEqual(result.lines.count, 4)
    }

    func testRemapsAnchorOutOfDroppedCopy() {
        // Block [a"1", a"2"] repeated twice; anchor points at the a"1" inside the
        // dropped second copy. It must remap onto the surviving first copy.
        let lines = [
            "root",
            "  a \"1\"",
            "  a \"2\"",
            "  a \"1\"",
            "  a \"2\"",
        ]

        let result = WindowAXTreeCapture.collapseTandemRuns(lines, anchorIndex: 3)

        XCTAssertEqual(result.lines.count, 4) // root, a1, a2, marker
        XCTAssertNotNil(result.anchorIndex)
        XCTAssertEqual(result.anchorIndex, 1)
        XCTAssertEqual(result.lines[result.anchorIndex!], "  a \"1\"")
    }

    func testKeepsBarePairBelowGainThreshold() {
        // A single duplicated line nets one line, which the marker would cost
        // back, so the default minGain leaves it intact rather than churn.
        let lines = ["root", "  x \"1\"", "  x \"1\""]
        let result = WindowAXTreeCapture.collapseTandemRuns(lines)
        XCTAssertEqual(result.lines, lines)
    }

    // MARK: - isSeparatorOnly (value trimming)

    func testSeparatorOnlyMatchesPunctuationGlyphs() {
        for sep in ["·", "•", "|", "-", "(", ")", "··", "—"] {
            XCTAssertTrue(WindowAXTreeCapture.isSeparatorOnly(sep), "expected separator: \(sep)")
        }
        // Whitespace around a lone glyph still counts.
        XCTAssertTrue(WindowAXTreeCapture.isSeparatorOnly(" · "))
    }

    func testSeparatorOnlyKeepsRealText() {
        for text in ["ok", "12", "-4", "+367", "Hi", "a", "Reply", ".regular"] {
            XCTAssertFalse(WindowAXTreeCapture.isSeparatorOnly(text), "should keep: \(text)")
        }
        XCTAssertFalse(WindowAXTreeCapture.isSeparatorOnly(""))
    }
}
