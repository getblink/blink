import SwiftUI

/// When set (harness only), forces the number of reply cards shown so a
/// static `ImageRenderer` snapshot includes them — the real `.task` that
/// lands them doesn't run off-screen. nil in production → normal behavior.
private struct OverlayForcedCardCountKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}
extension EnvironmentValues {
    var overlayForcedCardCount: Int? {
        get { self[OverlayForcedCardCountKey.self] }
        set { self[OverlayForcedCardCountKey.self] = newValue }
    }
}

/// The Blink overlay mock: a single panel with TL;DR bullets up top and
/// three numbered reply cards below. Arrives after the slide-2 keypress has
/// resolved, then *grows* as each reply card lands — panel and suggestions
/// are one motion, not "full-size container then fill."
///
/// Surface treatment: a clean solid card — pure white in light mode, an
/// elevated dark gray in dark mode. Light mode uses a very soft drop
/// shadow; dark mode uses a subtle "drop light" (a soft white halo) cast by
/// the opaque fill so it reads as lit/floating rather than a muddy shadow.
/// The reply cards are flat chips (fill + hairline border, no shadow).
struct WelcomeOverlayPanel: View {
    let phase: WelcomePhase
    /// Whether the panel is shown. Driven by the parent so the overlay can
    /// linger into `.chose` (through the pick) and only dismiss once the reply
    /// is committed — decoupled from the raw phase.
    let visible: Bool
    /// Which reply card is highlighted as the chosen option (nil = none).
    let selectedIndex: Int?

    @Environment(\.colorScheme) private var scheme
    @Environment(\.overlayForcedCardCount) private var forcedCardCount

    /// Number of reply cards currently mounted. Each increment adds a
    /// card to the VStack, which makes the panel taller — the growth
    /// IS the suggestions arriving.
    @State private var visibleCardCount: Int = 0
    /// Clamped to 3 — the reply-content arrays are fixed-size, so a stray
    /// forced count from the harness must never index past them.
    private var shownCards: Int { min(forcedCardCount ?? visibleCardCount, 3) }

    private var isDark: Bool { scheme == .dark }

    /// Wait for the keycap press to fully resolve — press (~0.3s) plus
    /// fade-out (~0.15s) — and leave a short empty beat before the panel
    /// rises, so the click clearly *causes* the overlay rather than
    /// cross-fading with the keys' exit.
    private static let panelArrivalDelay: TimeInterval = 0.7
    /// First card lands a beat after the panel finishes settling, so
    /// the TL;DR has a moment to register before the panel grows.
    private static let firstCardDelay: Duration = .milliseconds(900)
    /// Spacing between successive cards — tight so the three read as one
    /// quick cascade rather than three separate arrivals.
    private static let cardStagger: Duration = .milliseconds(100)

    /// Arrival uses a deliberate spring after the keypress delay; the exit
    /// (into `.chose`) is a bit quicker than the canvas's 0.7s growth so the
    /// overlay clears promptly and the reply field + text get the stage,
    /// rather than the panel lingering through the whole grow.
    private var panelAnimation: Animation {
        phase == .overlay
            ? .spring(duration: 0.6, bounce: 0.15).delay(Self.panelArrivalDelay)
            : .spring(duration: 0.45, bounce: 0.1)
    }

