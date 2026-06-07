#if DEBUG
import SwiftUI

// MARK: - LGProto08  "Tint flush glint"
//
// No corner element, no morph. Just the Reading puck with a cool-light
// color flush driven through `.regular.tint(…)` as `p` (0→1) advances.
//
// Timeline loop period = 3.6 s.
//   • p 0.10–0.55  puck fades + scales in (lgSpring / lgEaseOut)
//   • p 0.28–0.70  flush of lgBlue washes through the glass tint, peak at ~0.49
//                  (lgBump applied over the segment gives a smooth bell)
//
// The combined effect: the puck materialises with a wave of cold blue light
// passing through it, then settles to clear glass — a single perceptual "glint".
// Uses real glassEffect (macOS 26) — only renders in Xcode's preview canvas.
// NOT shipped UI.

@available(macOS 26.0, *)
struct LGProto08: View {
    var body: some View {
        LGDesktop {
            TimelineView(.animation) { ctx in
                // Normalised progress 0…1 over a 3.6 s loop.
                // The first 1.0 s drives the puck-in + glint animation;
                // the remaining 2.6 s is hold / reset before the next loop.
                let t = ctx.date.timeIntervalSinceReferenceDate
                let p = min(1.0, t.truncatingRemainder(dividingBy: 3.6) / 1.0)

                // --- appearance ---
                let scale   = 0.9 + 0.1 * lgSpring(lgSeg(p, 0.10, 0.60))
                let opacity = lgEaseOut(lgSeg(p, 0.10, 0.55))

                // --- color flush ---
                // Bell-shaped blue tint: rises from clear → lgBlue → clear
                // as p sweeps 0.28→0.70.  Peak opacity ≈ 0.55.
                let flush   = 0.55 * lgBump(lgSeg(p, 0.28, 0.70))

                ZStack {
                    LGBusyBackdrop()

                    // Dock bottom-right with a ~16 pt inset on each side.
                    ZStack(alignment: .bottomTrailing) {
                        Color.clear
                        LGPuckContent()
                            .glassEffect(.regular.tint(lgBlue.opacity(flush)), in: .capsule)
                            .scaleEffect(scale)
                            .opacity(opacity)
                    }
                    .frame(width: lgWinSize.width - 32, height: lgWinSize.height - 32,
                           alignment: .bottomTrailing)
                }
                .frame(width: lgWinSize.width, height: lgWinSize.height)
            }
        }
    }
}

// MARK: - Preview

#Preview("08 · tint flush glint") {
    if #available(macOS 26.0, *) { LGProto08() }
}
#endif
