import AppKit
import ApplicationServices
import AVFoundation

/// Floating window that walks the tester through the three permissions Blink
/// needs. Each row links directly to the relevant Security & Privacy pane and
/// a draggable Blink.app icon at the bottom acts as a manual fallback for the
/// machines where TCC's API path silently fails (orphan rows, identity
/// mismatch, etc.).
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
        win.title = "Blink — Permissions"
        win.isReleasedWhenClosed = false
        win.delegate = self

        let heading = self.heading("Blink needs three permissions to run.")

        rows = []
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

        let dragSection = buildDragFallbackSection()

        let stack = NSStackView(views: [heading, grid, dragSection])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
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
        row.cell(at: 0).yPlacement = .top
        row.cell(at: 2).yPlacement = .top
    }

    /// Builds the manual-drag fallback footer. Visible always — phrased as a
    /// hint, not an error, so users who don't need it can ignore it. The
    /// draggable Blink icon is the only visual; the label says the rest. An
    /// earlier version paired Blink with a System Settings icon and an arrow,
    /// but the arrow → gear flow read as "drop on the gear", which is wrong:
    /// the destination is the Settings *window*, not the icon.
    private func buildDragFallbackSection() -> NSView {
        let dragView = BundleDragSourceView(bundleURL: Bundle.main.bundleURL)
        NSLayoutConstraint.activate([
            dragView.widthAnchor.constraint(equalToConstant: 48),
            dragView.heightAnchor.constraint(equalToConstant: 48),
        ])

        let label = NSTextField(labelWithString:
            "Drag this icon into System Settings if Blink doesn't appear after clicking Open Settings."
        )
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.preferredMaxLayoutWidth = 340
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [dragView, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 14
        return stack
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

// MARK: - Drag source

/// Pasteboard writer that advertises a file URL the way Finder does, so System
/// Settings' permission lists accept the dropped `.app` bundle. Writing only
/// `.fileURL` is sometimes insufficient on Tahoe; advertising the legacy and
/// promised types alongside it makes the receiver treat the drop as a
/// Finder-originated bundle.
private final class BundlePasteboardWriter: NSObject, NSPasteboardWriting {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [
            .fileURL,
            .URL,
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
            NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
            .string,
        ]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .fileURL,
             .URL,
             NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"):
            return url.absoluteString
        case NSPasteboard.PasteboardType("NSFilenamesPboardType"):
            return [url.path]
        case .string:
            return url.path
        default:
            return nil
        }
    }
}

/// `NSImageView`-shaped drag source for Blink.app. Pressing and dragging the
/// view starts a `.copy` drag session whose pasteboard reproduces what Finder
/// puts on a `.app` drag, so the user can drop into System Settings'
/// permission list panes (Screen Recording, Accessibility, Input Monitoring).
private final class BundleDragSourceView: NSView, NSDraggingSource {
    private let bundleURL: URL
    private let iconView = NSImageView()
    private var mouseDownPoint: NSPoint?

    init(bundleURL: URL) {
        self.bundleURL = bundleURL
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        iconView.image = NSWorkspace.shared.icon(forFile: bundleURL.path)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.toolTip = "Drag into System Settings"
        addSubview(iconView)
        // Inset the icon by `iconInset` on each edge so the dashed border
        // drawn in `draw(_:)` has room to render around it.
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: BundleDragSourceView.iconInset),
            iconView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -BundleDragSourceView.iconInset),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: BundleDragSourceView.iconInset),
            iconView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -BundleDragSourceView.iconInset),
        ])
    }

    /// Padding between the dashed outline and the icon. Tuned to match the
    /// outer 48×48 footprint with a ~38pt visible icon.
    private static let iconInset: CGFloat = 5

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            xRadius: 8,
            yRadius: 8
        )
        path.lineWidth = 1.25
        path.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.tertiaryLabelColor.setStroke()
        path.stroke()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Hover affordance — switching to an open-hand cursor on enter makes the
    /// icon feel draggable instead of clickable, which is the main signal we
    /// need now that the Settings-icon visual flow is gone.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.openHand.push()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.pop()
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        guard hypot(current.x - down.x, current.y - down.y) > 4 else { return }
        mouseDownPoint = nil
        beginAppDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    private func beginAppDrag(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: BundlePasteboardWriter(url: bundleURL))
        let icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
        icon.size = NSSize(width: 56, height: 56)
        let dragPoint = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(
            NSRect(x: dragPoint.x - 28, y: dragPoint.y - 28, width: 56, height: 56),
            contents: icon
        )
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }
}
