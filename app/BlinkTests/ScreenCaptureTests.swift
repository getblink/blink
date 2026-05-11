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
