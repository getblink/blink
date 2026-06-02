import AppKit
import SwiftUI

/// First-run "try Blink on your own window" card.
///
/// The default (and only) first-run demo surface. The card floats in the
/// corner of the screen, watches for the user's first real hotkey press on
/// any window, and celebrates the result.
@MainActor
final class OnboardingDemoCardWindowController: NSObject, NSWindowDelegate {
    enum Outcome {
        /// User pressed the hotkey, saw the suggestions overlay, and the card
        /// finished the celebration. This is the activation moment.
        case firstHotkeyLanded
        /// User explicitly dismissed the card (Skip / close button / Esc).
        case skipped
    }

    fileprivate enum State: Equatable {
        case waiting
        case firing
        case landed
    }

    private let hotkeyDisplay: String
    private let hotkeyParts: [String]
    private let eventClient: BlinkEventClient?
    private let allowLogging: () -> Bool
    private let clientMetadata: () -> [String: Any]
    private let onOutcome: (Outcome) -> Void

    private let requestID: String = UUID().uuidString.lowercased()
    private var shownAt: Date = .distantPast
    private var state: State = .waiting
    private var didFireOutcome = false
    private var didEmitFirstHotkey = false
    private var didEmitFirstSummary = false
    private var didEmitFirstPaste = false
    private var didEmitArmed = false
    private var didAnimateEntrance = false
    private var entranceInFlight = false

    private let cardModel = DemoCardModel(state: .waiting)
    private var panel: NSPanel?
    private var hostingController: NSHostingController<DemoCardView>?
    private var landedDismissWorkItem: DispatchWorkItem?
    private var activationObserver: NSObjectProtocol?

    init(
        hotkeyDisplay: String,
        hotkeyParts: [String],
        eventClient: BlinkEventClient?,
        allowLogging: @escaping () -> Bool,
        clientMetadata: @escaping () -> [String: Any],
        onOutcome: @escaping (Outcome) -> Void
    ) {
        self.hotkeyDisplay = hotkeyDisplay
        self.hotkeyParts = hotkeyParts
        self.eventClient = eventClient
        self.allowLogging = allowLogging
        self.clientMetadata = clientMetadata
        self.onOutcome = onOutcome
        super.init()
    }

    deinit {
        if let observer = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    /// Initial content-size estimate used only for the first frame before the
    /// hosting controller auto-sizes to the SwiftUI content (`sizingOptions =
    /// .preferredContentSize`). Width matches the card's fixed width so only the
    /// height settles. The card is pinned to the corner via `pinToCorner()`.
    fileprivate static let cardSize = CGSize(width: DemoCardView.cardWidth, height: 220)
    private static let cornerInset: CGFloat = 24

    // MARK: - Public lifecycle

    func show() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        shownAt = Date()
        cardModel.state = state
        let view = DemoCardView(
            model: cardModel,
            hotkeyDisplay: hotkeyDisplay,
            hotkeyParts: hotkeyParts,
            onDismiss: { [weak self] in self?.handleSkip() }
        )
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        hostingController = host

        let panel = NSPanel(
            contentViewController: host
        )
        // No `.hudWindow`: we draw our own Liquid Glass card in SwiftUI and
        // keep the panel transparent so its alpha-shaped shadow follows the
        // card's rounded corners. `.closable` keeps ⌘W working even though the
        // native title-bar buttons are hidden (we draw the close control in the
        // card — the native traffic lights render inactive/gray on a
        // non-activating panel, which wouldn't match the design).
        panel.styleMask = [.titled, .closable, .fullSizeContentView, .nonactivatingPanel]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        panel.setContentSize(Self.cardSize)
        panel.alphaValue = 0
        self.panel = panel
        pinToCorner()

        panel.orderFrontRegardless()
        // The first `windowDidResize` (after the hosting controller settles its
        // preferred size) is the primary entrance trigger, so the animation
        // runs at the final size. This delayed call is a fallback for the rare
        // case where no resize fires; both are guarded by `didAnimateEntrance`.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.animateEntranceIfNeeded()
        }

