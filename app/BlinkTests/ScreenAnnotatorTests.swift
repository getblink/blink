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

    /// Decode `png` and return non-grey pixel locations as (x_frac, y_frac)
    /// in 0…1 from the visual top-left. "Non-grey" = differs meaningfully
    /// from the makeBlankPNG fill (0.5, 0.5, 0.5). Used to assert that
    /// drawn markers land at the expected portion of the image.
    private func nonGreyPixelCoords(_ png: Data, threshold: Int = 50) -> [(CGFloat, CGFloat)] {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return []
        }
        let width = cgImage.width
        let height = cgImage.height
        guard let space = cgImage.colorSpace, space.model == .rgb else { return [] }
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let ctx = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Note: `CGContext.draw` into a default bottom-up bitmap context
        // still produces row-major data where row 0 corresponds to the
        // VISUAL TOP of the image (CGImage's bytes are top-down). So
        // `y` below is "rows from the top," exactly matching the user's
        // mental model.
        var result: [(CGFloat, CGFloat)] = []
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                let r = Int(bytes[offset])
                let g = Int(bytes[offset + 1])
                let b = Int(bytes[offset + 2])
                let dr = abs(r - 128)
                let dg = abs(g - 128)
                let db = abs(b - 128)
                if dr > threshold || dg > threshold || db > threshold {
                    result.append((CGFloat(x) / CGFloat(width), CGFloat(y) / CGFloat(height)))
                }
            }
        }
        return result
    }

    func testCaretMarkerLandsAtCorrectYNotInverted() throws {
        // Regression for the Y-inversion bug caught dogfooding on
        // Conductor: a caret at AppKit y near the BOTTOM of the
        // capture rect must render at the BOTTOM of the visual image,
        // not the top. The original toPixels formula computed pixels
        // from the top while drawing into a bottom-up CGBitmapContext,
        // so the marker rendered upside-down by image-height.
        let png = makeBlankPNG()
        // Caret at AppKit (200, 30) inside captureRect (100, 50, 400, 240):
        // 30 is at the very bottom of the rect (rect.minY=50,
        // rect.maxY=290, so y=30 is *below* the rect and would be
        // skipped by `captureRect.contains`). Use y=60 instead — 10pt
        // above the bottom edge, clearly in the lower portion of the
        // rect.
        let caret = CGPoint(x: 300, y: 60)
        let annotated = ScreenAnnotator.annotate(
            pngData: png,
            captureRect: captureRect,
            markers: ScreenAnnotator.Markers(
                focusedBounds: nil,
                caretPoint: caret,
                mousePoint: nil,
                sourceConfidence: "native_ax"
            )
        )!
        let nonGrey = nonGreyPixelCoords(annotated)
        XCTAssertFalse(nonGrey.isEmpty, "caret should have drawn non-grey pixels")
        // Centroid of caret pixels should sit in the bottom third of
        // the image — AppKit y=60 is 10pt above the bottom of a 240pt
        // capture rect, so the marker belongs visually near the
        // bottom of the rendered PNG.
        let avgY = nonGrey.map(\.1).reduce(0, +) / CGFloat(nonGrey.count)
        XCTAssertGreaterThan(avgY, 0.66, "caret marker landed in upper 2/3 of image, indicating Y inversion")
    }

    func testCaretMarkerNearTopOfCaptureRendersNearTopOfImage() throws {
        // Mirror of the bottom test: AppKit y near the TOP of the
        // capture rect should render near the TOP of the image. Locks
        // in that the direction is consistent across the y-axis range
        // and not just for a single sample.
        let png = makeBlankPNG()
        // Caret at AppKit y=280 inside captureRect (100, 50, 400, 240):
        // 10pt below the rect's top edge at y=290.
        let caret = CGPoint(x: 300, y: 280)
        let annotated = ScreenAnnotator.annotate(
            pngData: png,
            captureRect: captureRect,
            markers: ScreenAnnotator.Markers(
                focusedBounds: nil,
                caretPoint: caret,
                mousePoint: nil,
                sourceConfidence: "native_ax"
            )
        )!
        let nonGrey = nonGreyPixelCoords(annotated)
        XCTAssertFalse(nonGrey.isEmpty, "caret should have drawn non-grey pixels")
        let avgY = nonGrey.map(\.1).reduce(0, +) / CGFloat(nonGrey.count)
        XCTAssertLessThan(avgY, 0.33, "caret marker landed in lower 2/3 of image, indicating Y inversion")
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

}
