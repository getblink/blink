#if DEBUG
import SwiftUI

// MARK: - LGProto16 — "B3 · snap-in → flash & fade" (the pick)
//
// Clear full-window lens appears fast (a ~90ms ease, reads as "just appears"
// without a harsh 1-frame cut), gives a soft FLARE (capture pop), then fades out
// right away — no linger. The Reading pill condenses in as it goes.
//
// Timed in SECONDS off the loop clock so the preview loops SEAMLESSLY: it returns
// to empty (pill fades out) before replaying, so there's no jarring hard-cut
// reset. In the real app this fires once and just ends docked.

@available(macOS 26.0, *)
struct LGProto16: View {
    private let cycle: Double = 2.6     // full loop (s): gesture + loading hold + reset to empty

    // ── Flare knobs ──────────────────────────────────────────────────────────
    // The flare is now an EDGE specular (the glass rim catches light) — NOT a
    // face fill, so it can't strobe the whole window.
    private let flarePeak: Double = 0.85       // brightness of the rim catch (0…1)
    private let flareGlow: Double = 0.40       // brightness of the soft glow around the rim
    private let flareStart: Double = 0.05      // s — flare begins
    private let flareEnd: Double = 0.42        // s — flare done (wider window = softer)

    var body: some View {
        LGDesktop {
            TimelineView(.animation) { ctx in
                let tc = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)

                // lens: fast ease-in (not a hard cut), soft flare, quick fade-out
                let lensIn = lgEaseOut(lgSeg(tc, 0.0, 0.09))
                let lensOut = lgEaseOut(lgSeg(tc, 0.20, 0.48))
                let lensOpacity = lensIn * (1 - lensOut)
                let flare = lgBump(lgSeg(tc, flareStart, flareEnd))

                // pill: condense in, hold (loading), then fade out → loop returns to empty
                let pillIn = lgSpring(lgSeg(tc, 0.30, 0.74))
                let pillScale = 0.2 + 0.8 * pillIn
                let pillFadeIn = lgEaseOut(lgSeg(tc, 0.30, 0.60))
                let pillFadeOut = lgEaseOut(lgSeg(tc, cycle - 0.42, cycle - 0.14))
                let pillOpacity = pillFadeIn * (1 - pillFadeOut)

                ZStack {
                    LGBusyBackdrop()
                    ZStack {
                        Color.clear
                            .frame(width: lgWinSize.width, height: lgWinSize.height)
                            .glassEffect(.clear, in: RoundedRectangle(cornerRadius: lgCorner, style: .continuous))
                        // Flare = the glass RIM briefly catching light (edges only,
                        // no face fill → no full-window strobe). A thin bright stroke
                        // plus a soft glow that blooms past the edge.
                        RoundedRectangle(cornerRadius: lgCorner, style: .continuous)
                            .strokeBorder(.white.opacity(flarePeak * flare), lineWidth: 1.5)
                            .frame(width: lgWinSize.width, height: lgWinSize.height)
                            .shadow(color: .white.opacity(flareGlow * flare), radius: 9)
                    }
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

#Preview("B3 · snap-in → flash & fade") {
    if #available(macOS 26.0, *) { LGProto16() }
}
#endif
