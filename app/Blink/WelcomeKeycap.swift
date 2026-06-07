import SwiftUI

/// The three keycaps (`⌃ ⌥ Space`) that flash on slide 2. Fades in on
/// the `.hotkey` phase and sits at rest — the press itself is the
/// *transition* into `.overlay` (i.e. the user clicked through slide 2),
/// not part of slide 2's own dwell. After pressing, the keycaps fade
/// out and the overlay arrives in their place, so the click visually
/// causes the overlay.
struct WelcomeKeycap: View {
    let phase: WelcomePhase

    @State private var visible: Bool = false
    @State private var pressTrigger: Int = 0

    /// Total length of the press (down + release). Keycaps stay visible
    /// for this long after `.overlay` entry so the press completes
    /// before they fade out.
    private static let pressDuration: Duration = .milliseconds(420)

    var body: some View {
        HStack(spacing: 4) {
            badge("⌃")
            badge("⌥")
            badge("Space", wide: true)
        }
        .opacity(visible ? 1 : 0)
        .animation(.easeOut(duration: 0.3), value: visible)
        .keyframeAnimator(initialValue: Motion(), trigger: pressTrigger) { content, motion in
            content.scaleEffect(motion.scale)
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                // Press down — keys dip smaller (a real keypress travels
                // downward, not up).
                SpringKeyframe(0.88, duration: 0.17)
                // Release/settle.
                SpringKeyframe(1.0, duration: 0.25)
            }
        }
        // `.task(id: phase)` cancels on phase change so a late fade-out
        // from a previous phase can't clobber the current visibility.
        .task(id: phase) {
            switch phase {
            case .hotkey:
                visible = true
            case .overlay:
                // Slide-2 → slide-3 transition: the click. Press the
                // keys, then fade them out so the overlay takes the
                // stage.
                pressTrigger += 1
                try? await Task.sleep(for: Self.pressDuration)
                if !Task.isCancelled {
                    visible = false
                }
            default:
                visible = false
            }
        }
    }

    private func badge(_ text: String, wide: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            // Fixed light keycap + dark glyph in both light and dark mode.
            // A physical key reads as a light key regardless of system
            // appearance, and a solid fill avoids the muddy dark-glass
            // look of an adaptive material.
            .foregroundStyle(.black.opacity(0.78))
            .frame(minWidth: wide ? 64 : 30, minHeight: 30)
            .padding(.horizontal, wide ? 10 : 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.97)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.black.opacity(0.12)))
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
    }

    private struct Motion {
        var scale: CGFloat = 1.0
    }
}
