#if DEBUG
import SwiftUI

// MARK: - LGProto02  "Morph + blue tint glint"
//
// A corner circle (tinted blue) morphs into the reading puck via GlassEffectContainer.
// One beat after the morph lands the tint fades to plain .regular — the cool-blue
// "glint" drains away, leaving a clean glass puck.  Uses glassEffect (macOS 26 API).
// Runs entirely in Xcode's preview canvas; not shipped UI.

@available(macOS 26.0, *)
struct LGProto02: View {

    @Namespace private var ns

    /// Whether the puck is open (fully morphed from blob)
    @State private var open = false
    /// Whether the blue tint glint is still active
    @State private var cool = true

    // Timer reference so we can cancel if needed
    @State private var LGP02timer: Timer? = nil

    var body: some View {
        LGDesktop {
            ZStack {
                LGBusyBackdrop()

                GlassEffectContainer(spacing: 28) {
                    if open {
                        LGP02Puck(cool: cool)
                            .glassEffectID("e", in: ns)
                    } else {
                        LGP02Blob(cool: cool)
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
            .onAppear {
                // 1. After 0.6 s, morph blob → puck
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    withAnimation(.bouncy(duration: 0.7)) {
                        open = true
                    }
                    // 2. After morph settles (~0.8 s later), drain the blue tint
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
                        withAnimation(.easeOut(duration: 0.5)) {
                            cool = false
                        }
                    }
                }

                // 3. Every 3 s thereafter, toggle open in withAnimation so the morph
                //    loops for the preview canvas demo.
                let t = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
                    // Capture the state BEFORE toggling to know the new direction.
                    let willOpen = !open
                    withAnimation(.bouncy(duration: 0.7)) {
                        open.toggle()
                    }
                    if willOpen {
                        // Morphing blob→puck: reset tint first so we start cool…
                        withAnimation(.easeIn(duration: 0.2)) { cool = true }
                        // …then drain it once the puck has settled
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
                            withAnimation(.easeOut(duration: 0.5)) { cool = false }
                        }
                    } else {
                        // Morphing puck→blob: immediately restore tint so blob is cool
                        withAnimation(.easeIn(duration: 0.2)) { cool = true }
                    }
                }
                LGP02timer = t
            }
        }
    }
}

// MARK: - LGP02Blob  (corner-circle waiting state)

@available(macOS 26.0, *)
private struct LGP02Blob: View {
    var cool: Bool
    var body: some View {
        Color.clear
            .frame(width: 44, height: 44)
            .glassEffect(
                cool
                    ? .regular.tint(lgBlue.opacity(0.50))
                    : .regular,
                in: .circle
            )
    }
}

// MARK: - LGP02Puck  (reading puck, tinted → untinted)

@available(macOS 26.0, *)
private struct LGP02Puck: View {
    var cool: Bool
    var body: some View {
        LGPuckContent()
            .glassEffect(
                cool
                    ? .regular.tint(lgBlue.opacity(0.50))
                    : .regular,
                in: .capsule
            )
    }
}

// MARK: - Preview

#Preview("02 · morph + blue tint") {
    if #available(macOS 26.0, *) { LGProto02() }
}
#endif
