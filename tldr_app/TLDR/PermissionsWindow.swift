import AppKit
import ApplicationServices
import AVFoundation

/// Floating window that walks the tester through the three permissions TLDR
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
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "TLDR — Permissions"
        win.isReleasedWhenClosed = false
        win.delegate = self

        let heading = self.heading("TLDR needs three permissions to run.")

        rows = []
        // Use an NSGridView so the status icon, name+description, and the
        // "Open Settings" button align cleanly across rows. NSStackView
        // can't pin a per-column width when the middle column varies, which
        // produced the staggered buttons in the previous layout.
        let grid = NSGridView(numberOfColumns: 3, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 14
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .center
        grid.column(at: 1).xPlacement = .leading
        grid.column(at: 2).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        addPermissionRow(
            grid: grid,
            title: "Accessibility",
            description: "Read the focused field and paste text.",
            check: { AXIsProcessTrusted() },
            url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
        addPermissionRow(
            grid: grid,
            title: "Input Monitoring",
            description: "Listen for the summary hotkey and numbered choices.",
            check: { PermissionsWindowController.inputMonitoringGranted() },
            url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        )
        addPermissionRow(
            grid: grid,
            title: "Screen Recording",
            description: "Capture the window you target.",
            check: { CGPreflightScreenCaptureAccess() },
            url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )

        let stack = NSStackView(views: [heading, grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

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
        // Auto-size the window to fit the content rather than hardcoding a
        // height that leaves a half-window of empty space below the rows.
        content.layoutSubtreeIfNeeded()
        let target = stack.fittingSize
        win.setContentSize(NSSize(width: max(target.width, 480), height: target.height))
        window = win
    }

    private func addPermissionRow(
        grid: NSGridView,
        title: String,
        description: String,
        check: @escaping () -> Bool,
        url: String
    ) {
        let status = NSTextField(labelWithString: "…")
        status.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        rows.append((name: title, check: check, url: url, label: status))

        let name = NSTextField(labelWithString: title)
        name.font = NSFont.boldSystemFont(ofSize: 13)
        let desc = NSTextField(labelWithString: description)
        desc.font = NSFont.systemFont(ofSize: 11)
        desc.textColor = .secondaryLabelColor

        let text = NSStackView(views: [name, desc])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let open = NSButton(title: "Open Settings", target: self, action: #selector(openURLButton))
        open.bezelStyle = .rounded
        open.setButtonType(.momentaryPushIn)
        open.identifier = NSUserInterfaceItemIdentifier(url)

        let row = grid.addRow(with: [status, text, open])
        // Pin the status cell vertically to the title row so the icon sits
        // beside the bold name rather than drifting toward the description.
        row.cell(at: 0).yPlacement = .top
        row.cell(at: 2).yPlacement = .top
    }

    private func heading(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.boldSystemFont(ofSize: 14)
        return label
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
