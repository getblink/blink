import AppKit
import CoreGraphics
import Foundation

/// Draws subtle markers onto a captured PNG so the vision model can see
/// where the focused element, caret, and mouse cursor are. macOS screen
/// capture omits the mouse cursor and the blinking caret by default, and
/// even the focused-element boundary is invisible in most apps — so the
/// model has no visual anchor for "where is the user about to type."
///
/// The translation from AppKit-screen coordinates to image pixels is
/// derived per-image from `cgImage.width / captureRect.width`; we never
/// read `NSScreen.backingScaleFactor`. That single ratio bakes the right
/// scale in for 1× / 2× / 3× displays, mixed-DPI multi-monitor, window
/// crops, and full-screen captures alike. Stroke widths are multiplied
/// by the same ratio so the marker line is the same physical thickness
/// regardless of display scale.
///
/// All marker draws are independent and gated by `captureRect.contains`
/// — markers outside the captured rect are *skipped*, never clamped to
/// the edge. A misleading edge-stuck marker is worse than no marker,
/// because the vision model trusts what it sees on the pixels.
enum ScreenAnnotator {
    struct Markers {
        /// Focused element bounds in AppKit-screen coordinates (origin
        /// bottom-left, +Y up). Already Y-flipped from raw AX by
        /// `FocusedContextCapture.axBoundsToScreen`.
        let focusedBounds: CGRect?
        /// Caret position in AppKit-screen coordinates.
        let caretPoint: CGPoint?
        /// Mouse cursor in AppKit-screen coordinates (`NSEvent.mouseLocation`).
        let mousePoint: CGPoint?
        /// `FocusedContextCapture.deriveSourceConfidence` output. When
        /// not in `{native_ax, chromium_input}`, the caret marker is
        /// suppressed — drawing it on a stale/{0,0} AX selection would
        /// mislead the model.
        let sourceConfidence: String
    }

