import CoreGraphics
import XCTest
@testable import TLDR

final class ScreenCaptureTests: XCTestCase {
    func testDisplayFallbackDetectsFullscreenTitlebarStrip() {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 32)

        XCTAssertTrue(ScreenCapture.shouldUseDisplayFallback(windowFrame: frame, scale: 2))
    }

    func testDisplayFallbackAllowsNormalWindows() {
        let frame = CGRect(x: 120, y: 80, width: 900, height: 700)

        XCTAssertFalse(ScreenCapture.shouldUseDisplayFallback(windowFrame: frame, scale: 2))
    }
}
