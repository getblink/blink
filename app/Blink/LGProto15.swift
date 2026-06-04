#if DEBUG
import SwiftUI

// MARK: - LGProto15 — "B2 · drain" (immediate, eased, subtle glass)
//
// The clear full-window lens is there from frame one and IMMEDIATELY drains —
// a directional dissolve from the top-left toward the bottom-right corner, as if
// the glass flows into the forming pill. No appear-and-hold, no white fill (so
// nothing to strobe). The drain runs on a non-linear ease-in-out (slow → fast →
// settle), and the glass is a subtle veil (`lensStrength`).

@available(macOS 26.0, *)
struct LGProto15: View {
    // ── Knobs ────────────────────────────────────────────────────────────────
    private let cycle: Double = 2.4          // full loop (s): gesture + short loading hold
    private let lensStrength: Double = 0.62  // overall glass opacity (↓ = subtler veil)
    private let drainDur: Double = 0.62       // s — how long the drain takes

    // ease-OUT (quart): fastest right at the immediate start, then a long, smooth
    // deceleration to a soft stop — decelerating the whole way, never accelerating.
    // Raise the exponent (4 → 5/6) for an even softer, more drawn-out settle.
    private func eased(_ t: Double) -> Double {
        1 - pow(1 - lgClamp(t), 4)
    }

    var body: some View {
        LGDesktop {
            TimelineView(.animation) { ctx in
                let tc = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)

                // drain begins immediately; a 0.05s ease just smooths the loop reset
                // (prevents a hard snap) without delaying the drain.
                let appear = lgEaseOut(lgSeg(tc, 0.0, 0.05))
                let drain = eased(lgSeg(tc, 0.0, drainDur))
                // pill condenses in as the drain crosses the window
                let grow = lgSpring(lgSeg(tc, 0.18, 0.62))
                let pillScale = 0.18 + 0.82 * grow
                let pillOpacity = lgEaseOut(lgSeg(tc, 0.18, 0.52))
                // eyes start NORMAL as the pill forms, then ease to HAPPY and hold
                let happyVal = lgEaseOut(lgSeg(tc, 0.52, 0.92))

                ZStack {
                    LGBusyBackdrop()
                    Color.clear
                        .frame(width: lgWinSize.width, height: lgWinSize.height)
                        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: lgCorner, style: .continuous))
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: min(drain, 0.999)),
                                    .init(color: .black, location: min(drain + 0.16, 1.0)),
                                ],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .opacity(appear * lensStrength)
                    ZStack(alignment: .bottomTrailing) {
                        Color.clear
                        LGPuckContent(happy: happyVal)
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

#Preview("B2 · drain (immediate)") {
    if #available(macOS 26.0, *) { LGProto15() }
}
#endif
