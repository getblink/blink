import AppKit
import SwiftUI

/// Which kind of step the welcome flow is showing. Drives the middle's
/// three-way cross-fade (landing hero ↔ animated tour canvas ↔ permissions
/// checklist) and the footer (page dots show only on the tour).
enum WelcomeStepKind: Equatable {
    case landing
    case tour
    case permissions
}

/// The chrome around the slideshow body: a title/subtitle copy block on top,
/// a step-specific middle (landing hero, animated canvas, or permissions
/// checklist), and page dots + advance hint on the bottom.
///
/// The whole container is the tap target — clicking anywhere advances on the
/// landing and tour steps. The permissions step drives completion through its
/// own "Get Started" button instead, so taps there are inert.
struct WelcomeSlideContainer: View {
    let title: String
    let subtitle: String
    let stepKind: WelcomeStepKind
    /// Tour canvas phase. Pinned to `.chose` on the non-tour bookends so the
    /// canvas sits at its final state behind the cross-fade.
    let phase: WelcomePhase
    let copyVisible: Bool
    /// Active page dot (0-based tour index). Only meaningful on `.tour`.
    let tourDotIndex: Int
    /// Number of tour slides (page dots). The bookends add none.
    let dotCount: Int
    let canAdvance: Bool
    /// Whether to show the Back affordance (every step after the first). Driven
    /// off the lagged copy index so it fades with the incoming step, not the
    /// instant `slideIndex` (which made it pop in).
    let showBack: Bool
    /// True while a transition crosses a landing/permissions boundary. When set,
    /// the middle (and page dots) fade out→in with the copy as a single unit;
    /// within the tour it stays put and only the canvas morphs between phases.
    let middleFades: Bool
    /// Pre-built permissions middle, fed from `PermissionsModel`. Always present
    /// in the cross-fade ZStack; only visible on the `.permissions` step.
    let permissions: WelcomePermissionsView
    let onTap: () -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            copyBlock
                .opacity(copyVisible ? 1 : 0)
            middle
            footer
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            // Only the tour advances on a background tap. The landing and
            // permissions bookends commit through their own buttons ("Get
            // started" / "Get Started"), so a stray click there is inert.
            guard stepKind == .tour else { return }
            onTap()
        }
    }

    /// Fixed-height copy block so the middle stays in the same vertical
    /// position across slides — no jitter when title/subtitle lengths differ.
    private var copyBlock: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)
        }
        .frame(height: 60, alignment: .top)
    }

    /// Opacity of the currently-shown middle. On a bookend crossing it rides
    /// the copy's `copyVisible` fade (out 0→0 at the hidden midpoint, then in),
    /// so the landing/permissions hand-off leaves and arrives as one unit in
    /// step with the title. Within the tour it stays solid so the canvas can
    /// morph phase-to-phase without dissolving.
    private var middleOpacity: Double {
        middleFades ? (copyVisible ? 1 : 0) : 1
    }

    /// The three step bodies share one ZStack. `stepKind` selects which is
    /// shown; the swap happens at the copy's hidden midpoint (opacity 0), so
    /// it's invisible. The canvas defines the height, so the copy block and
    /// footer don't shift across the hand-offs.
    private var middle: some View {
        ZStack {
            landingHero
                .opacity(stepKind == .landing ? middleOpacity : 0)
                .allowsHitTesting(stepKind == .landing)
            WelcomeCanvasView(phase: phase)
                .opacity(stepKind == .tour ? middleOpacity : 0)
                .allowsHitTesting(stepKind == .tour)
            permissions
                .opacity(stepKind == .permissions ? middleOpacity : 0)
                .allowsHitTesting(stepKind == .permissions)
        }
    }

    /// Landing hero: the app icon over a primary "Get started" button. The
    /// "Welcome to Blink" headline + tagline live in the shared copy block.
    private var landingHero: some View {
        VStack(spacing: 24) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 116, height: 116)
                .accessibilityHidden(true)
            Button(action: onTap) {
                Text("Get started")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(minWidth: 120)
                    .padding(.vertical, 4)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.blinkAccent)
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        ZStack(alignment: .top) {
            // Page dots + advance hint — tour only. Always present so they can
            // fade with the same unit as the middle (via middleOpacity) instead
            // of popping in/out. The bookends carry their own CTA in the middle.
            VStack(spacing: 12) {
                pageDots
                Text("Click anywhere to continue")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .opacity(canAdvance ? 0.65 : 0)
                    .animation(.easeIn(duration: 0.3), value: canAdvance)
            }
            .opacity(stepKind == .tour ? middleOpacity : 0)

            // A subtle "Back" affordance on every step after the first. It's a
            // real button, so its tap is consumed here and never falls through
            // to the container's "click anywhere to advance" gesture. Fades on
            // the (lagged) showBack flip rather than popping.
            HStack {
                backButton
                Spacer()
            }
            .opacity(showBack ? 1 : 0)
            .animation(.easeInOut(duration: 0.3), value: showBack)
        }
        .frame(height: 40)
    }

    private var backButton: some View {
        Button(action: onBack) {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                Text("Back")
                    .font(.system(size: 11))
            }
            .foregroundColor(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<dotCount, id: \.self) { i in
                Circle()
                    .fill(i == min(tourDotIndex, dotCount - 1) ? Color.primary.opacity(0.85) : Color.primary.opacity(0.2))
                    .frame(width: 7, height: 7)
            }
        }
    }
}
