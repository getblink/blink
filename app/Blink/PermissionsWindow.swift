import AppKit
import ApplicationServices
import AVFoundation

/// First-run wizard for Blink's permission setup. A single checklist screen
/// lets the user grant the three required permissions in any order; rows
/// flip to "Granted" as the user toggles them in System Settings. The
/// wizard intentionally avoids prompt-style TCC calls and only relies on
/// preflight probes (`AXIsProcessTrusted`, `IOHIDCheckAccess`,
/// `CGPreflightScreenCaptureAccess`).
final class PermissionsWindowController: NSObject, NSWindowDelegate {
    private enum Permission: String, CaseIterable {
        case accessibility
        case inputMonitoring
        case screenRecording
    }

    private struct PermissionCopy {
        let permission: Permission
        let headline: String
        let explainer: String
        let settingsURL: String
        let check: () -> Bool
    }

    private struct PermissionRowViews {
        let statusPill: NSTextField
        let openSettingsButton: NSButton
    }

    private let hotkeyDisplay: String
    private let eventClient: BlinkEventClient?
    private let allowLogging: () -> Bool
    private let clientMetadata: () -> [String: Any]
    private let onFinished: () -> Void
    private let setOnboardingSampleActive: (Bool) -> Void
    private let attemptHotkeyStart: () -> Bool
    private let sampleHotkey: Hotkey

    private var window: NSWindow?
    private var contentHost = NSView()
    private var refreshTimer: Timer?
    private var permissionRows: [Permission: PermissionRowViews] = [:]
    private var hotkeyHeaderField: NSTextField?
    private var lastGrantedSnapshot: [Permission: Bool] = [:]
    private var grantMS: [Permission: Int] = [:]
    private var didMarkOnboarded: Bool = false
    private var didFireCompleted: Bool = false
    private var chatMockController: OnboardingChatMockWindowController?
    private var wizardWindowClosed: Bool = false
    private var autoDismissWorkItem: DispatchWorkItem?
    private var hotkeyStartRetryWorkItem: DispatchWorkItem?
    private var shownAt: Date?
    private var inRelaunchFallback: Bool = false

    init(
        hotkeyDisplay: String,
        sampleHotkey: Hotkey,
        eventClient: BlinkEventClient? = nil,
        allowLogging: @escaping () -> Bool = { false },
        clientMetadata: @escaping () -> [String: Any] = { [:] },
        setOnboardingSampleActive: @escaping (Bool) -> Void = { _ in },
        attemptHotkeyStart: @escaping () -> Bool = { false },
        onFinished: @escaping () -> Void = {}
    ) {
        self.hotkeyDisplay = hotkeyDisplay
        self.sampleHotkey = sampleHotkey
        self.eventClient = eventClient
        self.allowLogging = allowLogging
        self.clientMetadata = clientMetadata
        self.setOnboardingSampleActive = setOnboardingSampleActive
        self.attemptHotkeyStart = attemptHotkeyStart
        self.onFinished = onFinished
        super.init()
    }

    func show() {
        if window == nil { buildWindow() }
        wizardWindowClosed = false
        inRelaunchFallback = false
        autoDismissWorkItem?.cancel()
        autoDismissWorkItem = nil
        hotkeyStartRetryWorkItem?.cancel()
        hotkeyStartRetryWorkItem = nil
        didFireCompleted = false
        grantMS.removeAll()
        lastGrantedSnapshot = currentSnapshot()
        // Seed grant timestamps for permissions already granted at show time
        // so `grants_ms` is complete in `onboarding_completed`.
        for (perm, granted) in lastGrantedSnapshot where granted {
            grantMS[perm] = 0
        }
        shownAt = Date()
        emit(type: "onboarding_shown", details: [
            "initial_granted": lastGrantedSnapshot
                .filter { $0.value }
                .map { $0.key.rawValue }
        ])
        renderChecklist()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startRefreshing()
        // If everything was already granted at show time, skip the whole
        // dance immediately — same path the auto-dismiss takes after a
        // grant flips.
        if lastGrantedSnapshot.values.allSatisfy({ $0 }) {
            scheduleAutoDismiss()
        }
    }