        installActivationObserver()
        emit("onboarding_demo_card_shown", details: ["hotkey_display": hotkeyDisplay])
    }

    /// Programmatic close. Does NOT fire an outcome.
    func close() {
        landedDismissWorkItem?.cancel()
        landedDismissWorkItem = nil
        panel?.close()
        panel = nil
        hostingController = nil
    }

    /// Emit abandoned telemetry. Call from `applicationWillTerminate` if the
    /// card is still alive and no hotkey has fired.
    func noteAppWillTerminate() {
        guard panel != nil else { return }
        if !didEmitFirstHotkey {
            emit(
                "onboarding_demo_abandoned",
                details: ["ms_since_shown": msSinceShown]
            )
        }
    }

    // MARK: - Signals from BlinkApp

    /// Called from the hotkey path on every summary fire. First fire while the
    /// card is alive transitions us into `firing` and hides the panel so it
    /// doesn't fight the suggestions overlay.
    func noteHotkeyInvoked() {
        guard panel != nil, state == .waiting else { return }
        setState(.firing)
        panel?.orderOut(nil)
        if !didEmitFirstHotkey {
            didEmitFirstHotkey = true
            emit(
                "onboarding_demo_first_hotkey",
                details: [
                    "ms_since_shown": msSinceShown,
                    "trigger_bundle_id": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown",
                ]
            )
        }
    }

    /// Called when the Blink suggestions overlay actually appears (or errors).
    /// Success transitions us to `landed`; failure re-shows the card with a
    /// "try again" hint.
    func noteSummaryCompleted(success: Bool) {
        guard panel != nil else { return }
        if success {
            setState(.landed)
            if !didEmitFirstSummary {
                didEmitFirstSummary = true
                emit(
                    "onboarding_demo_first_summary_success",
                    details: [
                        "ms_since_shown": msSinceShown,
                        "trigger_bundle_id": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown",
                    ]
                )
            }
            showPanelAgain()
        } else {
            setState(.waiting)
            showPanelAgain()
        }
    }

    /// Called when the user picks a suggestion via 1/2/3 (or the equivalent).
    func noteSuggestionPicked(index: Int) {
        guard panel != nil else { return }
        if !didEmitFirstPaste {
            didEmitFirstPaste = true
            emit(
                "onboarding_demo_first_paste",
                details: [
                    "ms_since_shown": msSinceShown,
                    "choice_index": index + 1,
                ]
            )
        }
        // The landed celebration auto-dismisses ~6s after the first paste so
        // the user has a beat to read it before the card disappears.
        scheduleLandedDismiss()
    }

    // MARK: - Internal

    private func setState(_ newState: State) {
        state = newState
        // Publishing to the model updates the live SwiftUI view in place (no
        // rootView swap), so the entrance animation isn't replayed on every
        // state change — only the landed logo spring fires, on its own appear.
        cardModel.state = newState
    }

    private func handleSkip() {
        emit(
            "onboarding_demo_skipped",
            details: [
                "ms_since_shown": msSinceShown,
                "reached_state": stateString,
            ]
        )
        fireOutcome(.skipped)
    }

    private func fireOutcome(_ outcome: Outcome) {
        guard !didFireOutcome else { return }
        didFireOutcome = true
        close()
        onOutcome(outcome)
    }

    private func scheduleLandedDismiss() {
        landedDismissWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.fireOutcome(.firstHotkeyLanded)
        }
        landedDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0, execute: work)
    }

    private func showPanelAgain() {
        guard let panel, !panel.isVisible else { return }
        panel.orderFrontRegardless()
    }

    /// Top-right corner origin for the panel's current frame size.
    private func cornerOrigin() -> NSPoint? {
        guard let panel else { return nil }
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return nil }
        let frame = panel.frame
        return NSPoint(
            x: visible.maxX - frame.width - Self.cornerInset,
            y: visible.maxY - frame.height - Self.cornerInset
        )
    }

    /// Keep the card pinned to the top-right corner so it grows downward as the
    /// content height changes between states (no jump, no empty space).
    private func pinToCorner() {
        guard let panel, let origin = cornerOrigin() else { return }
        panel.setFrameOrigin(origin)
    }

    /// One-shot entrance: a gentle fade + rise, at the window level so it is not
    /// clipped by the content-sized panel. The target is the corner (not the
    /// current origin), so it lands correctly even if the size is still
    /// settling. Reduce-Motion shows it immediately.
    private func animateEntranceIfNeeded() {
        guard let panel, !didAnimateEntrance, let target = cornerOrigin() else { return }
        didAnimateEntrance = true
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrameOrigin(target)
            panel.alphaValue = 1
            return
        }
        entranceInFlight = true
        // A pronounced rise (vs the subtle steady-state nudge) so the eye
        // follows the card into the corner after the welcome window fades.
        panel.setFrameOrigin(NSPoint(x: target.x, y: target.y - 22))
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.42
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(target)
        }, completionHandler: { [weak self] in
            // Runs on the main thread; snap to the final corner in case the
            // content size settled mid-flight.
            MainActor.assumeIsolated {
                self?.entranceInFlight = false
                self?.pinToCorner()
            }
        })
    }

    private func installActivationObserver() {
        let center = NSWorkspace.shared.notificationCenter
        activationObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let bundleID = app.bundleIdentifier
            // queue: .main above already routes us to the main thread; the
            // explicit MainActor hop is to satisfy strict concurrency since the
            // notification handler signature is @Sendable.
            Task { @MainActor in
                guard let self else { return }
                // The first time the user alt-tabs away from Blink with the
                // card open, emit a single "armed" event. Cheap signal that
                // they saw the card and are now in position to try the hotkey.
                if bundleID != Bundle.main.bundleIdentifier,
                   self.state == .waiting,
                   !self.didEmitArmed {
                    self.didEmitArmed = true
                    self.emit(
                        "onboarding_demo_card_armed",
                        details: ["ms_since_shown": self.msSinceShown]
                    )
                }
            }
        }
    }

    private var msSinceShown: Int {
        Int(Date().timeIntervalSince(shownAt) * 1000)
    }

    private var stateString: String {
        switch state {
        case .waiting: return "waiting"
        case .firing: return "firing"
        case .landed: return "landed"
        }
    }

    private func emit(_ type: String, details: [String: Any]) {
        guard let eventClient else { return }
        eventClient.send(
            requestID: requestID,
            eventType: type,
            allowLogging: allowLogging(),
            clientMetadata: clientMetadata(),
            details: details,
            completion: nil
        )
    }

    // MARK: - NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        // The hosting controller auto-sizes the panel to the SwiftUI content.
        // The first resize (size settled) drives the entrance; later resizes
        // (state changes) re-pin to the corner. While the entrance is in
        // flight, leave the origin to the animator so it doesn't fight.
        if !didAnimateEntrance {
            animateEntranceIfNeeded()
        } else if !entranceInFlight {
            pinToCorner()
        }
    }

    func windowWillClose(_ notification: Notification) {
        // ⌘W (the panel is .closable) — treat as Skip with no extra ceremony.
        // If we're already firing an outcome (from a button path), fireOutcome's
        // idempotency guard makes this a no-op.
        if !didFireOutcome {
            handleSkip()
        }
    }
}

