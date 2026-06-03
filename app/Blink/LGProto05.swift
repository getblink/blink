#if DEBUG
import SwiftUI

// MARK: - LGProto05  "Two blobs merge → puck"
//
// Demonstrates GlassEffectContainer's gooey liquid-merge behaviour.
// Two .regular glass circles sit ~90 pt apart in the bottom-right corner.
// Because the container's spacing: 44 > their gap, they read as already
// partially merged.  On the morph beat, both IDs collapse into a single
// capsule puck — the container animates the coalesce in one fluid move.
// Loops every 3 s.  Uses real glassEffect (macOS 26 / Xcode preview only).

@available(macOS 26.0, *)
struct LGProto05: View {

    @Namespace private var ns
    @State private var open = false

    var body: some View {
        LGDesktop {
            ZStack {
                LGBusyBackdrop()

                // Anchor the container flush with the bottom-right corner so
                // both circles land in that region without extra offset math.
                GlassEffectContainer(spacing: 44) {
                    if open {
                        // Single merged puck — both blob IDs dissolve into this one.
                        // We assign the primary blob ID so the container knows
                        // which anchor to treat as the destination.
                        LGPuckContent()
                            .glassEffect(.regular, in: .capsule)
                            .glassEffectID("p" as AnyHashable, in: ns)
                    } else {
                        // Two sibling blobs inside the same GlassEffectContainer.
                        // Their proximity (they'll land ~90 pt apart, well within
                        // the container's spacing: 44 merge field) makes them
                        // visually gooey-connected even before the morph.
                        HStack(spacing: 90) {
                            // Left blob — secondary
                            LGP05Blob(size: 38)
                                .glassEffectID("q" as AnyHashable, in: ns)

                            // Right blob — primary (destination anchor)
                            LGP05Blob(size: 44)
                                .glassEffectID("p" as AnyHashable, in: ns)
                        }
                    }
                }
                // Pin the whole container to the bottom-right, matching the
                // Dock-corner convention used by the other protos.
                .frame(
                    width: lgWinSize.width - 32,
                    height: lgWinSize.height - 32,
                    alignment: .bottomTrailing
                )
            }
            .frame(width: lgWinSize.width, height: lgWinSize.height)
        }
        .onAppear {
            // Initial beat after 0.6 s so the canvas isn't static on open.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                withAnimation(.bouncy(duration: 0.7)) { open = true }
            }
            // Loop every 3 s to keep the merge/split cycling.
            Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
                withAnimation(.bouncy(duration: 0.7)) { open.toggle() }
            }
        }
    }
}

// MARK: - LGP05Blob

/// A plain .regular glass circle used as one of the two pre-merge blobs.
@available(macOS 26.0, *)
private struct LGP05Blob: View {
    var size: CGFloat
    var body: some View {
        Color.clear
            .frame(width: size, height: size)
            .glassEffect(.regular, in: .circle)
    }
}

// MARK: - Preview

#Preview("05 · two blobs merge") {
    if #available(macOS 26.0, *) { LGProto05() }
}
#endif