    private var permissions: [PermissionCopy] {
        [
            PermissionCopy(
                permission: .accessibility,
                headline: "Accessibility",
                explainer: "Blink reads the focused field and pastes your selected reply.",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                check: { AXIsProcessTrusted() }
            ),
            PermissionCopy(
                permission: .inputMonitoring,
                headline: "Input Monitoring",
                explainer: "Blink listens for \(hotkeyDisplay) and the overlay number keys.",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
                check: { PermissionsWindowController.inputMonitoringGranted() }
            ),
            PermissionCopy(
                permission: .screenRecording,
                headline: "Screen Recording",
                explainer: "Blink needs to see the active window before it can summarize it.",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                check: { Self.screenRecordingGranted(caller: "PermissionsWindow.screenRecordingCheck") }
            ),
        ]
    }

    private func currentSnapshot() -> [Permission: Bool] {
        var snap: [Permission: Bool] = [:]
        for copy in permissions {
            snap[copy.permission] = copy.check()
        }
        return snap
    }

    private func buildWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Blink Setup"
        win.isReleasedWhenClosed = false
        win.delegate = self

        contentHost.translatesAutoresizingMaskIntoConstraints = false
        win.contentView = contentHost
        NSLayoutConstraint.activate([
            contentHost.widthAnchor.constraint(greaterThanOrEqualToConstant: 720),
            contentHost.heightAnchor.constraint(greaterThanOrEqualToConstant: 620),
        ])
        win.center()
        window = win
    }

    private func renderChecklist() {
        permissionRows.removeAll()
        contentHost.subviews.forEach { $0.removeFromSuperview() }

        let tagline = heading("Blink turns the window you are reading into a short tl;dr and three replies.")
        tagline.maximumNumberOfLines = 3
        tagline.preferredMaxLayoutWidth = 480

        let hotkeyRow = hotkeyHeaderView()
        hotkeyHeaderField = hotkeyRow.field

        let rowsStack = NSStackView(views: permissions.map { permissionRow(for: $0) })
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 12

        let dragFallback = dragFallbackSection()

        let seeSample = NSButton(title: "See a sample", target: self, action: #selector(showSample))
        seeSample.bezelStyle = .rounded
        seeSample.controlSize = .large
        seeSample.keyEquivalent = "\r"

        let buttons = NSStackView(views: [seeSample])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10

        let view = baseStack(views: [
            tagline,
            hotkeyRow.container,
            rowsStack,
            dragFallback,
            buttons,
        ])
        view.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            view.topAnchor.constraint(equalTo: contentHost.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ])
        let target = view.fittingSize
        window?.setContentSize(NSSize(
            width: max(target.width, 720),
            height: max(target.height, 620)
        ))
    }

    private func hotkeyHeaderView() -> (container: NSView, field: NSTextField) {
        let label = NSTextField(labelWithString: "Hotkey")
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor

        let inputMonitoringOn = Self.inputMonitoringGranted()
        let value = NSTextField(labelWithString: "")
        applyHotkeyHeaderState(field: value, granted: inputMonitoringOn)

        let stack = NSStackView(views: [label, value])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 12
        return (stack, value)
    }

    private func applyHotkeyHeaderState(field: NSTextField, granted: Bool) {
        if granted {
            field.stringValue = hotkeyDisplay
            field.font = NSFont.monospacedSystemFont(ofSize: 15, weight: .semibold)
            field.textColor = .labelColor
        } else {
            field.stringValue = "unlocks once Input Monitoring is granted"
            field.font = NSFont.systemFont(ofSize: 12)
            field.textColor = .tertiaryLabelColor
        }
    }

    private func permissionRow(for copy: PermissionCopy) -> NSView {
        let granted = copy.check()

        let title = NSTextField(labelWithString: copy.headline)
        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor

        let explainer = NSTextField(wrappingLabelWithString: copy.explainer)
        explainer.font = NSFont.systemFont(ofSize: 12)
        explainer.textColor = .secondaryLabelColor
        explainer.maximumNumberOfLines = 2
        // Force wrap below actual column width so the longer copy lines
        // ("…before it can summarize it.", "…paste your selected reply.")
        // break to a second line instead of getting clipped at the right
        // edge of the text column.
        explainer.preferredMaxLayoutWidth = 360
        explainer.lineBreakMode = .byWordWrapping
        explainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        explainer.setContentCompressionResistancePriority(.required, for: .vertical)

        let textStack = NSStackView(views: [title, explainer])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let pill = statusLabel(granted: granted)
        pill.setContentHuggingPriority(.required, for: .horizontal)

        let openSettings = NSButton(title: "Open Settings", target: self, action: #selector(openSettings))
        openSettings.identifier = NSUserInterfaceItemIdentifier(copy.settingsURL)
        // The button's tag carries the row's permission so the action handler
        // can record when this specific row was opened (for stuck-row drag
        // disclosure logic).
        openSettings.tag = Self.tag(for: copy.permission)
        openSettings.bezelStyle = .rounded
        openSettings.controlSize = .regular
        openSettings.isEnabled = true

        let row = NSStackView(views: [textStack, pill, openSettings])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        row.distribution = .fill
        row.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setHuggingPriority(.defaultLow, for: .horizontal)
        row.wantsLayer = true
        row.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.4).cgColor
        row.layer?.cornerRadius = 8
        row.layer?.borderWidth = 0.5
        row.layer?.borderColor = NSColor.separatorColor.cgColor

        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(greaterThanOrEqualToConstant: 656),
        ])

        permissionRows[copy.permission] = PermissionRowViews(
            statusPill: pill,
            openSettingsButton: openSettings
        )
        return row
    }

    private func baseStack(views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 22
        stack.edgeInsets = NSEdgeInsets(top: 32, left: 32, bottom: 32, right: 32)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 480
        return label
    }

    private func body(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 480
        return label
    }

    private func statusLabel(granted: Bool) -> NSTextField {
        let label = NSTextField(labelWithString: granted ? "Granted" : "Not granted")
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = granted ? .systemGreen : .tertiaryLabelColor
        label.alignment = .right
        return label
    }

    private static func tag(for permission: Permission) -> Int {
        switch permission {
        case .accessibility: return 1001
        case .inputMonitoring: return 1002
        case .screenRecording: return 1003
        }
    }

    private static func permission(forTag tag: Int) -> Permission? {
        switch tag {
        case 1001: return .accessibility
        case 1002: return .inputMonitoring
        case 1003: return .screenRecording
        default: return nil
        }
    }

    private func dragFallbackSection() -> NSView {
        let dragView = BundleDragSourceView(bundleURL: Bundle.main.bundleURL)
        NSLayoutConstraint.activate([
            dragView.widthAnchor.constraint(equalToConstant: 96),
            dragView.heightAnchor.constraint(equalToConstant: 96),
        ])

        let title = NSTextField(labelWithString: "If Blink isn't in the list")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor

        let label = NSTextField(wrappingLabelWithString:
            "Drag the Blink icon into the System Settings list to add it."
        )
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 3
        label.preferredMaxLayoutWidth = 360
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [title, label])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4

        let stack = NSStackView(views: [dragView, textStack])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 16
        return stack
    }

    @objc private func showSample() {
        guard chatMockController == nil else {
            chatMockController?.show()
            return
        }
        emit(type: "onboarding_sample_invoked", details: [:])
        let fixture = OnboardingFixture.load()
        setOnboardingSampleActive(true)
        let controller = OnboardingChatMockWindowController(
            fixture: fixture,
            hotkey: sampleHotkey,
            hotkeyDisplay: sampleHotkey.displayString
        ) { [weak self] in
            guard let self else { return }
            self.setOnboardingSampleActive(false)
            self.chatMockController = nil
            // Only re-show the wizard if it wasn't closed by the user while
            // the mock was up — otherwise we'd resurrect a window they
            // dismissed.
            if !self.wizardWindowClosed {
                self.window?.makeKeyAndOrderFront(nil)
                self.onDemoClosed()
            }
        }
        chatMockController = controller
        // Hide the wizard while the sample is up so it doesn't sit in front
        // of the demo window. We deliberately don't fire auto-dismiss or
        // relaunch-fallback while the demo is open — that would yank the
        // demo window out from under the user. `refresh()` and
        // `finishChecklist()` both gate on `chatMockController == nil`.
        window?.orderOut(nil)
        controller.show()
    }

    private func onDemoClosed() {
        // The demo's onClose has already cleared `chatMockController`. If the
        // user granted the last permission while the demo was up, this is
        // where we finally trigger the auto-dismiss path we suppressed
        // earlier.
        if !inRelaunchFallback,
           !didFireCompleted,
           lastGrantedSnapshot.values.count == Permission.allCases.count,
           lastGrantedSnapshot.values.allSatisfy({ $0 }) {
            scheduleAutoDismiss()
        }
    }

    @objc private func openSettings(_ sender: NSButton) {
        if let perm = Self.permission(forTag: sender.tag) {
            emit(type: "onboarding_open_settings_clicked", details: [
                "permission": perm.rawValue
            ])
        }
        guard let id = sender.identifier?.rawValue, let url = URL(string: id) else { return }
        NSWorkspace.shared.open(url)
    }

    private func markOnboardedOnce() {
        guard !didMarkOnboarded else { return }
        didMarkOnboarded = true
        Paths.markOnboarded()
    }

    private func startRefreshing() {
        refreshTimer?.invalidate()
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        let snapshot = currentSnapshot()
        let shownAt = self.shownAt ?? Date()

        var anyChange = false
        var inputMonitoringFlipped = false
        for perm in Permission.allCases {
            let was = lastGrantedSnapshot[perm] ?? false
            let isGranted = snapshot[perm] ?? false
            if was == isGranted { continue }
            anyChange = true
            if let row = permissionRows[perm] {
                let pill = statusLabel(granted: isGranted)
                row.statusPill.stringValue = pill.stringValue
                row.statusPill.textColor = pill.textColor
            }
            if isGranted {
                let elapsed = Int(Date().timeIntervalSince(shownAt) * 1000)
                grantMS[perm] = elapsed
                emit(type: "permission_granted", details: [
                    "permission": perm.rawValue,
                    "ms_since_shown": elapsed,
                ])
                if perm == .inputMonitoring { inputMonitoringFlipped = true }
            }
        }
        lastGrantedSnapshot = snapshot

        if inputMonitoringFlipped, let field = hotkeyHeaderField {
            applyHotkeyHeaderState(field: field, granted: true)
        }

        if anyChange, snapshot.values.allSatisfy({ $0 }) {
            scheduleAutoDismiss()
        }
    }

    private func scheduleAutoDismiss() {
        guard autoDismissWorkItem == nil, !inRelaunchFallback else { return }
        // Don't yank the demo out from under the user. `onDemoClosed()` will
        // re-trigger this once the demo closes.
        if chatMockController != nil { return }
        markOnboardedOnce()
        let work = DispatchWorkItem { [weak self] in
            self?.finishChecklist()
        }
        autoDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func finishChecklist() {
        guard !didFireCompleted else { return }
        // Clear the dismiss handle so `onDemoClosed()` can re-schedule us if
        // the demo opened mid-flight; cancel any stale retry from a prior
        // finishChecklist that got pre-empted by the demo.
        autoDismissWorkItem = nil
        hotkeyStartRetryWorkItem?.cancel()
        hotkeyStartRetryWorkItem = nil
        // Demo opened between schedule and fire — wait for `onDemoClosed()`.
        if chatMockController != nil {
            return
        }
        if attemptHotkeyStart() {
            didFireCompleted = true
            emitCompleted(relaunchRequired: false)
            refreshTimer?.invalidate()
            refreshTimer = nil
            window?.close()
            onFinished()
            return
        }
        // First in-process start attempt failed. Retry once after a brief
        // grace, then fall back to a relaunch card.
        TCCDiagnostics.log("hotkeys_start_after_onboarding first_attempt_failed=true")
        let retry = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Demo opened during the retry window — defer until it closes.
            if self.chatMockController != nil { return }
            if self.attemptHotkeyStart() {
                self.didFireCompleted = true
                self.emitCompleted(relaunchRequired: false)
                TCCDiagnostics.log("hotkeys_start_after_onboarding retry_succeeded=true")
                self.refreshTimer?.invalidate()
                self.refreshTimer = nil
                self.window?.close()
                self.onFinished()
            } else {
                TCCDiagnostics.log("hotkeys_start_after_onboarding retry_failed=true")
                self.enterRelaunchFallback()
            }
        }
        hotkeyStartRetryWorkItem = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: retry)
    }

    private func enterRelaunchFallback() {
        guard !inRelaunchFallback else { return }
        inRelaunchFallback = true
        autoDismissWorkItem?.cancel()
        autoDismissWorkItem = nil
        refreshTimer?.invalidate()
        refreshTimer = nil

        contentHost.subviews.forEach { $0.removeFromSuperview() }
        let title = heading("Relaunch Blink")
        let detail = body("Blink needs a quick relaunch to start listening for your hotkey.")
        let relaunch = NSButton(
            title: "Relaunch Blink",
            target: self,
            action: #selector(relaunchTapped)
        )
        relaunch.bezelStyle = .rounded
        relaunch.controlSize = .large
        relaunch.keyEquivalent = "\r"

        let view = baseStack(views: [title, detail, relaunch])
        view.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            view.topAnchor.constraint(equalTo: contentHost.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ])
    }

    @objc private func relaunchTapped() {
        didFireCompleted = true
        emitCompleted(relaunchRequired: true)
        markOnboardedOnce()
        relaunchSelf()
    }

    private func emitCompleted(relaunchRequired: Bool) {
        let shownAt = self.shownAt ?? Date()
        let duration = Int(Date().timeIntervalSince(shownAt) * 1000)
        let grants: [String: Int] = Dictionary(uniqueKeysWithValues: grantMS.map { ($0.key.rawValue, $0.value) })
        emit(type: "onboarding_completed", details: [
            "relaunch_required": relaunchRequired,
            "duration_ms": duration,
            "grants_ms": grants,
        ])
    }

    private func relaunchSelf() {
        let bundleURL = Bundle.main.bundleURL
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [bundleURL.path]
            do {
                try process.run()
            } catch {
                NSLog("Blink: relaunch failed: %@", error.localizedDescription)
            }
            NSApp.terminate(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        wizardWindowClosed = true
        refreshTimer?.invalidate()
        refreshTimer = nil
        autoDismissWorkItem?.cancel()
        autoDismissWorkItem = nil
        hotkeyStartRetryWorkItem?.cancel()
        hotkeyStartRetryWorkItem = nil
        chatMockController?.close()
        if !didMarkOnboarded {
            // Closing the wizard before all grants leaves the onboarded
            // marker absent so the next launch retries onboarding. Telemetry
            // captures which rows the user did complete before bailing.
            let granted = lastGrantedSnapshot
                .filter { $0.value }
                .map { $0.key.rawValue }
            emit(type: "onboarding_abandoned", details: ["granted": granted])
        }
    }

    private func emit(type: String, details: [String: Any]) {
        eventClient?.send(
            requestID: "onboarding-\(Paths.loadOrCreateInstallID())",
            eventType: type,
            allowLogging: allowLogging(),
            clientMetadata: clientMetadata(),
            details: details
        )
    }

    // MARK: - Probes

    static func inputMonitoringGranted() -> Bool {
        HotkeyManager.inputMonitoringGranted()
    }

    private static func screenRecordingGranted(caller: String) -> Bool {
        let granted = CGPreflightScreenCaptureAccess()
        TCCDiagnostics.log("screen_recording_preflight caller=\(caller) granted=\(granted)")
        return granted
    }
}

// MARK: - Drag source

/// Pasteboard writer that advertises a file URL the way Finder does, so System
/// Settings' permission lists accept the dropped `.app` bundle.
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

/// `NSImageView`-shaped drag source for Blink.app.
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
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: BundleDragSourceView.iconInset),
            iconView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -BundleDragSourceView.iconInset),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: BundleDragSourceView.iconInset),
            iconView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -BundleDragSourceView.iconInset),
        ])
    }

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
