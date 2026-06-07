#if DEBUG
import SwiftUI

// MARK: - LGProto04  "Puck-only materialize"
//
// No corner element — just the reading puck appearing and disappearing via the
// system Liquid Glass materialize transition.
//
// `.glassEffectTransition(.materialize)` is a view modifier (macOS 26+) that
// configures how the glass surface animates when its surrounding `if` branch
// changes.  Toggling `show` inside `withAnimation` hands entrance/exit off to
// the system's native glass materialize choreography.
//
// Preview-canvas only; not shipped UI.

// MARK: - Root view

@available(macOS 26.0, *)
struct LGProto04: View {

    @State private var show = false

    var body: some View {
        LGDesktop {
            ZStack {
                LGBusyBackdrop()

                // Overlay layer — bottom-right anchored, puck materializes here.
                ZStack(alignment: .bottomTrailing) {
                    if show {
                        LGP04Puck()
                    }
                }
                .frame(
                    width:  lgWinSize.width  - 32,
                    height: lgWinSize.height - 32,
                    alignment: .bottomTrailing
                )
                .animation(.smooth(duration: 0.5), value: show)
            }
            .frame(width: lgWinSize.width, height: lgWinSize.height)
        }
        .onAppear {
            // Initial materialize: wait 0.5 s, then bring the puck in.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.smooth(duration: 0.5)) { show = true }
            }

            // Loop: every 3 s toggle visibility so the materialize plays both ways.
            Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
                withAnimation(.smooth(duration: 0.5)) { show.toggle() }
            }
        }
    }
}

// MARK: - LGP04Puck

/// The reading puck with `.glassEffectTransition(.materialize)` applied so the
/// system drives the glass entrance/exit animation.  Falls back to
/// `.transition(.scale.combined(with: .opacity))` on earlier SDKs.
@available(macOS 26.0, *)
private struct LGP04Puck: View {
    var body: some View {
        LGPuckContent()
            .glassEffect(.regular, in: .capsule)
            .lgp04MaterializeTransition()
            .transition(.scale(scale: 0.88).combined(with: .opacity))
    }
}

// MARK: - lgp04MaterializeTransition modifier shim

/// Applies `.glassEffectTransition(.materialize)` on macOS 26+; no-op on older.
/// Separated into its own modifier so the `if #available` doesn't live inside
/// `body`, keeping LGP04Puck readable.
private struct LGP04MaterializeModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffectTransition(.materialize)
        } else {
            content
        }
    }
}

private extension View {
    func lgp04MaterializeTransition() -> some View {
        modifier(LGP04MaterializeModifier())
    }
}

// MARK: - Preview

#Preview("04 · puck materialize") {
    if #available(macOS 26.0, *) { LGProto04() }
}
#endif
