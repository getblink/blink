import AppKit
import ApplicationServices
import AVFoundation
import PermissionFlow

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
        let check: () -> Bool
    }

    private struct PermissionRowViews {
        let statusPill: NSTextField
        let openSettingsButton: NSButton
    }

    private let eventClient: BlinkEventClient?
    private let allowLogging: () -> Bool
    private let clientMetadata: () -> [String: Any]
    private let onFinished: () -> Void
    private let attemptHotkeyStart: () -> Bool

    private var window: NSWindow?
    private var contentHost = NSView()
    private var refreshTimer: Timer?
    private var permissionRows: [Permission: PermissionRowViews] = [:]
    private var primaryButton: NSButton?
    private var lastGrantedSnapshot: [Permission: Bool] = [:]
    private var grantMS: [Permission: Int] = [:]
    private var didMarkOnboarded: Bool = false
    private var didFireCompleted: Bool = false
    private var wizardWindowClosed: Bool = false
    private var hotkeyStartRetryWorkItem: DispatchWorkItem?
    private var autoChainWorkItem: DispatchWorkItem?
    private var shownAt: Date?
    private var inRelaunchFallback: Bool = false

    /// Owns System Settings navigation and the floating drag-to-authorize
    /// panel that appears next to the privacy pane. The controller's factory
    /// and methods are `@MainActor`-isolated; every access here is on main
    /// (button actions, window delegate, refresh timer fired on the main
    /// run loop), so the `assumeIsolated` wrapper is safe.
    private lazy var permissionFlowController: PermissionFlowController = {
        MainActor.assumeIsolated {
            PermissionFlow.makeController(
                configuration: .init(
                    requiredAppURLs: [Bundle.main.bundleURL],
                    promptForAccessibilityTrust: false
                )
            )
        }
    }()

    init(
        eventClient: BlinkEventClient? = nil,
        allowLogging: @escaping () -> Bool = { false },
        clientMetadata: @escaping () -> [String: Any] = { [:] },
        attemptHotkeyStart: @escaping () -> Bool = { false },
        onFinished: @escaping () -> Void = {}
    ) {
        self.eventClient = eventClient
        self.allowLogging = allowLogging
        self.clientMetadata = clientMetadata
        self.attemptHotkeyStart = attemptHotkeyStart
        self.onFinished = onFinished
        super.init()
    }

    func show() {
        if window == nil { buildWindow() }
        wizardWindowClosed = false
        inRelaunchFallback = false
        hotkeyStartRetryWorkItem?.cancel()
        hotkeyStartRetryWorkItem = nil
        autoChainWorkItem?.cancel()
        autoChainWorkItem = nil
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
    }

    private var permissions: [PermissionCopy] {
        [
            PermissionCopy(
                permission: .accessibility,
                headline: "Accessibility",
                explainer: "Blink reads the focused field and pastes your selected reply.",
                check: { AXIsProcessTrusted() }
            ),
            PermissionCopy(
                permission: .inputMonitoring,
                headline: "Input Monitoring",
                explainer: "Blink listens for the summary hotkey and the overlay number keys.",
                check: { PermissionsWindowController.inputMonitoringGranted() }
            ),
            PermissionCopy(
                permission: .screenRecording,
                headline: "Screen Recording",
                explainer: "Blink needs to see the active window before it can summarize it.",
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
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Blink Setup"
        win.isReleasedWhenClosed = false
        win.delegate = self

        contentHost.translatesAutoresizingMaskIntoConstraints = false
        win.contentView = contentHost
        win.center()
        window = win
    }

    private func renderChecklist() {
        permissionRows.removeAll()
        contentHost.subviews.forEach { $0.removeFromSuperview() }

        let tagline = heading("Blink turns the window you are reading into a short tl;dr and three replies.")
        tagline.maximumNumberOfLines = 3
        tagline.preferredMaxLayoutWidth = 480

        let rowsStack = NSStackView(views: permissions.map { permissionRow(for: $0) })
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 10

        let getStarted = NSButton(title: "Get Started", target: self, action: #selector(getStartedTapped))
        getStarted.bezelStyle = .rounded
        getStarted.controlSize = .large
        getStarted.keyEquivalent = "\r"
        getStarted.isEnabled = lastGrantedSnapshot.values.allSatisfy({ $0 })
            && lastGrantedSnapshot.count == Permission.allCases.count
        primaryButton = getStarted

        // Right-align the primary button at the bottom of the stack.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, getStarted])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.distribution = .fill
        buttons.spacing = 10

        let view = baseStack(views: [
            tagline,
            rowsStack,
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
        window?.setContentSize(target)
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
        // `preferredMaxLayoutWidth` alone isn't enough — the parent stack has
        // low hugging priority and stretches the label wider, at which point
        // AppKit happily renders a single line right up to the frame edge and
        // clips. A hard max-width constraint forces the longer strings
        // ("…paste your selected reply.") onto a second line every time.
        explainer.preferredMaxLayoutWidth = 320
        explainer.lineBreakMode = .byWordWrapping
        explainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        explainer.setContentCompressionResistancePriority(.required, for: .vertical)
        explainer.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true

        let textStack = NSStackView(views: [title, explainer])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let pill = statusLabel(granted: granted)
        pill.setContentHuggingPriority(.required, for: .horizontal)

        let openSettings = NSButton(title: "Open Settings", target: self, action: #selector(openSettings))
        // The button's tag carries the row's permission so the action handler
        // can route to the correct PermissionFlow pane.
        openSettings.tag = Self.tag(for: copy.permission)
        openSettings.bezelStyle = .rounded
        openSettings.controlSize = .regular
        openSettings.isEnabled = true

        let row = NSStackView(views: [textStack, pill, openSettings])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        row.distribution = .fill
        // Top/bottom are bumped past the "frame" target to compensate for the
        // NSTextField leading/descender space — 28pt of frame inset ≈ 22pt of
        // visible whitespace between the rounded border and the glyphs.
        row.edgeInsets = NSEdgeInsets(top: 28, left: 20, bottom: 28, right: 20)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setHuggingPriority(.defaultLow, for: .horizontal)
        row.wantsLayer = true
        row.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.4).cgColor
        row.layer?.cornerRadius = 8
        row.layer?.borderWidth = 0.5
        row.layer?.borderColor = NSColor.separatorColor.cgColor

        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(greaterThanOrEqualToConstant: 480),
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
        // Top inset is small because the titlebar already provides visual
        // separation from the chrome above; horizontal stays generous for
        // breathing room on either side of the cards.
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 40, bottom: 28, right: 40)
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

    @objc private func getStartedTapped() {
        emit(type: "onboarding_get_started_clicked", details: [:])
        finishChecklist()
    }

    @objc private func openSettings(_ sender: NSButton) {
        guard let perm = Self.permission(forTag: sender.tag) else { return }
        emit(type: "onboarding_open_settings_clicked", details: [
            "permission": perm.rawValue
        ])
        // Anchor the floating-helper launch animation to the button itself
        // so it appears to fly out of the row the user just clicked. When
        // the button isn't in a window (shouldn't happen here), fall back
        // to a frameless authorize call — the helper still appears.
        let sourceFrame: CGRect? = {
            guard let window = sender.window else { return nil }
            return window.convertToScreen(sender.convert(sender.bounds, to: nil))
        }()
        MainActor.assumeIsolated {
            permissionFlowController.authorize(
                pane: Self.permissionFlowPane(for: perm),
                suggestedAppURLs: [Bundle.main.bundleURL],
                sourceFrameInScreen: sourceFrame
            )
        }
    }

    private static func permissionFlowPane(for permission: Permission) -> PermissionFlowPane {
        switch permission {
        case .accessibility: return .accessibility
        case .inputMonitoring: return .inputMonitoring
        case .screenRecording: return .screenRecording
        }
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

        var newlyGranted: Permission?
        for perm in Permission.allCases {
            let was = lastGrantedSnapshot[perm] ?? false
            let isGranted = snapshot[perm] ?? false
            if was == isGranted { continue }
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
                if newlyGranted == nil { newlyGranted = perm }
            }
        }
        lastGrantedSnapshot = snapshot

        let allGranted = snapshot.values.allSatisfy({ $0 })
        primaryButton?.isEnabled = allGranted

        // Auto-chain: after the user grants one permission, queue the next
        // ungranted one's deep link so System Settings hops to it without
        // another button click. The short delay lets the green-flip register
        // visually before the floating helper repositions.
        if let just = newlyGranted, !allGranted, !inRelaunchFallback {
            scheduleAutoChainAfter(just)
        }
    }

    private func scheduleAutoChainAfter(_ justGranted: Permission) {
        autoChainWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.autoChainAfter(justGranted)
        }
        autoChainWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func autoChainAfter(_ justGranted: Permission) {
        autoChainWorkItem = nil
        guard !inRelaunchFallback, !wizardWindowClosed, !didFireCompleted else { return }
        // Prefer the next ungranted row after the one the user just dealt
        // with, wrapping to the top so we don't dead-end on the last row if
        // grants happen out of order.
        let display = permissions.map { $0.permission }
        guard let pivot = display.firstIndex(of: justGranted) else { return }
        let rotated = Array(display[(pivot + 1)...]) + Array(display[..<pivot])
        guard let next = rotated.first(where: {
            (lastGrantedSnapshot[$0] ?? false) == false
        }) else {
            return
        }
        guard let button = permissionRows[next]?.openSettingsButton else { return }
        // Anchor the floating helper to the corresponding row's button so
        // the launch animation matches a user-initiated click.
        let sourceFrame: CGRect? = {
            guard let window = button.window else { return nil }
            return window.convertToScreen(button.convert(button.bounds, to: nil))
        }()
        emit(type: "onboarding_auto_chain", details: [
            "permission": next.rawValue
        ])
        MainActor.assumeIsolated {
            permissionFlowController.authorize(
                pane: Self.permissionFlowPane(for: next),
                suggestedAppURLs: [Bundle.main.bundleURL],
                sourceFrameInScreen: sourceFrame
            )
        }
    }

    private func finishChecklist() {
        guard !didFireCompleted else { return }
        hotkeyStartRetryWorkItem?.cancel()
        hotkeyStartRetryWorkItem = nil
        autoChainWorkItem?.cancel()
        autoChainWorkItem = nil
        // Mark onboarded the moment the user commits to proceeding past
        // permissions; granting alone (no Get Started click) shouldn't count
        // as onboarded so a closed-wizard-on-fresh-install re-shows next
        // launch with the demo still pending.
        markOnboardedOnce()
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
        autoChainWorkItem?.cancel()
        autoChainWorkItem = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        // The wizard window stays open here (we swap its content rather than
        // closing it), so `windowWillClose` won't fire — close the floating
        // permission helper manually to avoid leaving it next to the
        // relaunch screen.
        MainActor.assumeIsolated {
            permissionFlowController.closePanel()
        }

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
        MainActor.assumeIsolated {
            permissionFlowController.closePanel()
        }
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
        autoChainWorkItem?.cancel()
        autoChainWorkItem = nil
        hotkeyStartRetryWorkItem?.cancel()
        hotkeyStartRetryWorkItem = nil
        MainActor.assumeIsolated {
            permissionFlowController.closePanel()
        }
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