// MARK: - Card model

/// Drives the live SwiftUI card. The controller publishes state changes here so
/// the view updates in place rather than via a `rootView` swap.
private final class DemoCardModel: ObservableObject {
    @Published var state: OnboardingDemoCardWindowController.State
    init(state: OnboardingDemoCardWindowController.State) {
        self.state = state
    }
}

// MARK: - SwiftUI card

private struct DemoCardView: View {
    @ObservedObject var model: DemoCardModel
    let hotkeyDisplay: String
    let hotkeyParts: [String]
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let cardWidth: CGFloat = 320

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .center, spacing: 14) {
                if model.state == .landed {
                    BlinkLogo(reduceMotion: reduceMotion)
                }

                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)

                switch model.state {
                case .waiting, .firing:
                    Text("Switch to any window and press")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)

                    KeyRow(keys: hotkeyParts)
                        .padding(.vertical, 2)

                    Text("Blink reads it and drafts three replies in seconds.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)

                case .landed:
                    Text("Press \(hotkeyDisplay) anytime. Blink lives in your Dock.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 22)
            .frame(width: Self.cardWidth)
            .modifier(GlassCardSurface(cornerRadius: 22))

            MacCloseButton(action: onDismiss)
                .padding(14)
        }
    }

    private var title: String {
        model.state == .landed ? "Nice, that's Blink" : "Try Blink on your own window"
    }
}

// MARK: - Close button

/// The standard macOS traffic-light close button: red fill, ✕ on hover. Drawn
/// in SwiftUI (rather than using the native title-bar button) so it stays the
/// active red on a non-activating panel.
private struct MacCloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color(red: 1.0, green: 0.37, blue: 0.34))
                    .overlay(Circle().strokeBorder(.black.opacity(0.18), lineWidth: 0.5))
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.black.opacity(hovering ? 0.55 : 0.0))
            }
            .frame(width: 12, height: 12)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Close")
        .accessibilityLabel("Dismiss")
    }
}

// MARK: - Blink logo

/// Landed-state celebration: the Blink app icon springs in once. Solid image,
/// no glow.
private struct BlinkLogo: View {
    let reduceMotion: Bool
    @State private var shown = false

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 54, height: 54)
            .scaleEffect(shown ? 1 : 0.5)
            .opacity(shown ? 1 : 0)
            .onAppear {
                if reduceMotion {
                    shown = true
                } else {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) {
                        shown = true
                    }
                }
            }
    }
}

// MARK: - Keys

/// The hotkey rendered as separate caps, e.g. ⌃ ⌥ Space.
private struct KeyRow: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Keycap(label: key)
            }
        }
    }
}

/// One quiet, flat cap — no shadow, glow, or animation.
private struct Keycap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 16, weight: .medium, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, label.count > 1 ? 12 : 9)
            .padding(.vertical, 6)
            .frame(minWidth: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.primary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
            )
    }
}

// MARK: - Glass card surface

/// Liquid Glass on macOS 26+, `.regularMaterial` everywhere older. The panel is
/// transparent and provides the (rounded) drop shadow, so this draws no shadow
/// of its own.
private struct GlassCardSurface: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            content.background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.regularMaterial)
            )
        }
    }
}