    var body: some View {
        VStack(spacing: 0) {
            tldrSection
            if shownCards > 0 {
                Divider().padding(.horizontal, 10)
                replyCardsSection
            }
        }
        .frame(width: 318)
        .background(RoundedRectangle(cornerRadius: 10).fill(panelFill))
        // Clip content to the panel shape so a card mid-fade can never
        // extend past the still-growing border — the growth reveals it.
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(panelBorder, lineWidth: 1))
        // Shadow AFTER the clip, so the drop light stays a clean halo cast by
        // the opaque silhouette rather than being clipped away.
        .shadow(color: panelShadow.color, radius: panelShadow.radius, y: panelShadow.y)
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1.0 : 0.96)
        // Keyed on `visible`: arrival rides the delayed spring while
        // `phase == .overlay`, and the dismissal at insertion (`.chose`) uses
        // the quicker exit spring so the panel clears as the reply lands.
        .animation(panelAnimation, value: visible)
        // `.task(id: phase)` auto-cancels when the phase changes, so
        // clicking through to `.chose` before the cards finish landing
        // won't leave a detached Task that repopulates them on the final
        // slide. The post-sleep `isCancelled` check is required because
        // `try?` swallows the cancellation error and would otherwise let
        // the loop continue.
        .task(id: phase) {
            // Hold all three cards through `.chose` so the chosen option can
            // highlight before the parent dismisses the whole panel. Without
            // this the cards would reset to 0 the moment we left `.overlay`.
            if phase == .chose {
                visibleCardCount = 3
                return
            }
            visibleCardCount = 0
            guard phase == .overlay else { return }
            try? await Task.sleep(for: Self.firstCardDelay)
            for i in 1...3 {
                if Task.isCancelled { return }
                // No bounce: the same spring drives both the card's fade-in
                // and the panel's height growth, so a bounce would make the
                // panel size overshoot/settle out of step with the option
                // appearing. Critically damped keeps them locked.
                withAnimation(.spring(duration: 0.4, bounce: 0)) {
                    visibleCardCount = i
                }
                if i < 3 {
                    try? await Task.sleep(for: Self.cardStagger)
                }
            }
        }
    }

    private var tldrSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                HStack(spacing: 6) {
                    Circle().fill(.primary.opacity(0.55)).frame(width: 3, height: 3)
                    RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.72))
                        .frame(width: [220, 240, 180][i], height: 6)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var replyCardsSection: some View {
        VStack(spacing: 4) {
            ForEach(0..<shownCards, id: \.self) { i in
                replyCard(index: i, contentWidth: [220, 250, 180][i])
                    // Panel growth LEADS the fade: the opacity is delayed a
                    // beat behind the height growth (which rides the ambient
                    // spring with no delay), on the same curve/velocity — so
                    // the panel makes room first and the option fades into it.
                    .transition(.asymmetric(
                        insertion: .opacity.animation(
                            .spring(duration: 0.4, bounce: 0).delay(0.12)
                        ),
                        removal: .identity
                    ))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private func replyCard(index: Int, contentWidth: CGFloat) -> some View {
        // The chosen option on the final slide. When set, the card takes an
        // accent fill/border + tinted number and pops once — reading as the
        // user picking it before it lands in the field.
        let isSelected = index == selectedIndex
        return HStack(spacing: 8) {
            // Bare number — no gray chip behind it.
            Text("\(index + 1)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(isSelected ? .blinkAccent : .primary.opacity(0.5))
                .frame(width: 14, height: 14)
            RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.6))
                .frame(width: contentWidth, height: 6)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.blinkAccent.opacity(0.15) : cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.blinkAccent : cardBorder, lineWidth: isSelected ? 1.5 : 1)
        )
        // No shadow or glow on the cards — they're flat chips, defined only
        // by their fill + hairline border. The lone drop light lives on the
        // panel itself.
        .animation(.spring(duration: 0.3, bounce: 0.2), value: selectedIndex)
        // Press-pop on the chosen card — a quick dip-and-settle, mirroring the
        // keycap press, so the pick reads as a tap. Only the selected card's
        // trigger flips, so the others never animate.
        .keyframeAnimator(initialValue: 1.0, trigger: isSelected) { content, scale in
            content.scaleEffect(scale)
        } keyframes: { _ in
            KeyframeTrack {
                SpringKeyframe(0.95, duration: 0.12)
                SpringKeyframe(1.0, duration: 0.22)
            }
        }
    }

    // MARK: - Surfaces

    private var panelFill: Color {
        isDark ? Color(white: 0.17) : .white
    }

    private var panelBorder: Color {
        isDark ? .white.opacity(0.10) : .black.opacity(0.05)
    }

    private var cardFill: Color {
        isDark ? Color(white: 0.25) : .white
    }

    private var cardBorder: Color {
        // Hairline carries the card delineation since there's no shadow.
        isDark ? .white.opacity(0.12) : .black.opacity(0.07)
    }

    /// Light mode: a very soft, low drop shadow. Dark mode: a subtle "drop
    /// light" — a soft white halo instead of a muddy dark shadow.
    private var panelShadow: (color: Color, radius: CGFloat, y: CGFloat) {
        isDark ? (.white.opacity(0.06), 14, 2) : (.black.opacity(0.10), 12, 4)
    }
}
