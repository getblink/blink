import SwiftUI

/// The chrome around `WelcomeCanvasView`: title/body copy block on top,
/// canvas in the middle, page dots + advance hint on bottom. The whole
/// container is the tap target — there are no buttons.
struct WelcomeSlideContainer: View {
    let copySlide: WelcomeSlide
    let phase: WelcomePhase
    let copyVisible: Bool
    let slideIndex: Int
    let totalSlides: Int
    let canAdvance: Bool
    let onTap: () -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            // Copy fades out then in sequentially (driven by copyVisible in
            // WelcomePreview) so two different titles never overlap and
            // become unreadable. The canvas morphs in place via its phase
            // animation.
            copyBlock
                .opacity(copyVisible ? 1 : 0)
            WelcomeCanvasView(phase: phase)
            footer
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }

    /// Fixed-height copy block so the canvas stays in the same vertical
    /// position across slides — no jitter when title/body lengths differ.
    private var copyBlock: some View {
        VStack(spacing: 8) {
            Text(copySlide.title)
                .font(.system(size: 24, weight: .semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Text(copySlide.body)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)
        }
        .frame(height: 60, alignment: .top)
    }

    private var footer: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 12) {
                pageDots
                // "Click anywhere to continue" — hidden until the dwell
                // timer expires, then fades in to signal advance is enabled.
                Text("Click anywhere to continue")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .opacity(canAdvance ? 0.65 : 0)
                    .animation(.easeIn(duration: 0.3), value: canAdvance)
            }
            // A subtle "Back" affordance on every slide after the first. It's
            // a real button, so its tap is consumed here and never falls
            // through to the container's "click anywhere to advance" gesture.
            if slideIndex > 0 {
                HStack {
                    backButton
                    Spacer()
                }
            }
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
            ForEach(0..<totalSlides, id: \.self) { i in
                Circle()
                    .fill(i == slideIndex ? Color.primary.opacity(0.85) : Color.primary.opacity(0.2))
                    .frame(width: 7, height: 7)
            }
        }
    }
}
