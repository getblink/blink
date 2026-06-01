import AppKit
import SwiftUI

/// First-run welcome window. Hosts `WelcomePreview` — the "Welcome to Blink"
/// landing, the animated 4-slide tour, and the live in-window permissions step
/// — centered on screen as one continuous, single-window experience.
///
/// The window stays open across landing → tour → permissions; it closes and
/// hands off to the demo card (`onComplete`) only after permissions are granted
/// and the hotkey listener starts. An early manual close just tears down — the
/// onboarded marker isn't written, so the next launch re-runs onboarding.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private let eventClient: BlinkEventClient?
    private let allowLogging: () -> Bool
    private let clientMetadata: () -> [String: Any]
    private let attemptHotkeyStart: () -> Bool
    /// Fired exactly once, only on a successful grant + hotkey start.
    private let onComplete: () -> Void

    private var window: NSWindow?
    private var model: PermissionsModel?
    private var didComplete = false

    init(
        eventClient: BlinkEventClient?,
        allowLogging: @escaping () -> Bool,
        clientMetadata: @escaping () -> [String: Any],
        attemptHotkeyStart: @escaping () -> Bool,
        onComplete: @escaping () -> Void
    ) {
        self.eventClient = eventClient
        self.allowLogging = allowLogging
        self.clientMetadata = clientMetadata
        self.attemptHotkeyStart = attemptHotkeyStart
        self.onComplete = onComplete
        super.init()
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let model = PermissionsModel(
            eventClient: eventClient,
            allowLogging: allowLogging,
            clientMetadata: clientMetadata,
            attemptHotkeyStart: attemptHotkeyStart,
            onComplete: { [weak self] in self?.completeAndClose() }
        )
        self.model = model

        let root = WelcomePreview(model: model)
            .frame(minWidth: 620, minHeight: 540)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 620, height: 540))
        window.center()
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The permissions step succeeded: close the window and hand off to the
    /// demo card. Idempotent.
    private func completeAndClose() {
        guard !didComplete else { return }
        didComplete = true
        window?.close()
        onComplete()
    }

    func windowWillClose(_ notification: Notification) {
        // Reached by a successful finish (via completeAndClose) OR an early
        // manual close. Either way, let the model tear down its timer/helper
        // and record an abandon if the user never finished. Only the success
        // path advances onboarding — an early close leaves the user on the
        // menubar with the marker unset, so onboarding re-runs next launch.
        model?.handleWindowClosed()
        model = nil
        window = nil
    }
}
