#if DEBUG
import SwiftUI

// MARK: - LGProto12 — "B · lens → condense in place"
//
// The full-window CLEAR lens fades out in place (no movement). The Reading pill
// CONDENSES into existence at the corner: it nucleates as a tiny glass nub and
// springs up to full size with an organic overshoot, timed so it "firms up" as
// the lens dissolves. No container/metaball — the simplest, most reliable take:
// the glass appears to settle/gather into the pill where it sat. Progress-driven.

@available(macOS 26.0, *)
struct LGProto12: View {
    var body: some View {
        LGDesktop {
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let p = min(1.0, t.truncatingRemainder(dividingBy: 3.6) / 1.1)

                // lens: in (0→0.18), hold, out (0.45→0.80) — purely opacity, no movement
                let lensOpacity = lgEaseOut(lgSeg(p, 0.0, 0.18)) * (1 - lgEaseOut(lgSeg(p, 0.45, 0.80)))
                // pill: nucleate + spring up as the lens fades
                let grow = lgSpring(lgSeg(p, 0.40, 0.92))
                let pillScale = 0.18 + 0.82 * grow
                let pillOpacity = lgEaseOut(lgSeg(p, 0.40, 0.72))

                ZStack {
                    LGBusyBackdrop()
                    Color.clear
                        .frame(width: lgWinSize.width, height: lgWinSize.height)
                        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: lgCorner, style: .continuous))
                        .opacity(lensOpacity)
                    ZStack(alignment: .bottomTrailing) {
                        Color.clear
                        LGPuckContent()
                            .glassEffect(.regular, in: .capsule)
                            .scaleEffect(pillScale, anchor: .center)
                            .opacity(pillOpacity)
                    }
                    .frame(width: lgWinSize.width - 32, height: lgWinSize.height - 32, alignment: .bottomTrailing)
                }
                .frame(width: lgWinSize.width, height: lgWinSize.height)
            }
        }
    }
}

#Preview("12 · lens → condense") {
    if #available(macOS 26.0, *) { LGProto12() }
}
#endif
