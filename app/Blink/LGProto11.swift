#if DEBUG
import SwiftUI

// MARK: - LGProto11 — "A · lens → blob morph"
//
// The full-window CLEAR lens fades in place (separate layer, NOT in the glass
// container — that's what broke the first cut). The Reading pill emerges as a
// blob via a solo `GlassEffectContainer` morph: a small glass circle morphs into
// the pill capsule (gooey shape change), revealed as the lens dissolves over it.

@available(macOS 26.0, *)
struct LGProto11: View {
    @Namespace private var ns
    @State private var lensOn = false
    @State private var budded = false

    var body: some View {
        LGDesktop {
            ZStack {
                LGBusyBackdrop()

                // Pill blob morph — positioned bottom-right via a wrapper so the
                // glass keeps its natural (small) size; the container holds only
                // the morphing element.
                ZStack(alignment: .bottomTrailing) {
                    Color.clear
                    GlassEffectContainer(spacing: 18) {
                        Group {
                            if budded {
                                LGPuckContent().glassEffect(.regular, in: .capsule)
                            } else {
                                Color.clear.frame(width: 28, height: 28).glassEffect(.regular, in: .circle)
                            }
                        }
                        .glassEffectID("pill", in: ns)
                    }
                }
                .frame(width: lgWinSize.width - 32, height: lgWinSize.height - 32, alignment: .bottomTrailing)
                .opacity(lensOn || budded ? 1 : 0)

                // Full-window clear lens on top — fades in / out in place, no motion.
                Color.clear
                    .frame(width: lgWinSize.width, height: lgWinSize.height)
                    .glassEffect(.clear, in: RoundedRectangle(cornerRadius: lgCorner, style: .continuous))
                    .opacity(lensOn ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .frame(width: lgWinSize.width, height: lgWinSize.height)
        }
        .onAppear(perform: loop)
    }

    private func loop() {
        func go() {
            withAnimation(.easeOut(duration: 0.35)) { lensOn = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                withAnimation(.bouncy(duration: 0.7)) { budded = true }
                withAnimation(.easeIn(duration: 0.5)) { lensOn = false }
            }
        }
        go()
        Timer.scheduledTimer(withTimeInterval: 3.6, repeats: true) { _ in
            withAnimation(.easeIn(duration: 0.3)) { budded = false; lensOn = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { go() }
        }
    }
}

#Preview("11 · lens → blob morph") {
    if #available(macOS 26.0, *) { LGProto11() }
}
#endif
