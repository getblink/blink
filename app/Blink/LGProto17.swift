#if DEBUG
import SwiftUI

// MARK: - LGProto17 — "B2+B3 · snap-in → flare → drain into the pill"
//
// Combines the two favorites. The clear full-window lens APPEARS INSTANTLY,
// gives a quick bright FLARE (B3, the capture "pop"), then DRAINS directionally
// from the top-left toward the bottom-right corner (B2, a masked dissolve) as the
// Reading pill condenses in — so the glass flares, then flows into the pill.

@available(macOS 26.0, *)
struct LGProto17: View {
    var body: some View {
        LGDesktop {
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let p = min(1.0, t.truncatingRemainder(dividingBy: 4.0) / 1.5)

                let flare = lgBump(lgSeg(p, 0.20, 0.44))            // pop right after snap-in
                let drain = lgEaseOut(lgSeg(p, 0.34, 0.78))          // then drains to the corner
                let grow = lgSpring(lgSeg(p, 0.48, 0.96))
                let pillScale = 0.18 + 0.82 * grow
                let pillOpacity = lgEaseOut(lgSeg(p, 0.48, 0.78))

                ZStack {
                    LGBusyBackdrop()

                    // lens + flare drain away together (the mask removes them)
                    ZStack {
                        Color.clear
                            .frame(width: lgWinSize.width, height: lgWinSize.height)
                            .glassEffect(.clear, in: RoundedRectangle(cornerRadius: lgCorner, style: .continuous))
                        RoundedRectangle(cornerRadius: lgCorner, style: .continuous)
                            .fill(.white.opacity(0.28 * flare))
                            .frame(width: lgWinSize.width, height: lgWinSize.height)
                    }
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: min(drain, 0.999)),
                                .init(color: .black, location: min(drain + 0.16, 1.0)),
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )

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

#Preview("B2+B3 · flare → drain") {
    if #available(macOS 26.0, *) { LGProto17() }
}
#endif
