import AppKit
import CoreGraphics
import XCTest
@testable import Blink

final class ScreenAnnotatorTests: XCTestCase {
    /// 200×120 px solid-grey PNG covering a 400×240 AppKit-screen rect
    /// at origin (100, 50). That's a 2× backing scale (mimics a captured
    /// Retina window). All marker math derives `sx` from the image's
    /// pixel size divided by the capture rect's point size.
    private let captureRect = CGRect(x: 100, y: 50, width: 400, height: 240)
    private let imageSizePixels = CGSize(width: 200, height: 120)

    private func makeBlankPNG() -> Data {
        let width = Int(imageSizePixels.width)
        let height = Int(imageSizePixels.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = context.makeImage()!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(
            data,
            "public.png" as CFString,
            1,
            nil
        )!
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    private func pixelsDiffer(_ a: Data, _ b: Data) -> Bool {
        // Two PNGs differing by any number of pixels will differ in raw
        // bytes too — PNG is deterministic for our drawing pipeline.
        // Tighter than rasterising and comparing pixels for our purposes.
        a != b
    }

    func testAnnotateProducesDecodablePNGWhenAllMarkersAreNil() {
        // Even with every marker nil the annotate pass still re-encodes
        // through CGContext, so we can't byte-equality-check vs the
        // input. Assert the output is valid PNG bytes — drawing nothing
        // must not produce a corrupted or zero-byte image.
        let png = makeBlankPNG()
        let result = ScreenAnnotator.annotate(
            pngData: png,
            captureRect: captureRect,
            markers: ScreenAnnotator.Markers(
                focusedBounds: nil,
                caretPoint: nil,
                mousePoint: nil,
                sourceConfidence: "native_ax"
            )
        )
        XCTAssertNotNil(result)
        XCTAssertNotNil(NSImage(data: result!))
    }

    func testCaretMarkerDrawsForNativeAX() {
        let png = makeBlankPNG()
        let baseline = ScreenAnnotator.annotate(
            pngData: png,
            captureRect: captureRect,
            markers: ScreenAnnotator.Markers(
                focusedBounds: nil,
                caretPoint: nil,
                mousePoint: nil,
                sourceConfidence: "native_ax"
            )
        )!
        let withCaret = ScreenAnnotator.annotate(
            pngData: png,
            captureRect: captureRect,
            markers: ScreenAnnotator.Markers(
                focusedBounds: nil,
                caretPoint: CGPoint(x: 300, y: 170),
                mousePoint: nil,
                sourceConfidence: "native_ax"
            )
        )!
        XCTAssertTrue(pixelsDiffer(baseline, withCaret))
    }

    func testCaretMarkerSkippedForLowConfidenceSurfaces() {
        let png = makeBlankPNG()
        let baseline = ScreenAnnotator.annotate(
            pngData: png,
            captureRect: captureRect,
            markers: ScreenAnnotator.Markers(
                focusedBounds: nil,
                caretPoint: nil,
                mousePoint: nil,
                sourceConfidence: "electron_partial"
            )
        )!
        let withCaret = ScreenAnnotator.annotate(
            pngData: png,
            captureRect: captureRect,
            markers: ScreenAnnotator.Markers(
                focusedBounds: nil,
                caretPoint: CGPoint(x: 300, y: 170),
                mousePoint: nil,
                sourceConfidence: "electron_partial"
            )
        )!
        // Caret is dropped on `electron_partial`, so the two outputs
        // should be byte-identical.
        XCTAssertFalse(pixelsDiffer(baseline, withCaret))
    }

    func testMouseMarkerDrawsRegardlessOfSourceConfidence() {
        let png = makeBlankPNG()
        let baseline = ScreenAnnotator.annotate(
            pngData: png,
            captureRect: captureRect,
            markers: ScreenAnnotator.Markers(
                focusedBounds: nil,
                caretPoint: nil,
                mousePoint: nil,
                sourceConfidence: "terminal_none"
            )
        )!
        let withMouse = ScreenAnnotator.annotate(
            pngData: png,
            captureRect: captureRect,
            markers: ScreenAnnotator.Markers(
                focusedBounds: nil,
                caretPoint: nil,
                mousePoint: CGPoint(x: 250, y: 200),
                sourceConfidence: "terminal_none"
            )
        )!
        XCTAssertTrue(pixelsDiffer(baseline, withMouse))
    }

    func testMarkersOutsideCaptureRectAreSkippedNotClamped() {
        let png = makeBlankPNG()
        let baseline = ScreenAnnotator.annotate(
            pngData: png,
            captureRect: captureRect,
            markers: ScreenAnnotator.Markers(
                focusedBounds: nil,
                caretPoint: nil,
                mousePoint: nil,
                sourceConfidence: "native_ax"
            )
        )!
        // Cursor parked on a second monitor far outside the capture rect.
        let outOfBoundsMouse = CGPoint(x: -500, y: -500)
        let outsideBounds = CGRect(x: -1000, y: -1000, width: 50, height: 50)
        let result = ScreenAnnotator.annotate(
            pngData: png,
            captureRect: captureRect,
            markers: ScreenAnnotator.Markers(
                focusedBounds: outsideBounds,
                caretPoint: CGPoint(x: -250, y: -250),
                mousePoint: outOfBoundsMouse,
                sourceConfidence: "native_ax"
            )
        )!
        XCTAssertFalse(pixelsDiffer(baseline, result))
    }

    func testAnnotateReturnsNilForDegenerateCaptureRect() {
        let png = makeBlankPNG()
        let result = ScreenAnnotator.annotate(
            pngData: png,
            captureRect: CGRect(x: 0, y: 0, width: 0, height: 0),
            markers: ScreenAnnotator.Markers(
                focusedBounds: nil,
                caretPoint: nil,
                mousePoint: nil,
                sourceConfidence: "native_ax"
            )
        )
        XCTAssertNil(result)
    }

    func testFullCoverageBoundsSuppressesOutline() {
        let png = makeBlankPNG()
        let baseline = ScreenAnnotator.annotate(
            pngData: png,
            captureRect: captureRect,
            markers: ScreenAnnotator.Markers(
                focusedBounds: nil,
                caretPoint: nil,
                mousePoint: nil,
                sourceConfidence: "native_ax"
            )
        )!
        // Bounds covering 100% of the capture rect — outline must skip.
        let fullCover = ScreenAnnotator.annotate(
            pngData: png,
            captureRect: captureRect,
            markers: ScreenAnnotator.Markers(
                focusedBounds: captureRect,
                caretPoint: nil,
                mousePoint: nil,
                sourceConfidence: "native_ax"
            )
        )!
        XCTAssertFalse(pixelsDiffer(baseline, fullCover))
    }

    func testDrawCaretAllowedMatrix() {
        XCTAssertTrue(ScreenAnnotator.drawCaretAllowed(for: "native_ax"))
        XCTAssertTrue(ScreenAnnotator.drawCaretAllowed(for: "chromium_input"))
        XCTAssertFalse(ScreenAnnotator.drawCaretAllowed(for: "chromium_contenteditable"))
        XCTAssertFalse(ScreenAnnotator.drawCaretAllowed(for: "electron_partial"))
        XCTAssertFalse(ScreenAnnotator.drawCaretAllowed(for: "terminal_none"))
        XCTAssertFalse(ScreenAnnotator.drawCaretAllowed(for: "unknown"))
    }

    func testDrawFocusedOutlineAllowedMatrix() {
        // Mirrors `drawCaretAllowed`: bounds and caret AX queries are
        // unreliable together, so we gate them together. Mouse marker
        // (NSEvent.mouseLocation) bypasses AX and stays universal.
        XCTAssertTrue(ScreenAnnotator.drawFocusedOutlineAllowed(for: "native_ax"))
        XCTAssertTrue(ScreenAnnotator.drawFocusedOutlineAllowed(for: "chromium_input"))
        XCTAssertFalse(ScreenAnnotator.drawFocusedOutlineAllowed(for: "chromium_contenteditable"))
        XCTAssertFalse(ScreenAnnotator.drawFocusedOutlineAllowed(for: "electron_partial"))
        XCTAssertFalse(ScreenAnnotator.drawFocusedOutlineAllowed(for: "terminal_none"))
        XCTAssertFalse(ScreenAnnotator.drawFocusedOutlineAllowed(for: "unknown"))
    }

    func testFocusedOutlineSkippedForLowConfidenceSurfaces() {
        // Caught dogfooding Conductor: drawing the outline at AX's
        // reported (wrong) bounds was the visible regression. Lock in
        // that an outline-providing markers struct on `electron_partial`
        // produces byte-identical bytes to the no-markers baseline.
        let png = makeBlankPNG()
        let baseline = ScreenAnnotator.annotate(
            pngData: png,
            captureRect: captureRect,
            markers: ScreenAnnotator.Markers(
                focusedBounds: nil,
                caretPoint: nil,
                mousePoint: nil,
                sourceConfidence: "electron_partial"
            )
        )!
        let withOutline = ScreenAnnotator.annotate(
            pngData: png,
            captureRect: captureRect,
            markers: ScreenAnnotator.Markers(
                focusedBounds: CGRect(x: 200, y: 100, width: 100, height: 30),
                caretPoint: nil,
                mousePoint: nil,
                sourceConfidence: "electron_partial"
            )
        )!
        XCTAssertFalse(pixelsDiffer(baseline, withOutline))
    }
}
