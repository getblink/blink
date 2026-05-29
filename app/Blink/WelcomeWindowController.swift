import AppKit
import SwiftUI

/// First-run welcome slideshow window. Hosts `WelcomePreview` — the animated
/// 4-slide intro (cursor → hotkey → overlay → pick) — centered on screen, and
/// reports completion so the app can advance to the permissions wizard.
///
/// Completion and an early manual close both funnel through the window's
/// `windowWillClose`, so there's a single, idempotent hand-off path: the user
/// is never stranded on this screen, and `onComplete` fires exactly once.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private let onComplete: () -> Void
    private var window: NSWindow?
    private var didComplete = false

    init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
        super.init()
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Finishing the last slide just closes the window; the close handler
        // below is the one place that advances onboarding.
        let root = WelcomePreview(onComplete: { [weak self] in self?.window?.close() })
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

    func windowWillClose(_ notification: Notification) {
        // Reached by finishing the slideshow OR by an early manual close —
        // either way, advance onboarding exactly once.
        guard !didComplete else { return }
        didComplete = true
        window = nil
        onComplete()
    }
}
