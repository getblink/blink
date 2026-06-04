#if DEBUG
import SwiftUI

// MARK: - LGProto09  "Warm pop → puck"
//
// When closed: a `.regular.tint(lgGold)` glass circle (~52 pt) sits in the
// bottom-right corner — a warm sunlight bubble about to arrive.  On open it
// morphs (GlassEffectContainer + glassEffectID) into the reading puck, keeping
// a faint gold tint (`.regular.tint(lgGold.opacity(0.35))`) so the whole
// moment feels like warm light caught in glass.
//
// The morph self-loops every 3 s (initial trigger at 0.6 s) in the preview
// canvas.  Uses REAL glassEffect (macOS 26) — only renders in Xcode's preview
// canvas.  NOT shipped UI.

@available(macOS 26.0, *)
struct LGProto09: View {
    @Namespace private var ns
    @State private var open = false

    var body: some View {
        LGDesktop {
            ZStack {
                LGBusyBackdrop()

                GlassEffectContainer(spacing: 28) {
                    if open {
                        // Reading puck — warm-gold-tinted capsule
                        LGPuckContent()
                            .glassEffect(.regular.tint(lgGold.opacity(0.35)), in: .capsule)
                            .glassEffectID("e", in: ns)
                    } else {
                        // Gold sunlight bubble
                        LGP09Bubble()
                            .glassEffectID("e", in: ns)
                    }
                }
                .frame(
                    width: lgWinSize.width - 32,
                    height: lgWinSize.height - 32,
                    alignment: .bottomTrailing
                )
            }
            .frame(width: lgWinSize.width, height: lgWinSize.height)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                withAnimation(.bouncy(duration: 0.7)) { open = true }
            }
            Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
                withAnimation(.bouncy(duration: 0.7)) { open.toggle() }
            }
        }
    }
}

// MARK: - LGP09Bubble  (warm gold circle — the "pre-capture" state)

@available(macOS 26.0, *)
private struct LGP09Bubble: View {
    var body: some View {
        Color.clear
            .frame(width: 52, height: 52)
            .glassEffect(.regular.tint(lgGold), in: .circle)
    }
}

// MARK: - Preview

#Preview("09 · warm pop → puck") {
    if #available(macOS 26.0, *) { LGProto09() }
}
#endif