    /// Annotate the given PNG and return new PNG bytes. Returns nil
    /// when decoding/encoding fails or `captureRect` is degenerate;
    /// callers should fall back to the un-annotated bytes on nil.
    static func annotate(
        pngData: Data,
        captureRect: CGRect,
        markers: Markers
    ) -> Data? {
        guard captureRect.width.isFinite, captureRect.height.isFinite,
              captureRect.width > 0, captureRect.height > 0 else {
            return nil
        }
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let pxW = cgImage.width
        let pxH = cgImage.height
        guard pxW > 0, pxH > 0 else { return nil }

        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pxW,
            height: pxH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        // Image-pixel coords have origin top-left, +Y down — the same as
        // CGContext after this draw — so no extra flip is needed for the
        // source image itself.
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: pxW, height: pxH))

        let sx = CGFloat(pxW) / captureRect.width
        let sy = CGFloat(pxH) / captureRect.height

        // Translate AppKit-screen (bottom-left, +Y up) into context-pixel
        // coords. CGBitmapContext defaults to a bottom-left origin with
        // +Y up — the same convention as AppKit-screen — so distance
        // along the y-axis from `captureRect.minY` (window's bottom
        // edge in AppKit) is the same direction as distance from the
        // context's bottom edge. Earlier I had `captureRect.maxY - p.y`
        // here, which produced a top-down "pixels from top" value that
        // the bottom-up context then rendered upside down: a marker
        // intended for y=84% of the image landed at y=16%.
        // `context.draw(cgImage, in:)` already handles the source PNG's
        // top-down byte order correctly when drawing into this bottom-up
        // context, so only marker coords need to match the context's
        // convention.
        func toPixels(_ p: CGPoint) -> CGPoint {
            CGPoint(
                x: (p.x - captureRect.minX) * sx,
                y: (p.y - captureRect.minY) * sy
            )
        }

        // Stroke widths and glyph sizes are specified in *points* (the
        // numbers below are the visually-tuned values at 1×), then
        // multiplied by `sx` so the marker has the same physical
        // thickness at any backing scale.
        let scale = sx

        drawFocusedOutline(
            in: context,
            captureRect: captureRect,
            bounds: markers.focusedBounds,
            transform: toPixels,
            scale: scale
        )
        if drawCaretAllowed(for: markers.sourceConfidence) {
            drawCaret(
                in: context,
                captureRect: captureRect,
                point: markers.caretPoint,
                transform: toPixels,
                scale: scale
            )
        }
        drawMouse(
            in: context,
            captureRect: captureRect,
            point: markers.mousePoint,
            transform: toPixels,
            scale: scale
        )

        guard let annotated = context.makeImage() else { return nil }
        return encodePNG(annotated)
    }

    /// Skip the caret marker on surfaces where AX caret data is known to
    /// be stale or fabricated. Drawing a marker at {0,0} or at an
    /// AX-approximated point on a contentEditable misleads the model.
    static func drawCaretAllowed(for sourceConfidence: String) -> Bool {
        switch sourceConfidence {
        case "native_ax", "chromium_input":
            return true
        default:
            return false
        }
    }

    private static func drawFocusedOutline(
        in context: CGContext,
        captureRect: CGRect,
        bounds: CGRect?,
        transform: (CGPoint) -> CGPoint,
        scale: CGFloat
    ) {
        guard let bounds else { return }
        guard bounds.width >= 8, bounds.height >= 8,
              bounds.width.isFinite, bounds.height.isFinite else { return }
        guard captureRect.intersects(bounds) else { return }
        // Suppress the outline when the focused element covers most of
        // the image — a full-window editor is its own outline, and
        // tracing it just adds noise around the screenshot's edges.
        let bothFraction = (bounds.width * bounds.height)
            / max(captureRect.width * captureRect.height, 1)
        guard bothFraction < 0.6 else { return }

        // Map AppKit-screen corners into context-pixel coords. The
        // CGBitmapContext is bottom-up, so the rect's `y` is the bottom
        // edge and `height` extends upward — matching the natural
        // direction of the AppKit-screen input.
        let bottomLeft = transform(CGPoint(x: bounds.minX, y: bounds.minY))
        let topRight = transform(CGPoint(x: bounds.maxX, y: bounds.maxY))
        let rect = CGRect(
            x: bottomLeft.x,
            y: bottomLeft.y,
            width: topRight.x - bottomLeft.x,
            height: topRight.y - bottomLeft.y
        ).integral

        context.saveGState()
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: 4 * scale,
            cornerHeight: 4 * scale,
            transform: nil
        )
        context.addPath(path)
        context.setStrokeColor(
            red: 0x5D / 255.0,
            green: 0x8E / 255.0,
            blue: 0xFF / 255.0,
            alpha: 0.8
        )
        context.setLineWidth(1.5 * scale)
        context.strokePath()
        context.restoreGState()
    }

    private static func drawCaret(
        in context: CGContext,
        captureRect: CGRect,
        point: CGPoint?,
        transform: (CGPoint) -> CGPoint,
        scale: CGFloat
    ) {
        guard let point else { return }
        guard captureRect.contains(point) else { return }
        let p = transform(point)

        context.saveGState()
        // Soft dark shadow under the caret so it survives on light AND
        // dark backgrounds without picking a foreground color per app.
        context.setShadow(
            offset: CGSize(width: 0, height: 1 * scale),
            blur: 2 * scale,
            color: CGColor(gray: 0, alpha: 0.6)
        )
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)

        // Vertical bar centered horizontally on the caret point. The
        // bar straddles ±9pt vertically from the caret point, which
        // covers the bounds of a typical text line.
        let barWidth = 2 * scale
        let barHeight = 18 * scale
        let bar = CGRect(
            x: p.x - barWidth / 2,
            y: p.y - barHeight / 2,
            width: barWidth,
            height: barHeight
        )
        context.fill(bar)

        // Downward-pointing triangle floating just above the bar so the
        // model can locate the caret even if the bar overlaps a busy
        // background. CGBitmapContext is bottom-up, so "above the bar"
        // means a larger Y in context coords — apex sits just above
        // `bar.maxY`, base sits even higher (apex below base = triangle
        // points down at the bar in the final image).
        let triangleHeight = 6 * scale
        let triangleWidth = 6 * scale
        let apexY = bar.maxY + 2 * scale
        let baseY = apexY + triangleHeight
        let triangleApex = CGPoint(x: p.x, y: apexY)
        let triangleBaseLeft = CGPoint(x: p.x - triangleWidth / 2, y: baseY)
        let triangleBaseRight = CGPoint(x: p.x + triangleWidth / 2, y: baseY)
        context.beginPath()
        context.move(to: triangleApex)
        context.addLine(to: triangleBaseLeft)
        context.addLine(to: triangleBaseRight)
        context.closePath()
        context.fillPath()
        context.restoreGState()
    }

    private static func drawMouse(
        in context: CGContext,
        captureRect: CGRect,
        point: CGPoint?,
        transform: (CGPoint) -> CGPoint,
        scale: CGFloat
    ) {
        guard let point else { return }
        guard captureRect.contains(point) else { return }
        let p = transform(point)

        // Macros-style arrow cursor with the hotspot (tip) at `p`.
        // Coordinates below are in points relative to the tip, expressed
        // top-down (positive Y goes "visually downward"); negated at
        // draw time because the CGBitmapContext is bottom-up. Shape
        // matches the macOS system arrow closely enough that the
        // marker reads as "cursor" instantly without confusing the
        // model — the prior hollow ring left users (and the model)
        // unsure whether it was a marker or part of the underlying UI.
        let arrowOffsets: [(CGFloat, CGFloat)] = [
            ( 0.0,  0.0),   // tip (hotspot)
            ( 0.0, 14.0),   // bottom-left of body
            ( 4.0, 11.0),   // inner-left at tail base
            ( 7.0, 17.0),   // tail bottom-left
            ( 9.0, 16.0),   // tail bottom-right
            ( 6.0, 10.0),   // inner-right at tail base
            (10.0, 10.0),   // right edge of body
        ]

        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -1 * scale),
            blur: 2 * scale,
            color: CGColor(gray: 0, alpha: 0.7)
        )
        context.beginPath()
        for (index, offset) in arrowOffsets.enumerated() {
            let pt = CGPoint(
                x: p.x + offset.0 * scale,
                y: p.y - offset.1 * scale   // bottom-up: subtract to go visually down
            )
            if index == 0 {
                context.move(to: pt)
            } else {
                context.addLine(to: pt)
            }
        }
        context.closePath()
        // Black body with a white halo: black reads on light surfaces
        // (the typical case in macOS), the white stroke gives contrast
        // on dark surfaces. `drawPath(.fillStroke)` strokes the outline
        // half-inside half-outside the fill, but with a 1.5pt stroke
        // the visible white halo around the black is clearly readable.
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.setLineWidth(1.5 * scale)
        context.drawPath(using: .fillStroke)
        context.restoreGState()
    }

    private static func encodePNG(_ cgImage: CGImage) -> Data? {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            "public.png" as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }
}
