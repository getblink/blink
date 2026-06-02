import AppKit
import SwiftUI

/// Top-level state for the welcome slideshow. Drives `slideIndex` and the
/// per-step "Click anywhere" hint; everything visual lives in
/// `WelcomeSlideContainer` and the components it composes.
///
/// The flow is a single window: a "Welcome to Blink" landing, the 4-slide
/// tour (cursor → hotkey → overlay → pick), and a live permissions step that
/// replaces the old separate AppKit wizard for first-run. The activation
/// moment (first real hotkey press on the user's own desktop) lives in the
/// demo card that follows, once permissions are granted.
struct WelcomePreview: View {
    /// Owns the live permission probing, telemetry, auto-chain, and the
    /// hotkey-start / relaunch fallback for the permissions step. Injected so
    /// the window controller can wire in the app's real dependencies.
    @StateObject private var permissions: PermissionsModel

    @State private var slideIndex: Int = 0
    /// Copy index lags `slideIndex` so the title/body can fade out, swap
    /// while hidden, and fade back in — the middle (driven by slideIndex)
    /// still reacts immediately.
    @State private var copyIndex: Int = 0
    @State private var copyVisible: Bool = true
    @State private var showHint: Bool = false
    /// Set per-navigation: true when the move crosses a landing/permissions
    /// boundary, so the container fades the middle + dots with the copy as one
    /// unit (vs. staying solid and morphing within the tour).
    @State private var middleFades: Bool = false
    /// The in-flight copy fade, held so a rapid second navigation can cancel
    /// it — otherwise overlapping fade tasks race and can leave the copy
    /// stuck invisible.
    @State private var copyFadeTask: Task<Void, Never>?

    init(model: PermissionsModel, startAtPermissions: Bool = false) {
        _permissions = StateObject(wrappedValue: model)
        // Resume directly at the permissions step (e.g. after a mid-grant
        // relaunch) instead of replaying the landing + tour.
        let start = startAtPermissions ? (Self.steps.count - 1) : 0
        _slideIndex = State(initialValue: start)
        _copyIndex = State(initialValue: start)
    }

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

    /// Landing copy. The hero icon + "Get started" button live in the middle;
    /// these strings fill the shared copy block.
    static let landingTitle = "Welcome to Blink"
    static let landingSubtitle = "Reads your screen and writes the rest — in your voice."

    /// The closing permissions step. Live grant checklist — replaces the old
    /// framing slide and the separate AppKit wizard for first-run.
    static let framingTitle = "A couple of permissions to get going"
    static let framingSubtitle = "Just what Blink needs for the loop you just saw."

    /// One typed entry per step: landing, the four tour slides, then
    /// permissions. The bookends are dot-less; the tour carries the page dots.
    struct Step {
        let kind: WelcomeStepKind
        let title: String
        let subtitle: String
        /// Canvas phase. Pinned to `.chose` on the bookends so the canvas
        /// rests at its final state behind the cross-fade.
        let phase: WelcomePhase
    }

    static let steps: [Step] = {
        var result: [Step] = [
            // Landing pins the (hidden) canvas to the tour's *first* phase, not
            // `.chose`. Otherwise the canvas behind the landing sits prefilled
            // with the inserted reply, and crossing into slide 1 (or Back)
            // animates that text out/in — a visible glitch.
            Step(kind: .landing, title: landingTitle, subtitle: landingSubtitle, phase: .cursorLanded),
        ]
        result += defaultSlides.map {
            Step(kind: .tour, title: $0.title, subtitle: $0.body, phase: $0.phase)
        }
        result.append(
            Step(kind: .permissions, title: framingTitle, subtitle: framingSubtitle, phase: .chose)
        )
        return result
    }()

    private var stepCount: Int { Self.steps.count }
    /// 0-based tour index for the page dots (landing is step 0 → -1, which the
    /// container clamps; dots only render on `.tour` anyway).
    private func tourDotIndex(_ step: Int) -> Int { step - 1 }

    private var permissionsView: WelcomePermissionsView {
        WelcomePermissionsView(
            granted: permissions.granted,
            allGranted: permissions.allGranted,
            needsRelaunch: permissions.needsRelaunch,
            launchAtLogin: permissions.launchAtLogin,
            onOpenSettings: { permissions.openSettings(for: $0) },
            onSetLaunchAtLogin: { permissions.setLaunchAtLogin($0) },
            onGetStarted: { permissions.finish() },
            onRelaunch: { permissions.relaunch() }
        )
    }

    var body: some View {
        WelcomeSlideContainer(
            title: Self.steps[copyIndex].title,
            subtitle: Self.steps[copyIndex].subtitle,
            // Drive the middle's cross-fade off the lagged copyIndex so the
            // canvas→permissions dissolve lands in step with the title swap,
            // not 200ms ahead.
            stepKind: Self.steps[copyIndex].kind,
            phase: Self.steps[slideIndex].phase,
            copyVisible: copyVisible,
            tourDotIndex: tourDotIndex(slideIndex),
            dotCount: Self.defaultSlides.count,
            canAdvance: showHint,
            // Lag Back off copyIndex so it fades with the incoming step.
            showBack: copyIndex > 0,
            middleFades: middleFades,
            permissions: permissionsView,
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
        .onChange(of: slideIndex) { _, newValue in
            // Begin live probing only while the permissions step is on screen;
            // pause (and close the floating helper) when stepping away.
            if Self.steps[newValue].kind == .permissions {
                permissions.start()
            } else {
                permissions.pause()
            }
        }
        .onAppear {
            // Resume case: we open straight on permissions, so onChange never
            // fires — kick off probing here. start() is idempotent.
            if Self.steps[slideIndex].kind == .permissions {
                permissions.start()
            }
        }
    }

    private func handleTap() {
        // The click is never swallowed; the canvas + copy animations carry the
        // pacing. Taps on the permissions step are inert (the container guards
        // them) — completion there runs through the "Get Started" button.
        guard slideIndex < stepCount - 1 else { return }
        goTo(slideIndex + 1)
    }

    private func handleBack() {
        guard slideIndex > 0 else { return }
        goTo(slideIndex - 1)
    }

    /// Move to `newIndex`: the middle reacts immediately at its own deliberate
    /// pace, while the copy fades out, swaps to the new step's text while
    /// hidden, then fades back in — sequential, so two different titles never
    /// sit on screen at once. Works the same forward or backward.
    ///
    /// Cancelling any in-flight fade first makes rapid navigation safe: only
    /// the latest task reaches the fade-in, so the copy can't get stranded
    /// invisible. `try?` swallows the sleep's cancellation error, so the
    /// post-sleep `isCancelled` check is what actually stops a stale task.
    private func goTo(_ newIndex: Int) {
        // A bookend crossing (landing↔tour or tour↔permissions) fades the middle
        // with the copy; tour↔tour keeps the canvas solid and just morphs phase.
        middleFades = Self.steps[slideIndex].kind != Self.steps[newIndex].kind
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
    WelcomePreview(
        model: PermissionsModel(
            eventClient: nil,
            allowLogging: { false },
            clientMetadata: { [:] },
            attemptHotkeyStart: { false },
            onComplete: {}
        )
    )
    .frame(width: 620, height: 540)
    .background(Color(nsColor: .windowBackgroundColor))
}
