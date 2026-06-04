#if DEBUG
import SwiftUI

// MARK: - LGProto06  "Edge rail → puck"
//
// When closed, a thin wide glass capsule hugs the bottom edge of the window
// (width ~190, height ~10) — a barely-visible glass "rail".  On open it morphs
// into the standard reading puck via GlassEffectContainer + glassEffectID, so
// the slim rail grows and rises into a full-height capsule.
//
// The morph loops every 3 s in the preview canvas (initial trigger at 0.6 s).
// Uses REAL glassEffect (macOS 26) — only renders in Xcode's preview canvas.
// NOT shipped UI.

@available(macOS 26.0, *)
struct LGProto06: View {
    @Namespace private var ns
    @State private var open = false

    var body: some View {
        LGDesktop {
            ZStack {
                LGBusyBackdrop()

                GlassEffectContainer(spacing: 24) {
                    if open {
                        // Reading puck — full height capsule
                        LGPuckContent()
                            .glassEffect(.regular, in: .capsule)
                            .glassEffectID("e", in: ns)
                    } else {
                        // Thin glass rail hugging the bottom edge
                        LGP06Rail()
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

// MARK: - LGP06Rail  (thin glass bar — the "rail" state)

@available(macOS 26.0, *)
private struct LGP06Rail: View {
    var body: some View {
        Color.clear
            .frame(width: 190, height: 10)
            .glassEffect(.regular, in: .capsule)
    }
}

// MARK: - Preview

#Preview("06 · edge rail → puck") {
    if #available(macOS 26.0, *) { LGProto06() }
}
#endif
