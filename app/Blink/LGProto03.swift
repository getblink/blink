#if DEBUG
import SwiftUI

// MARK: - LGProto03: "Full-window liquid glass LENS → collapses into the puck"
//
// The whole window briefly turns to CLEAR liquid glass (refraction halos around
// all four edges, but NO dimming/frosting — using the `.clear` variant). Then,
// instead of lingering, the lens *collapses* down toward the bottom-right corner
// (shrinking like LGProto07) and fades away (like LGProto10), resolving into the
// Reading puck. So: window → clear glass → gathers into the corner puck.
//
// Sequence (driven by `p`, 0→1 over ~1.05 s, then holds):
//   p 0.00 → 0.26  lens materialises (clear glass, fade + slight scale)
//   p 0.26 → 0.42  hold — the window is glass
//   p 0.42 → 0.82  lens collapses toward bottom-right + fades out
//   p 0.52 → 0.92  Reading puck springs in at the corner
//
// TUNING: `lgp03Lens` swaps the lens variant (.clear default ↔ .regular).

private let lgp03PuckW: CGFloat = 150
private let lgp03PuckH: CGFloat = 40

private func lgp03Lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }

// MARK: - Lens (clear, full-window → collapses to corner)

@available(macOS 26.0, *)
private struct LGP03Lens: View {
    var p: Double
    var body: some View {
        let appear = lgEaseOut(lgSeg(p, 0.0, 0.26))
        let collapse = lgEaseOut(lgSeg(p, 0.42, 0.82))   // full-window → puck-sized
        let fadeOut = lgEaseOut(lgSeg(p, 0.52, 0.80))
        let w = lgp03Lerp(lgWinSize.width, lgp03PuckW, collapse)
        let h = lgp03Lerp(lgWinSize.height, lgp03PuckH, collapse)
        let r = lgp03Lerp(lgCorner, lgp03PuckH / 2, collapse)
        Color.clear
            .frame(width: w, height: h)
            // LENS VARIANT: .clear refracts without dimming (was .regular, which dimmed).
            .glassEffect(.clear, in: RoundedRectangle(cornerRadius: r, style: .continuous))
            .opacity(appear * (1 - fadeOut))
    }
}

// MARK: - Puck (resolves in as the lens collapses to the corner)

@available(macOS 26.0, *)
private struct LGP03Puck: View {
    var p: Double
    var body: some View {
        let puckP = lgSpring(lgSeg(p, 0.52, 0.92))
        LGPuckContent()
            .glassEffect(.regular, in: .capsule)
            .scaleEffect(0.85 + 0.15 * puckP)
            .opacity(lgEaseOut(lgSeg(p, 0.52, 0.86)))
    }
}

// MARK: - Root

@available(macOS 26.0, *)
struct LGProto03: View {
    var body: some View {
        LGDesktop {
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let p = min(1.0, t.truncatingRemainder(dividingBy: 3.6) / 1.05)
                ZStack {
                    LGBusyBackdrop()
                    // Lens fills the window at full size, then collapses to the
                    // bottom-right corner (bottom-trailing pin = collapse anchor).
                    ZStack(alignment: .bottomTrailing) {
                        Color.clear
                        LGP03Lens(p: p)
                    }
                    .frame(width: lgWinSize.width, height: lgWinSize.height, alignment: .bottomTrailing)
                    // Puck, inset ~16 at the corner.
                    ZStack(alignment: .bottomTrailing) {
                        Color.clear
                        LGP03Puck(p: p)
                    }
                    .frame(width: lgWinSize.width - 32, height: lgWinSize.height - 32, alignment: .bottomTrailing)
                }
                .frame(width: lgWinSize.width, height: lgWinSize.height)
            }
        }
    }
}

#Preview("03 · full-window lens → puck") {
    if #available(macOS 26.0, *) { LGProto03() }
}
#endif
