import AppKit
import ApplicationServices
import AVFoundation

/// First-run wizard for Blink's permission setup. The window owns the
/// explanation and uses System Settings deep links plus the drag fallback;
/// it deliberately avoids prompt-style TCC calls.
final class PermissionsWindowController: NSObject, NSWindowDelegate {
    private enum Step: String, CaseIterable {
        case welcome
        case accessibility
        case inputMonitoring
        case screenRecording
        case relaunch
        case ready
    }

    private struct PermissionCopy {
        let step: Step
        let headline: String
        let explainer: String
        let settingsURL: String
        let check: () -> Bool
    }

    private let hotkeyDisplay: String
    private let eventClient: BlinkEventClient?
    private let allowLogging: () -> Bool
    private let clientMetadata: () -> [String: Any]
    private let onFinished: () -> Void
    private let setOnboardingSampleActive: (Bool) -> Void

    private var window: NSWindow?
    private var contentHost = NSView()
    private var refreshTimer: Timer?
    private var currentStep: Step
    private var lastAutoAdvancedStep: Step?
    private var lastPermissionGrantedState: Bool = false
    private var lastAllPermissionsGrantedState: Bool = false
    private var didMarkOnboarded: Bool = false
    private var chatMockController: OnboardingChatMockWindowController?
    private var wizardWindowClosed: Bool = false

    init(
        hotkeyDisplay: String,
        eventClient: BlinkEventClient? = nil,
        allowLogging: @escaping () -> Bool = { false },
        clientMetadata: @escaping () -> [String: Any] = { [:] },
        setOnboardingSampleActive: @escaping (Bool) -> Void = { _ in },
        onFinished: @escaping () -> Void = {}
    ) {
        self.hotkeyDisplay = hotkeyDisplay
        self.eventClient = eventClient
        self.allowLogging = allowLogging
        self.clientMetadata = clientMetadata
        self.setOnboardingSampleActive = setOnboardingSampleActive
        self.onFinished = onFinished
        self.currentStep = PermissionsWindowController.initialStep()
        super.init()
    }

    func show() {
        if window == nil { buildWindow() }
        wizardWindowClosed = false
        transitionTo(Self.initialStep())
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startRefreshing()
    }

    private static func initialStep() -> Step {
        if Paths.requiresFirstRunOnboarding() {
            TCCDiagnostics.log("onboarding_initial_step requires_first_run_onboarding=true")
            return .welcome
        }
        if !AXIsProcessTrusted() {
            return .accessibility
        }
        if !inputMonitoringGranted() {
            return .inputMonitoring
        }
        if !screenRecordingGranted(caller: "PermissionsWindow.initialStep") {
            return .screenRecording
        }
        return .ready
    }

    private var permissions: [PermissionCopy] {
        [
            PermissionCopy(
                step: .accessibility,
                headline: "Allow Accessibility",
                explainer: "Blink reads the focused field and pastes your selected reply.",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                check: { AXIsProcessTrusted() }
            ),
            PermissionCopy(
                step: .inputMonitoring,
                headline: "Allow Input Monitoring",
                explainer: "Blink listens for \(hotkeyDisplay) and the overlay number keys.",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
                check: { PermissionsWindowController.inputMonitoringGranted() }
            ),
            PermissionCopy(
                step: .screenRecording,
                headline: "Allow Screen Recording",
                explainer: "Blink needs to see the active window before it can summarize it.",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                check: { Self.screenRecordingGranted(caller: "PermissionsWindow.screenRecordingCheck") }
            ),
        ]
    }

