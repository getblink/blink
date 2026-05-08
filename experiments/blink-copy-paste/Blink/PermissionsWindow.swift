import AppKit
import ApplicationServices
import AVFoundation

/// Floating window that walks the tester through the three permissions Blink
/// needs. Each row links directly to the relevant Security & Privacy pane.
final class PermissionsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var refreshTimer: Timer?
    private var rows: [(name: String, check: () -> Bool, url: String, label: NSTextField)] = []

    func show() {
        if window == nil { buildWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startRefreshing()
    }

    private func buildWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Blink — Permissions"
        win.isReleasedWhenClosed = false
        win.delegate = self

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(self.heading("Blink needs three permissions to run."))

        rows = []
        stack.addArrangedSubview(self.permissionRow(
            title: "Accessibility",
            description: "Read the focused field and paste text.",
            check: { AXIsProcessTrusted() },
            url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ))
        stack.addArrangedSubview(self.permissionRow(
            title: "Input Monitoring",
            description: "Listen for the ⌃⇧C / ⌃⇧V hotkeys.",
            check: { PermissionsWindowController.inputMonitoringGranted() },
            url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        ))
        stack.addArrangedSubview(self.permissionRow(
            title: "Screen Recording",
            description: "Capture the window you target.",
            check: { CGPreflightScreenCaptureAccess() },
            url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ))

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        win.contentView = content
        window = win
    }

    private func heading(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.boldSystemFont(ofSize: 14)
        return label
    }

    private func permissionRow(
        title: String, description: String,
        check: @escaping () -> Bool, url: String
    ) -> NSView {
        let status = NSTextField(labelWithString: "…")
        status.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        rows.append((name: title, check: check, url: url, label: status))

        let name = NSTextField(labelWithString: title)
        name.font = NSFont.boldSystemFont(ofSize: 13)
        let desc = NSTextField(labelWithString: description)
        desc.font = NSFont.systemFont(ofSize: 11)
        desc.textColor = .secondaryLabelColor

        let open = NSButton(title: "Open Settings", target: self, action: #selector(openURLButton))
        open.bezelStyle = .rounded
        open.setButtonType(.momentaryPushIn)
        open.identifier = NSUserInterfaceItemIdentifier(url)

        let text = NSStackView(views: [name, desc])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let row = NSStackView(views: [status, text, NSView(), open])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    @objc private func openURLButton(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let url = URL(string: id) else { return }
        NSWorkspace.shared.open(url)
    }

    private func startRefreshing() {
        refreshTimer?.invalidate()
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        for row in rows {
            let ok = row.check()
            row.label.stringValue = ok ? "✅" : "○"
            row.label.textColor = ok ? .systemGreen : .tertiaryLabelColor
        }
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Probes

    /// Query Input Monitoring directly instead of creating probe event taps on
    /// every refresh. The permissions window polls once per second while open,
    /// so probing via `CGEvent.tapCreate` needlessly churns WindowServer/TCC.
    static func inputMonitoringGranted() -> Bool {
        HotkeyManager.inputMonitoringGranted()
    }
}
