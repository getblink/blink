import AppKit

/// A small, non-activating bottom-right affordance shown when Blink has a
/// background (catch-up) summary ready for a window. It is just a *readiness
/// indicator* — click it and the coordinator shows the cached summary in the
/// normal overlay; the indicator itself carries no content.
///
/// Non-activating + floating so it never steals focus from the app the user is
/// in. Styling here is intentionally minimal (a rounded pill) — this is a
/// dogfood affordance, not the final visual.
///
/// Main-thread only (wraps AppKit). The coordinator owns it and only touches it
/// from the main queue.
final class BackgroundReadyIndicator {
    private var panel: NSPanel?
    private let onClick: () -> Void

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
    }

    /// Show the indicator in the bottom-right of the active screen. `label` is a
    /// short hint (e.g. the app name) — content stays in the overlay on click.
    func show(label: String) {
        hide()
        let size = NSSize(width: 200, height: 40)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        let button = NSButton(title: "✨ \(label) — ready", target: self, action: #selector(handleClick))
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.frame = NSRect(origin: .zero, size: size)
        button.toolTip = "Blink prepared a summary for this window — click to view"
        panel.contentView = button

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            let margin: CGFloat = 24
            panel.setFrameOrigin(NSPoint(x: f.maxX - size.width - margin, y: f.minY + margin))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    @objc private func handleClick() {
        onClick()
    }
}
