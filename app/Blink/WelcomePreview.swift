import AppKit
import SwiftUI

/// Top-level state for the welcome slideshow. Drives `slideIndex` and the
/// unskippable per-slide dwell timer; everything visual lives in
/// `WelcomeSlideContainer` and the components it composes.
///
/// Not a fixture — users do not interact with the canvas. The activation
/// moment (first real hotkey press on the user's own desktop) lives in a
/// later step.
struct WelcomePreview: View {
    var onComplete: () -> Void = {}

    @State private var slideIndex: Int = 0
    /// Copy index lags `slideIndex` so the title/body can fade out, swap
    /// while hidden, and fade back in — the canvas (driven by slideIndex)
    /// still reacts immediately.
    @State private var copyIndex: Int = 0
    @State private var copyVisible: Bool = true
    @State private var showHint: Bool = false
    /// The in-flight copy fade, held so a rapid second navigation can cancel
    /// it — otherwise overlapping fade tasks race and can leave the copy
    /// stuck invisible.
    @State private var copyFadeTask: Task<Void, Never>?

    /// How long after a slide appears before the "Click anywhere" hint
    /// fades in — roughly the length of the slide's entrance animation.
    /// This gates only the *hint*, never the click itself, so advancing
    /// always feels responsive and the animation (not a forced dwell)
    /// carries the pacing.
    private static let hintDelay: Duration = .milliseconds(1300)
    /// Time the copy spends faded out before swapping to the next slide's
    /// text — keeps the two titles from ever overlapping mid-fade.
    private static let copyFadeOut: Duration = .milliseconds(200)

    static let defaultSlides: [WelcomeSlide] = [
        WelcomeSlide(
            phase: .cursorLanded,
            title: "When you're about to type a reply",
            body: "Blink waits in the background. Focus any text field to wake it up."
        ),
        WelcomeSlide(
            phase: .hotkey,
            title: "Press ⌃⌥Space",
            body: "That's the default hotkey. You can change it in Settings."
        ),
        WelcomeSlide(
            phase: .overlay,
            title: "Blink reads the thread and drafts three replies",
            body: "Summary up top, three replies below — in your voice."
        ),
        WelcomeSlide(
            phase: .chose,
            title: "Pick one — press 1, 2, or 3",
            body: "Your reply is inserted directly into the field. Esc to dismiss."
        ),
    ]

    var body: some View {
        WelcomeSlideContainer(
            copySlide: Self.defaultSlides[copyIndex],
            phase: Self.defaultSlides[slideIndex].phase,
            copyVisible: copyVisible,
            slideIndex: slideIndex,
            totalSlides: Self.defaultSlides.count,
            canAdvance: showHint,
            onTap: handleTap,
            onBack: handleBack
        )
        .task(id: slideIndex) {
            showHint = false
            try? await Task.sleep(for: Self.hintDelay)
            if !Task.isCancelled {
                showHint = true
            }
        }
    }

    private func handleTap() {
        // The click is never swallowed; the canvas + copy animations carry
        // the pacing.
        guard slideIndex < Self.defaultSlides.count - 1 else {
            onComplete()
            return
        }
        goTo(slideIndex + 1)
    }

    private func handleBack() {
        guard slideIndex > 0 else { return }
        goTo(slideIndex - 1)
    }

    /// Move to `newIndex`: the canvas reacts immediately at its own
    /// deliberate pace, while the copy fades out, swaps to the new slide's
    /// text while hidden, then fades back in — sequential, so two different
    /// titles never sit on screen at once (the cross-fade overlap was
    /// unreadable). Works the same forward or backward.
    ///
    /// Cancelling any in-flight fade first makes rapid navigation safe: only
    /// the latest task reaches the fade-in, so the copy can't get stranded
    /// invisible. `try?` swallows the sleep's cancellation error, so the
    /// post-sleep `isCancelled` check is what actually stops a stale task.
    private func goTo(_ newIndex: Int) {
        slideIndex = newIndex
        copyFadeTask?.cancel()
        copyFadeTask = Task { @MainActor in
            withAnimation(.easeOut(duration: 0.2)) { copyVisible = false }
            try? await Task.sleep(for: Self.copyFadeOut)
            if Task.isCancelled { return }
            copyIndex = newIndex
            withAnimation(.easeIn(duration: 0.3)) { copyVisible = true }
        }
    }
}

/// One frame of the slideshow. Drives the phase of `WelcomeCanvasView`
/// and supplies the title/body copy shown above it.
struct WelcomeSlide: Identifiable {
    let id = UUID()
    let phase: WelcomePhase
    let title: String
    let body: String
}

/// Visual state of the canvas mock. Each slide pins this to one phase;
/// child components animate based on which phase is current.
enum WelcomePhase: CaseIterable {
    case cursorLanded, hotkey, overlay, chose
}

#Preview {
    WelcomePreview()
        .frame(width: 620, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
}
