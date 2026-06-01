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

    private var panel: NSPanel?
    private var hostingController: NSHostingController<DemoCardView>?
    private var landedDismissWorkItem: DispatchWorkItem?
    private var activationObserver: NSObjectProtocol?

    init(
        hotkeyDisplay: String,
        eventClient: BlinkEventClient?,
        allowLogging: @escaping () -> Bool,
        clientMetadata: @escaping () -> [String: Any],
        onOutcome: @escaping (Outcome) -> Void
    ) {
        self.hotkeyDisplay = hotkeyDisplay
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

    /// Fixed card size. Shared by the panel (`setContentSize`) and the SwiftUI
    /// view's frame — the view MUST be bounded, otherwise its `maxHeight:
    /// .infinity` makes `NSHostingController` size the panel to the content's
    /// (unbounded) preferred height, blowing the window up to screen height.
    fileprivate static let cardSize = CGSize(width: 360, height: 280)

    // MARK: - Public lifecycle

    func show() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        shownAt = Date()
        let view = DemoCardView(
            hotkeyDisplay: hotkeyDisplay,
            state: state,
            onSkip: { [weak self] in self?.handleSkip() }
        )
        let host = NSHostingController(rootView: view)
        hostingController = host

        let panel = NSPanel(
            contentViewController: host
        )
        panel.styleMask = [.titled, .closable, .fullSizeContentView, .nonactivatingPanel, .hudWindow]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let contentSize = Self.cardSize
        panel.setContentSize(contentSize)

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let origin = NSPoint(
                x: visible.maxX - contentSize.width - 24,
                y: visible.maxY - contentSize.height - 24
            )
            panel.setFrameOrigin(origin)
        } else {
            panel.center()
        }

        panel.orderFrontRegardless()
        self.panel = panel

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
        state = .firing
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
            state = .landed
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
            renderState()
            showPanelAgain()
        } else {
            state = .waiting
            renderState()
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

    private func renderState() {
        guard let host = hostingController else { return }
        host.rootView = DemoCardView(
            hotkeyDisplay: hotkeyDisplay,
            state: state,
            onSkip: { [weak self] in self?.handleSkip() }
        )
    }

    private func showPanelAgain() {
        guard let panel, !panel.isVisible else { return }
        panel.orderFrontRegardless()
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

    func windowWillClose(_ notification: Notification) {
        // The X button on the panel was clicked — treat as Skip with no extra
        // ceremony. If we're already firing an outcome (from a button path),
        // fireOutcome's idempotency guard makes this a no-op.
        if !didFireOutcome {
            handleSkip()
        }
    }
}

// MARK: - SwiftUI card

private struct DemoCardView: View {
    let hotkeyDisplay: String
    let state: OnboardingDemoCardWindowController.State
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            switch state {
            case .waiting, .firing:
                waitingBody
            case .landed:
                landedBody
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 16)
        // Bounded to the card size so the hosting controller can't size the
        // panel to an unbounded preferred height. The Spacer above still
        // pins the footer to the bottom within this fixed height.
        .frame(
            width: OnboardingDemoCardWindowController.cardSize.width,
            height: OnboardingDemoCardWindowController.cardSize.height,
            alignment: .topLeading
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: state == .landed ? "checkmark.seal.fill" : "sparkles")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.accentColor)
            Text(state == .landed ? "You're in." : "Try Blink on your own window")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)
            Spacer(minLength: 0)
        }
    }

    private var waitingBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Switch to any window — an email, a Slack thread, a doc — and press")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                KeycapView(label: hotkeyDisplay, size: .large)
                Spacer()
            }
            .padding(.vertical, 2)
            Text("Blink will summarize it and draft 3 replies. Press **1**, **2**, or **3** to paste.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var landedBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Press **1**, **2**, or **3** to paste a reply.\nPress **R** to reroll.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Button("Skip", action: onSkip)
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)
            Spacer()
        }
        .font(.system(size: 12))
    }
}

// MARK: - Keycap

/// Keycap for hotkey display. `large` is the focal-point variant used by the
/// demo card; `small` is the compact inline variant.
private struct KeycapView: View {
    enum Size { case small, large }
    let label: String
    let size: Size

    var body: some View {
        let fontSize: CGFloat = size == .large ? 18 : 12
        let hPad: CGFloat = size == .large ? 14 : 6
        let vPad: CGFloat = size == .large ? 8 : 2
        let corner: CGFloat = size == .large ? 8 : 4

        Text(label)
            .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
            .foregroundColor(.primary)
            .padding(.horizontal, hPad)
            .padding(.vertical, vPad)
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(size == .large ? 0.12 : 0), radius: 2, x: 0, y: 1)
    }
}
