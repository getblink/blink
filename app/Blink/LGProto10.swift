#if DEBUG
import SwiftUI

// MARK: - LGProto10  "Clear corner panel"
//
// Tests the `.clear` (high-transparency) glass variant at a large size.
// A `.clear` glass RoundedRectangle (~250×210, cornerRadius ~24) is tucked
// into the BOTTOM-RIGHT corner of the window.  It scales + fades in over
// progress p using lgSpring (scale 0.92→1.0) and lgEaseOut (opacity).
// The panel heavily refracts the colorful LGBusyBackdrop content behind it,
// making the difference between `.clear` and `.regular` immediately visible.
//
// The Reading puck (LGPuckContent wrapped in .regular glass capsule) sits
// at the bottom-right INSIDE/over the clear panel, fading in after p > 0.5.
//
// Loops every 3.6 s (1 s appear + 2.6 s hold).
// macOS 26 / Xcode preview canvas only — real glassEffect required.

// MARK: - LGProto10

@available(macOS 26.0, *)
struct LGProto10: View {
    var body: some View {
        LGDesktop {
            TimelineView(.animation) { ctx in
                let p = min(1.0, ctx.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 3.6) / 1.0)

                ZStack {
                    LGBusyBackdrop()

                    LGP10ClearPanel(p: p)
                }
                .frame(width: lgWinSize.width, height: lgWinSize.height)
            }
        }
    }
}

// MARK: - LGP10ClearPanel

/// The `.clear` glass corner panel + puck overlay, driven by progress p ∈ [0,1].
@available(macOS 26.0, *)
private struct LGP10ClearPanel: View {

    let p: Double

    /// Panel geometry constants.
    private let panelW:  CGFloat = 250
    private let panelH:  CGFloat = 210
    private let panelCR: CGFloat =  24

    /// Edge inset so the panel sits just inside the window corner.
    private let edgeInset: CGFloat = 16

    var body: some View {
        // Eased values derived from p.
        let scaleStart: CGFloat = 0.92
        let scaleEnd:   CGFloat = 1.00
        let scaleFrac   = lgSpring(p)
        let panelScale  = scaleStart + CGFloat(scaleFrac) * (scaleEnd - scaleStart)
        let panelOpacity = lgEaseOut(p)

        // Puck fades in after the panel is mostly present.
        let puckOpacity  = lgEaseOut(lgSeg(p, 0.5, 0.90))

        ZStack(alignment: .bottomTrailing) {
            // ── Clear glass panel ──────────────────────────────────────────
            // `.clear` glass = high transparency; foreground content must be
            // bold enough to read against the heavily refracted backdrop.
            Color.clear
                .frame(width: panelW, height: panelH)
                .glassEffect(
                    .clear,
                    in: RoundedRectangle(cornerRadius: panelCR, style: .continuous)
                )
                .scaleEffect(panelScale, anchor: .bottomTrailing)
                .opacity(panelOpacity)

            // ── Puck inside / over the clear panel ────────────────────────
            // .regular glass on the puck so it reads against the .clear panel.
            LGPuckContent()
                .glassEffect(.regular, in: .capsule)
                .opacity(puckOpacity)
                .padding(20)        // inset from panel's trailing/bottom edges
        }
        // Pin the ZStack's bottomTrailing to the canvas's bottomTrailing.
        .frame(
            width:  lgWinSize.width  - edgeInset,
            height: lgWinSize.height - edgeInset,
            alignment: .bottomTrailing
        )
    }
}

// MARK: - Preview

#Preview("10 · clear corner panel") {
    if #available(macOS 26.0, *) { LGProto10() }
}
#endif
