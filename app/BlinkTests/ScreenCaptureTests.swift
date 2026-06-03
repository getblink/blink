import CoreGraphics
import XCTest
@testable import Blink

final class ScreenCaptureTests: XCTestCase {
    func testDisplayFallbackDetectsFullscreenTitlebarStrip() {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 32)

        XCTAssertTrue(ScreenCapture.shouldUseDisplayFallback(windowFrame: frame, scale: 2))
    }

    func testDisplayFallbackAllowsNormalWindows() {
        let frame = CGRect(x: 120, y: 80, width: 900, height: 700)

        XCTAssertFalse(ScreenCapture.shouldUseDisplayFallback(windowFrame: frame, scale: 2))
    }

    func testPreferredCaptureSizePrefersAxWhenAvailable() {
        // The Chrome-on-X bug case: SCK reports a wide-short strip frame
        // while AX reports the actual window dims. Trust AX.
        let sckFrame = CGRect(x: 0, y: 0, width: 1512, height: 157)
        let axRect = CGRect(x: 100, y: 80, width: 1000, height: 700)

        let result = ScreenCapture.preferredCaptureSize(
            windowFrame: sckFrame,
            preferredGlobalRect: axRect
        )

        XCTAssertEqual(result.size, CGSize(width: 1000, height: 700))
        XCTAssertEqual(result.source, .ax)
    }

    func testPreferredCaptureSizeFallsBackToSckWhenAxNil() {
        let sckFrame = CGRect(x: 0, y: 0, width: 900, height: 700)

        let result = ScreenCapture.preferredCaptureSize(
            windowFrame: sckFrame,
            preferredGlobalRect: nil
        )

        XCTAssertEqual(result.size, CGSize(width: 900, height: 700))
        XCTAssertEqual(result.source, .sck)
    }

    func testPreferredCaptureSizeRejectsDegenerateAxRect() {
        // AX occasionally returns near-empty rects (stale window state, etc.).
        // Don't trust them — fall back to SCK's frame.
        let sckFrame = CGRect(x: 0, y: 0, width: 900, height: 700)
        let degenerateAxRect = CGRect(x: 0, y: 0, width: 4, height: 4)

        let result = ScreenCapture.preferredCaptureSize(
            windowFrame: sckFrame,
            preferredGlobalRect: degenerateAxRect
        )

        XCTAssertEqual(result.size, CGSize(width: 900, height: 700))
        XCTAssertEqual(result.source, .sck)
    }

    func testPreferredCaptureSizeAcceptsBoundaryAxRect() {
        // 100×100 is the boundary; the guard should accept (>= 100), not reject.
        let sckFrame = CGRect(x: 0, y: 0, width: 1512, height: 157)
        let axRect = CGRect(x: 0, y: 0, width: 100, height: 100)

        let result = ScreenCapture.preferredCaptureSize(
            windowFrame: sckFrame,
            preferredGlobalRect: axRect
        )

        XCTAssertEqual(result.size, CGSize(width: 100, height: 100))
        XCTAssertEqual(result.source, .ax)
    }

    func testTopmostNonSelfOwnerSkipsBlinkAndPicksNextWindow() {
        // Front-to-back z-order. Blink's own Control window is on top, then
        // a Safari window. We should pick Safari's PID.
        let ownPID: pid_t = 4242
        let windows: [[String: Any]] = [
            blinkWindow(ownerPID: ownPID),
            standardWindow(ownerPID: 9001, width: 1200, height: 800),
        ]

        let pid = ScreenCapture.topmostNonSelfOwnerPID(in: windows, excluding: ownPID)

        XCTAssertEqual(pid, 9001)
    }

    func testTopmostNonSelfOwnerRespectsFrontToBackOrderWhenBlinkIsNotFirst() {
        // Defensive: if some other Blink-owned window (e.g. menubar item)
        // sits behind a real target, we still want the topmost non-Blink
        // standard-layer window — not the first occurrence of a different PID.
        let ownPID: pid_t = 4242
        let windows: [[String: Any]] = [
            standardWindow(ownerPID: 9001, width: 1200, height: 800),
            blinkWindow(ownerPID: ownPID),
            standardWindow(ownerPID: 7777, width: 800, height: 600),
        ]

        let pid = ScreenCapture.topmostNonSelfOwnerPID(in: windows, excluding: ownPID)

        XCTAssertEqual(pid, 9001)
    }

    func testTopmostNonSelfOwnerSkipsNonStandardLayerWindows() {
        // Status-bar / menu overlays live above layer 0 and should never be
        // chosen as the capture target.
        let ownPID: pid_t = 4242
        let windows: [[String: Any]] = [
            standardWindow(ownerPID: 7777, width: 200, height: 24, layer: 25),
            standardWindow(ownerPID: 8888, width: 900, height: 700),
        ]

        let pid = ScreenCapture.topmostNonSelfOwnerPID(in: windows, excluding: ownPID)

        XCTAssertEqual(pid, 8888)
    }

    func testTopmostNonSelfOwnerSkipsTinyWindows() {
        // Tooltips and accessory popovers are tiny. Don't lock onto them.
        let ownPID: pid_t = 4242
        let windows: [[String: Any]] = [
            standardWindow(ownerPID: 5555, width: 40, height: 20),
            standardWindow(ownerPID: 6666, width: 1000, height: 700),
        ]

        let pid = ScreenCapture.topmostNonSelfOwnerPID(in: windows, excluding: ownPID)

        XCTAssertEqual(pid, 6666)
    }

    func testTopmostNonSelfOwnerReturnsNilWhenOnlySelfPresent() {
        let ownPID: pid_t = 4242
        let windows: [[String: Any]] = [blinkWindow(ownerPID: ownPID)]

        XCTAssertNil(ScreenCapture.topmostNonSelfOwnerPID(in: windows, excluding: ownPID))
    }

    func testFrontmostCapturableWindowRectSkipsBlinkAndReturnsNextBounds() {
        // The instant capture acknowledgment anchors to this rect. It must skip
        // Blink's own window and return the *exact* bounds of the next standard
        // window (non-zero origin included), since the lens is laid over it.
        let ownPID: pid_t = 4242
        let windows: [[String: Any]] = [
            blinkWindow(ownerPID: ownPID),
            windowWithBounds(ownerPID: 9001, x: 120, y: 80, width: 1200, height: 800),
        ]

        let rect = ScreenCapture.frontmostCapturableWindowRect(in: windows, excluding: ownPID)

        XCTAssertEqual(rect, CGRect(x: 120, y: 80, width: 1200, height: 800))
    }

    func testFrontmostCapturableWindowRectSkipsNonStandardLayerAndTinyWindows() {
        // Same filters as topmostNonSelfOwnerPID: above-layer-0 overlays and
        // sub-80pt accessory windows are never the capture target.
        let ownPID: pid_t = 4242
        let windows: [[String: Any]] = [
            standardWindow(ownerPID: 7777, width: 200, height: 24, layer: 25),
            standardWindow(ownerPID: 5555, width: 40, height: 20),
            windowWithBounds(ownerPID: 8888, x: 0, y: 0, width: 900, height: 700),
        ]

        let rect = ScreenCapture.frontmostCapturableWindowRect(in: windows, excluding: ownPID)

        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 900, height: 700))
    }

    func testFrontmostCapturableWindowRectReturnsNilWhenOnlySelfPresent() {
        let ownPID: pid_t = 4242
        let windows: [[String: Any]] = [blinkWindow(ownerPID: ownPID)]

        XCTAssertNil(ScreenCapture.frontmostCapturableWindowRect(in: windows, excluding: ownPID))
    }

    private func windowWithBounds(
        ownerPID: pid_t,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        layer: Int = 0
    ) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: ownerPID,
            kCGWindowLayer as String: layer,
            kCGWindowBounds as String: [
                "X": Double(x),
                "Y": Double(y),
                "Width": Double(width),
                "Height": Double(height),
            ] as [String: Any],
        ]
    }

    private func blinkWindow(ownerPID: pid_t) -> [String: Any] {
        standardWindow(ownerPID: ownerPID, width: 520, height: 220)
    }

    private func standardWindow(
        ownerPID: pid_t,
        width: CGFloat,
        height: CGFloat,
        layer: Int = 0
    ) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: ownerPID,
            kCGWindowLayer as String: layer,
            kCGWindowBounds as String: [
                "X": 0.0,
                "Y": 0.0,
                "Width": Double(width),
                "Height": Double(height),
            ] as [String: Any],
        ]
    }

    func testBestDisplayIndexPicksContainingDisplay() {
        // Two displays side by side. A rect whose center sits on the
        // right-hand display should pick that display, even though both
        // intersect the rect.
        let left = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let right = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let rect = CGRect(x: 1800, y: 200, width: 800, height: 600)

        let idx = ScreenCapture.bestDisplayIndex(for: rect, displayFrames: [left, right])

        XCTAssertEqual(idx, 1)
    }

    func testBestDisplayIndexFallsBackToLargestIntersection() {
        // Rect center off all displays (degenerate AX coords). Should pick
        // the display with the largest intersection rather than nil so the
        // fullscreen path still degrades to a sensible default.
        let left = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let right = CGRect(x: 2000, y: 0, width: 1000, height: 800)
        let orphan = CGRect(x: -500, y: -500, width: 100, height: 100)

        let idx = ScreenCapture.bestDisplayIndex(for: orphan, displayFrames: [left, right])

        // Neither contains the center, neither intersects — should still
        // return a non-nil index (the first display, by tie-break).
        XCTAssertEqual(idx, 0)
    }

    func testBestDisplayIndexReturnsNilForEmptyList() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)

        XCTAssertNil(ScreenCapture.bestDisplayIndex(for: rect, displayFrames: []))
    }

    func testBestDisplayIndexPrefersCenterOverArea() {
        // The rect overlaps display A more in area, but its center sits on
        // display B. Center-containment must win — that's what makes the
        // fullscreen path land on the right Space's display.
        let displayA = CGRect(x: 0, y: 0, width: 2000, height: 1000)
        let displayB = CGRect(x: 2000, y: 0, width: 500, height: 1000)
        // Wide rect spanning both displays, center at x=2050 (on B).
        let rect = CGRect(x: 1055, y: 400, width: 1990, height: 200)

        XCTAssertTrue(displayB.contains(CGPoint(x: rect.midX, y: rect.midY)))
        let areaOnA = displayA.intersection(rect).width * displayA.intersection(rect).height
        let areaOnB = displayB.intersection(rect).width * displayB.intersection(rect).height
        XCTAssertGreaterThan(areaOnA, areaOnB)

        let idx = ScreenCapture.bestDisplayIndex(for: rect, displayFrames: [displayA, displayB])

        XCTAssertEqual(idx, 1, "center-containment must outrank intersection area")
    }

    func testPreferredCaptureSizeReportsAxSourceEvenWhenDimsMatchSck() {
        // When AX and SCK happen to agree, the source tag must still report
        // .ax so log audits can confirm the AX path fired.
        let frame = CGRect(x: 0, y: 0, width: 900, height: 700)

        let result = ScreenCapture.preferredCaptureSize(
            windowFrame: frame,
            preferredGlobalRect: frame
        )

        XCTAssertEqual(result.size, CGSize(width: 900, height: 700))
        XCTAssertEqual(result.source, .ax)
    }
}
