#if DEBUG
import SwiftUI

// MARK: - LGProto13 — "C · lens → pinch-off (real metaball separation)"
//
// The genuinely-different third take. Two glass blobs share a GlassEffectContainer
// and start MERGED (overlapping → one peanut shape). On capture, the droplet
// slides away from the anchor and grows into the pill, so the gooey metaball NECK
// stretches between them and SNAPS — a droplet pinching off a bead of glass. The
// anchor then fades; the clear full-window lens fades in place behind it.
//
// (vs A, which is an in-place circle→capsule morph — no second blob, no neck.)

@available(macOS 26.0, *)
struct LGProto13: View {
    @Namespace private var ns
    @State private var lensOn = false
    @State private var separated = false

    // where the anchor bead sits relative to the docked pill (up-left of it)
    private let anchorDX: CGFloat = -52
    private let anchorDY: CGFloat = -42

    var body: some View {
        LGDesktop {
            ZStack {
                LGBusyBackdrop()

                ZStack(alignment: .bottomTrailing) {
                    Color.clear
                    GlassEffectContainer(spacing: 26) {
                        // anchor bead — the source the droplet pinches from; fades after
                        Color.clear.frame(width: 32, height: 32)
                            .glassEffect(.regular, in: .circle)
                            .glassEffectID("anchor", in: ns)
                            .offset(x: anchorDX, y: anchorDY)
                            .opacity(separated ? 0 : 1)

                        // droplet → pill: starts ON the anchor (merged), then slides
                        // to the dock + grows to the capsule → neck stretches & snaps
                        Group {
                            if separated {
                                LGPuckContent().glassEffect(.regular, in: .capsule)
                            } else {
                                Color.clear.frame(width: 26, height: 26).glassEffect(.regular, in: .circle)
                            }
                        }
                        .glassEffectID("drop", in: ns)
                        .offset(x: separated ? 0 : anchorDX, y: separated ? 0 : anchorDY)
                    }
                }
                .frame(width: lgWinSize.width - 32, height: lgWinSize.height - 32, alignment: .bottomTrailing)
                .opacity(lensOn || separated ? 1 : 0)

                // clear full-window lens — fades in place, no motion
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
                withAnimation(.bouncy(duration: 0.8)) { separated = true }   // pinch off
                withAnimation(.easeIn(duration: 0.55)) { lensOn = false }
            }
        }
        go()
        Timer.scheduledTimer(withTimeInterval: 3.8, repeats: true) { _ in
            withAnimation(.easeIn(duration: 0.3)) { separated = false; lensOn = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { go() }
        }
    }
}

#Preview("13 · lens → pinch-off") {
    if #available(macOS 26.0, *) { LGProto13() }
}
#endif
