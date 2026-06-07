#if DEBUG
import SwiftUI

// MARK: - LGProto14 — "B1 · snap-in lens → fade-out"
//
// Refines B (condense). The clear full-window lens APPEARS INSTANTLY on capture
// (no fade-in — the screen just becomes glass), holds a beat, then fades OUT in
// place. The Reading pill condenses up from a nub as the lens leaves.

@available(macOS 26.0, *)
struct LGProto14: View {
    var body: some View {
        LGDesktop {
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let p = min(1.0, t.truncatingRemainder(dividingBy: 4.0) / 1.5)

                // lens: full from p=0 (instant), holds, fades out over [0.30, 0.70]
                let lensOpacity = 1 - lgEaseOut(lgSeg(p, 0.30, 0.70))
                // pill condenses in as the lens leaves
                let grow = lgSpring(lgSeg(p, 0.40, 0.95))
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
                            .scaleEffect(pillScale)
                            .opacity(pillOpacity)
                    }
                    .frame(width: lgWinSize.width - 32, height: lgWinSize.height - 32, alignment: .bottomTrailing)
                }
                .frame(width: lgWinSize.width, height: lgWinSize.height)
            }
        }
    }
}

#Preview("B1 · snap-in → fade-out") {
    if #available(macOS 26.0, *) { LGProto14() }
}
#endif