    private func buildWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 360),
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
            contentHost.widthAnchor.constraint(greaterThanOrEqualToConstant: 540),
            contentHost.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])
        win.center()
        window = win
    }

    private func transitionTo(_ step: Step) {
        currentStep = step
        lastPermissionGrantedState = false
        lastAutoAdvancedStep = nil
        lastAllPermissionsGrantedState = allPermissionsGranted()
        emit(type: "onboarding_step_shown", step: step)
        renderCurrentStep()
        // Trigger an immediate refresh so a step that is already granted
        // auto-advances without waiting for the 1Hz poll.
        refresh()
    }

    private func renderCurrentStep() {
        contentHost.subviews.forEach { $0.removeFromSuperview() }

        let view: NSView
        switch currentStep {
        case .welcome:
            view = welcomeView()
        case .screenRecording, .inputMonitoring, .accessibility:
            view = permissionView(for: currentStep)
        case .relaunch:
            view = relaunchView()
        case .ready:
            view = readyView()
        }

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
            width: max(target.width, 540),
            height: max(target.height, 320)
        ))
    }

    private func welcomeView() -> NSView {
        let title = heading("Blink turns the window you are reading into a short tl;dr and three replies.")
        title.maximumNumberOfLines = 3
        title.preferredMaxLayoutWidth = 460

        let hotkeyRow = labeledValue(label: "Hotkey", value: hotkeyDisplay)

        let allGranted = allPermissionsGranted()
        let seeSample = NSButton(title: "See a sample", target: self, action: #selector(showSample))
        seeSample.bezelStyle = .rounded
        seeSample.controlSize = .large
        seeSample.isEnabled = allGranted

        let getStarted = NSButton(title: "Get Started", target: self, action: #selector(startPermissions))
        getStarted.bezelStyle = .rounded
        getStarted.controlSize = .large
        getStarted.keyEquivalent = "\r"

        let buttons = NSStackView(views: [seeSample, getStarted])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10

        var stackViews: [NSView] = [title, hotkeyRow, buttons]
        if !allGranted {
            let helper = body("Grant the permissions below first to try a real sample.")
            helper.textColor = .tertiaryLabelColor
            stackViews.append(helper)
        }
        return baseStack(views: stackViews)
    }

    private func allPermissionsGranted() -> Bool {
        permissions.allSatisfy { $0.check() }
    }

    private func permissionView(for step: Step) -> NSView {
        guard let copy = permissions.first(where: { $0.step == step }) else {
            return readyView()
        }
        let granted = copy.check()
        let title = heading(copy.headline)
        let detail = body(copy.explainer)
        let status = statusLabel(granted: granted)

        let openSettings = NSButton(title: "Open Settings", target: self, action: #selector(openSettings))
        openSettings.identifier = NSUserInterfaceItemIdentifier(copy.settingsURL)
        openSettings.bezelStyle = .rounded
        openSettings.controlSize = .large

        let next = NSButton(
            title: granted ? "Next" : "Waiting for permission",
            target: self,
            action: #selector(nextStep)
        )
        next.bezelStyle = .rounded
        next.controlSize = .large
        next.isEnabled = granted
        if granted {
            next.keyEquivalent = "\r"
        }

        let buttons = NSStackView(views: [openSettings, next])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10

        let stack = baseStack(views: [
            title,
            detail,
            status,
            buttons,
            dragFallbackSection(),
        ])
        return stack
    }

    private func relaunchView() -> NSView {
        let title = heading("Relaunch Blink")
        let detail = body("Some permissions only take effect after Blink relaunches.")

        let relaunch = NSButton(
            title: "Quit & Relaunch",
            target: self,
            action: #selector(quitAndRelaunch)
        )
        relaunch.bezelStyle = .rounded
        relaunch.controlSize = .large
        relaunch.keyEquivalent = "\r"

        return baseStack(views: [title, detail, relaunch])
    }

    private func readyView() -> NSView {
        let title = heading("Blink is ready.")
        let detail = body("Press \(hotkeyDisplay) on any window to try it.")

        let seeSample = NSButton(title: "See a sample", target: self, action: #selector(showSample))
        seeSample.bezelStyle = .rounded
        seeSample.controlSize = .large

        let done = NSButton(title: "Done", target: self, action: #selector(finishWithoutRelaunch))
        done.bezelStyle = .rounded
        done.controlSize = .large
        done.keyEquivalent = "\r"

        let buttons = NSStackView(views: [seeSample, done])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10

        return baseStack(views: [title, detail, buttons])
    }

    private func baseStack(views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 28, bottom: 28, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 21, weight: .semibold)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 460
        return label
    }

    private func body(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 460
        return label
    }

    private func labeledValue(label: String, value: String) -> NSView {
        let name = NSTextField(labelWithString: label)
        name.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        name.textColor = .secondaryLabelColor

        let value = NSTextField(labelWithString: value)
        value.font = NSFont.monospacedSystemFont(ofSize: 15, weight: .semibold)
        value.textColor = .labelColor

        let stack = NSStackView(views: [name, value])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 12
        return stack
    }

    private func statusLabel(granted: Bool) -> NSTextField {
        let label = NSTextField(labelWithString: granted ? "Granted" : "Not granted yet")
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.textColor = granted ? .systemGreen : .tertiaryLabelColor
        return label
    }

    /// Builds the manual-drag fallback footer. Visible on every permission
    /// step so users can recover when System Settings does not list Blink.
    private func dragFallbackSection() -> NSView {
        let dragView = BundleDragSourceView(bundleURL: Bundle.main.bundleURL)
        NSLayoutConstraint.activate([
            dragView.widthAnchor.constraint(equalToConstant: 48),
            dragView.heightAnchor.constraint(equalToConstant: 48),
        ])

        let label = NSTextField(wrappingLabelWithString:
            "If Blink is missing from the list, drag this app icon into the System Settings window."
        )
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 3
        label.preferredMaxLayoutWidth = 360
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [dragView, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 14
        return stack
    }

    @objc private func showSample() {
        guard chatMockController == nil else {
            chatMockController?.show()
            return
        }
        emit(type: "onboarding_sample_invoked", step: currentStep)
        let fixture = OnboardingFixture.load()
        setOnboardingSampleActive(true)
        let controller = OnboardingChatMockWindowController(
            messages: fixture.messages,
            hotkeyDisplay: hotkeyDisplay
        ) { [weak self] in
            guard let self else { return }
            self.setOnboardingSampleActive(false)
            self.chatMockController = nil
            // Only re-show the wizard if it wasn't closed by the user while
            // the mock was up — otherwise we'd resurrect a window they
            // dismissed.
            if !self.wizardWindowClosed {
                self.window?.makeKeyAndOrderFront(nil)
            }
        }
        chatMockController = controller
        // Hide the wizard while the sample is up so it doesn't sit in front
        // of the capture target.
        window?.orderOut(nil)
        controller.show()
    }

    @objc private func startPermissions() {
        emit(type: "onboarding_step_completed", step: .welcome)
        transitionTo(.accessibility)
    }

    @objc private func openSettings(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let url = URL(string: id) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func nextStep() {
        emit(type: "onboarding_step_completed", step: currentStep)
        if let permission = permissions.first(where: { $0.step == currentStep }),
           permission.check(),
           lastAutoAdvancedStep != currentStep {
            // Manual advance for a granted step that the poll hasn't reported
            // yet — still record the grant so telemetry isn't lopsided.
            emit(type: "permissions_granted", step: currentStep)
        }
        transitionTo(stepAfter(currentStep))
    }

    @objc private func quitAndRelaunch() {
        emit(type: "onboarding_step_completed", step: .relaunch)
        markOnboardedOnce()
        relaunchSelf()
    }

    @objc private func finishWithoutRelaunch() {
        emit(type: "onboarding_step_completed", step: .ready)
        markOnboardedOnce()
        window?.close()
        onFinished()
    }

    private func markOnboardedOnce() {
        guard !didMarkOnboarded else { return }
        didMarkOnboarded = true
        Paths.markOnboarded()
    }

    private func stepAfter(_ step: Step) -> Step {
        switch step {
        case .welcome:
            return .accessibility
        case .accessibility:
            return .inputMonitoring
        case .inputMonitoring:
            return .screenRecording
        case .screenRecording:
            return .relaunch
        case .relaunch, .ready:
            return .ready
        }
    }

    private func startRefreshing() {
        refreshTimer?.invalidate()
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        if currentStep == .welcome {
            let allGranted = allPermissionsGranted()
            if allGranted != lastAllPermissionsGrantedState {
                lastAllPermissionsGrantedState = allGranted
                renderCurrentStep()
            }
            return
        }
        guard let permission = permissions.first(where: { $0.step == currentStep }) else { return }
        let granted = permission.check()
        guard granted != lastPermissionGrantedState else { return }
        lastPermissionGrantedState = granted
        renderCurrentStep()
        guard granted else {
            lastAutoAdvancedStep = nil
            return
        }
        guard lastAutoAdvancedStep != currentStep else { return }
        lastAutoAdvancedStep = currentStep
        emit(type: "permissions_granted", step: currentStep)
        let pendingStep = currentStep
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.currentStep == pendingStep else { return }
            self.emit(type: "onboarding_step_completed", step: pendingStep)
            self.transitionTo(self.stepAfter(pendingStep))
        }
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
        // If the user closes the wizard while the mock chat window is still
        // up, tear it down so the onboarding-sample flag clears.
        chatMockController?.close()
        if !didMarkOnboarded, currentStep != .ready {
            // Intentional: closing the wizard mid-flow leaves the marker
            // absent so the next launch retries onboarding. We record the
            // abandonment for telemetry so drop-off is visible.
            emit(type: "onboarding_abandoned", step: currentStep)
        }
    }

    private func emit(type: String, step: Step) {
        eventClient?.send(
            requestID: "onboarding-\(Paths.loadOrCreateInstallID())",
            eventType: type,
            allowLogging: allowLogging(),
            clientMetadata: clientMetadata(),
            details: ["step": step.rawValue]
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
