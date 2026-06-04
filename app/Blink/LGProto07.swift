#if DEBUG
import SwiftUI

// MARK: - LGProto07  "Zoom big→small"
//
// A large .regular glass RoundedRectangle (~220×150) sits in the bottom-right
// quadrant and shrinks — driven by a continuous TimelineView progress value —
// down to the puck's footprint (~150×40) while its cornerRadius interpolates
// from 20 → 22 (capsule-ish).  LGPuckContent fades in as the box approaches
// puck size (p ∈ [0.4, 0.85]).  The glass view stays pinned to the
// bottomTrailing corner throughout.  Loops every 3.6 s (1 s shrink + 2.6 s
// hold/reset).  macOS 26 / Xcode preview canvas only.

// MARK: - helpers

/// Linear interpolation between two CGFloat values.
private func lgp07Lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
    a + CGFloat(t) * (b - a)
}

// MARK: - LGProto07

@available(macOS 26.0, *)
struct LGProto07: View {
    var body: some View {
        LGDesktop {
            TimelineView(.animation) { ctx in
                // p ∈ [0, 1]: fraction through the 1 s shrink window,
                // then holds at 1 for the remaining ~2.6 s before reset.
                let raw = ctx.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 3.6)
                let p = min(1.0, raw / 1.0)

                // Eased progress — starts fast, decelerates into the puck.
                let ep = lgEaseOut(p)

                // Geometry: big rect → puck
                let startW: CGFloat  = 220
                let startH: CGFloat  = 150
                let startCR: CGFloat =  20
                let endW: CGFloat    = 150
                let endH: CGFloat    =  40
                let endCR: CGFloat   =  22   // near-capsule at puck size

                let w  = lgp07Lerp(startW,  endW,  ep)
                let h  = lgp07Lerp(startH,  endH,  ep)
                let cr = lgp07Lerp(startCR, endCR, ep)

                // Puck label fades in as the box approaches puck size.
                let contentOpacity = lgEaseOut(lgSeg(p, 0.4, 0.85))

                ZStack(alignment: .bottomTrailing) {
                    LGBusyBackdrop()

                    // Shrinking glass element, pinned to bottom-right.
                    LGP07GlassBox(
                        width: w,
                        height: h,
                        cornerRadius: cr,
                        contentOpacity: contentOpacity
                    )
                    .padding(24)   // inset from the canvas edge
                }
                .frame(width: lgWinSize.width, height: lgWinSize.height)
            }
        }
    }
}

// MARK: - LGP07GlassBox

/// The shrinking glass element.  Width, height, cornerRadius, and content
/// opacity are all externally driven so TimelineView can animate them
/// frame-by-frame without maintaining any internal @State.
@available(macOS 26.0, *)
private struct LGP07GlassBox: View {
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    let contentOpacity: Double

    var body: some View {
        LGPuckContent()
            .opacity(contentOpacity)
            // Expand the hit/layout area to the current interpolated size so
            // the glass shape grows around the content as it shrinks to puck.
            .frame(width: width, height: height)
            .glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
    }
}

// MARK: - Preview

#Preview("07 · zoom big→small") {
    if #available(macOS 26.0, *) { LGProto07() }
}
#endif
