import AppKit
import ApplicationServices
import CoreGraphics
import PermissionFlowExtendedStatus
import Sparkle

@main
final class BlinkAppMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: BlinkCoordinator!
    private var menubar: MenubarController!
    private var hotkeys: HotkeyManager!
    private var permissionsWindow: PermissionsWindowController?
    private var controlWindow: ControlWindowController?
    private var settingsWindow: SettingsWindowController?
    private var onboardingSampleWindow: OnboardingChatMockWindowController?
    private var runtimeStore: RuntimeConfigStore?
    private var eventClient: BlinkEventClient?
    private var nudgeCoordinator: NudgeCoordinator?
    private let firstHotkeyOverlay = NudgeOverlay()
    private var hotkeyRetryTimer: Timer?
    private var updaterController: SPUStandardUpdaterController?
    private var hotkeyDisplay: String = ""
    private var summaryHotkey: Hotkey = .default
    private var mainMenuController: MainMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchedAt = DispatchTime.now()
        Self.logLaunchIdentity()
        // Enables `.inputMonitoring` and `.screenRecording` status detection
        // for the PermissionFlow controller used by the onboarding window.
        PermissionFlowExtendedStatus.register()
        let config = Config.load()
        let summaryHotkey = Hotkey.loadFromSettings(at: Paths.settingsPath)
        self.hotkeyDisplay = summaryHotkey.displayString
        self.summaryHotkey = summaryHotkey
        let runtimeStore = RuntimeConfigStore()
        self.runtimeStore = runtimeStore
        // Note: we no longer backfill the onboarded marker based on the
        // runs/ directory. The wizard owns the marker exclusively — it's
        // written when the user clicks Get Started, so any user who hasn't
        // explicitly completed the new wizard still sees it on launch,
        // including testers whose runs/ persists across TCC resets.
        DeviceTokenManager.mintIfNeeded(proxyConfig: RuntimeEnvironment.bootstrapProxyConfig())
        let eventClient = BlinkEventClient(proxyConfig: RuntimeEnvironment.proxyConfig())
        self.eventClient = eventClient
        let soundEffects = SoundEffects(runtimeStore: runtimeStore)

        PendingRunStore.sweepAbandonedRuns(
            eventClient: eventClient,
            allowLogging: runtimeStore.allowEventLogging,
            clientMetadata: BlinkCoordinator.clientMetadata()
        )

        coordinator = BlinkCoordinator(
            config: config,
            runtimeStore: runtimeStore,
            eventClient: eventClient,
            summaryHotkey: summaryHotkey,
            soundEffects: soundEffects,
            launchedAt: launchedAt
        )
        coordinator.onFailureNotice = { [weak self] title, message in
            self?.showFailureAlert(title: title, message: message)
        }
        coordinator.onPermissionsNeeded = { [weak self] in
            self?.showPermissionsWindow()
        }

        menubar = MenubarController(
            coordinator: coordinator,
            runtimeStore: runtimeStore,
            hotkeyDisplay: summaryHotkey.displayString,
            onShowPermissions: { [weak self] in self?.showPermissionsWindow() },
            onShowControlWindow: { [weak self] in self?.showControlWindow() }
        )
        menubar.install()

        // HIG rule #1: install a real macOS main menu (App / Edit / Action /
        // View / Window / Help). Done before any window appears so menu
        // validation can reach the coordinator from the very first event.
        installMainMenu(
            coordinator: coordinator,
            runtimeStore: runtimeStore,
            hotkeyDisplay: summaryHotkey.displayString
        )
        if Self.hasUsableSparkleConfig {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
            menubar.setUpdater(updaterController)
            // SUScheduledCheckInterval (24h) would skip a check on frequent
            // relaunches, so nudge Sparkle to run a fresh background check
            // shortly after launch. Silent unless an update is available, and
            // still respects the user's "Automatically check for updates"
            // preference via Sparkle's automaticallyChecksForUpdates gate.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak updaterController] in
                updaterController?.updater.checkForUpdatesInBackground()
            }
            // Sparkle was configured after the main menu was built; let the
            // controller surface the Check for Updates… item now.
            mainMenuController?.setUpdater(updaterController)
        }

        let nudges = NudgeCoordinator(
            runtimeStore: runtimeStore,
            eventClient: eventClient,
            hotkeyDisplay: summaryHotkey.displayString,
            menubarFrame: { [weak menubar] in menubar?.statusItemScreenFrame() },
            pulseMenubar: { [weak menubar] in menubar?.pulseForNudge() },
            isCoordinatorBusy: { [weak coordinator] in
                guard let coordinator else { return true }
                return coordinator.isOverlayActive
                    || coordinator.isCustomInputActive
                    || coordinator.isCollectingActive
            }
        )
        self.nudgeCoordinator = nudges
        nudges.start()

        hotkeys = HotkeyManager(
            summaryHotkey: summaryHotkey,
            isOverlayActive: { [weak coordinator] in coordinator?.isOverlayActive ?? false },
            isCustomInputActive: { [weak coordinator] in coordinator?.isCustomInputActive ?? false },
            isCollectingActive: { [weak coordinator] in coordinator?.isCollectingActive ?? false },
            onSummarize: { [weak coordinator, weak nudges] pressedAt in
                let summarizeEnteredAt = DispatchTime.now()
                Task { @MainActor in nudges?.noteHotkeyInvoked() }
                coordinator?.summarizeFrontmostWindow(
                    pressedAt: pressedAt,
                    summarizeEnteredAt: summarizeEnteredAt
                )
            },
            onSummaryHotkeyWhileOverlay: { [weak coordinator, weak nudges] pressedAt in
                let summarizeEnteredAt = DispatchTime.now()
                Task { @MainActor in nudges?.noteHotkeyInvoked() }
                coordinator?.acknowledgeSummaryHotkeyForReroll(
                    pressedAt: pressedAt,
                    summarizeEnteredAt: summarizeEnteredAt
                )
            },
            onSubmitCollecting: { [weak coordinator] in coordinator?.submitCollectingSession() },
            onCancelCollecting: { [weak coordinator] in coordinator?.cancelCollectingSession() },
            onChoice: { [weak coordinator] index in coordinator?.chooseSuggestion(index: index) },
            onInsert: { [weak coordinator] in
                if Thread.isMainThread {
                    return coordinator?.insertExpandedSuggestion() ?? false
                }
                var consumed = false
                DispatchQueue.main.sync {
                    consumed = coordinator?.insertExpandedSuggestion() ?? false
                }
                return consumed
            },
            onCustomInsert: { [weak coordinator] in
                if Thread.isMainThread {
                    _ = coordinator?.insertCustomReplyFromInput()
                    return true
                }
                DispatchQueue.main.sync {
                    _ = coordinator?.insertCustomReplyFromInput()
                }
                return true
            },
            onLeaveCustomInput: { [weak coordinator] in coordinator?.leaveCustomInput() },
            onTextEditing: { [weak coordinator] shortcut in
                if Thread.isMainThread {
                    return coordinator?.performCustomInputShortcut(shortcut) ?? false
                }
                var consumed = false
                DispatchQueue.main.sync {
                    consumed = coordinator?.performCustomInputShortcut(shortcut) ?? false
                }
                return consumed
            },
            onReroll: { [weak coordinator] in coordinator?.rerollCurrentSuggestions() },
            onDismiss: { [weak coordinator] in coordinator?.dismissOverlay() }
        )

        if shouldShowPermissionSetup() {
            showPermissionsWindow()
        } else {
            showControlWindow()
            showFirstHotkeyNudgeIfNeeded()
            startHotkeysIfNeeded()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // Dock-icon click while no windows are visible should reopen the
        // control window — same role the menubar item plays.
        if !hasVisibleWindows {
            if shouldShowPermissionSetup() {
                showPermissionsWindow()
            } else {
                showControlWindow()
            }
        }
        return true
    }

    private func startHotkeyRetry() {
        hotkeyRetryTimer?.invalidate()
        hotkeyRetryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self = self else {
                    timer.invalidate()
                    return
                }
                guard HotkeyManager.inputMonitoringGranted() else { return }
                if self.hotkeys.start() {
                    timer.invalidate()
                    self.hotkeyRetryTimer = nil
                }
            }
        }
    }

    private func startHotkeysIfNeeded() {
        guard hotkeys != nil else { return }
        guard !shouldShowPermissionSetup() else {
            TCCDiagnostics.log("hotkeys_start_deferred permissions_needed=true")
            return
        }
        if !hotkeys.start() {
            TCCDiagnostics.log("hotkeys_start_failed retrying=true")
            startHotkeyRetry()
        } else {
            TCCDiagnostics.log("hotkeys_start_succeeded")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyRetryTimer?.invalidate()
        hotkeyRetryTimer = nil
        hotkeys?.stop()
        nudgeCoordinator?.stop()
        firstHotkeyOverlay.close(userClicked: false, animated: false)
    }

    func showPermissionsWindow() {
        if permissionsWindow == nil {
            permissionsWindow = PermissionsWindowController(
                eventClient: eventClient,
                allowLogging: { [weak runtimeStore] in
                    runtimeStore?.allowEventLogging ?? false
                },
                clientMetadata: {
                    BlinkCoordinator.clientMetadata()
                },
                attemptHotkeyStart: { [weak self] in
                    self?.hotkeys?.start() ?? false
                },
                onFinished: { [weak self] in
                    self?.startHotkeysIfNeeded()
                    self?.runOnboardingSample()
                }
            )
        }
        permissionsWindow?.show()
    }

    /// Opens the chat-mock demo window and lets the user press the real
    /// summary hotkey themselves — the demo's job is to teach them the key
    /// they'll use forever. Permissions are guaranteed granted at this
    /// point; the control window opens once the user closes the mock.
    private func runOnboardingSample() {
        guard onboardingSampleWindow == nil else {
            onboardingSampleWindow?.show()
            return
        }
        let fixture = OnboardingFixture.load()
        coordinator.setOnboardingSampleActive(true)
        let mock = OnboardingChatMockWindowController(
            fixture: fixture,
            hotkeyDisplay: coordinator.currentHotkey.displayString
        ) { [weak self] in
            guard let self else { return }
            self.coordinator.setOnboardingSampleActive(false)
            self.onboardingSampleWindow = nil
            self.showControlWindow()
            self.showFirstHotkeyNudgeIfNeeded()
        }
        onboardingSampleWindow = mock
        mock.show()
        // System Settings may still be the OS-level frontmost app from the
        // last auto-chain hop. Re-activate Blink right after the mock opens
        // so the global hotkey, when the user presses it, captures the
        // mock window and not whatever Settings.app left behind.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.onboardingSampleWindow?.bringToFront()
        }
    }

    func showControlWindow() {
        guard !shouldShowPermissionSetup() else {
            showPermissionsWindow()
            return
        }
        guard let runtimeStore else { return }
        if controlWindow == nil {
            controlWindow = ControlWindowController(
                coordinator: coordinator,
                runtimeStore: runtimeStore,
                hotkey: summaryHotkey,
                onShowSettings: { [weak self] in self?.showSettingsWindow() }
            )
        }
        controlWindow?.show()
    }

    func showSettingsWindow(initialPane: SettingsWindowController.Pane = .general) {
        guard let runtimeStore else { return }
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                coordinator: coordinator,
                runtimeStore: runtimeStore,
                hotkeyDisplay: hotkeyDisplay,
                updaterController: updaterController,
                onShowPermissions: { [weak self] in self?.showPermissionsWindow() },
                onResetPermissions: { PermissionsActions.resetPermissions() },
                onOpenRuns: { NSWorkspace.shared.open(Paths.runsDir) },
                onOpenRuntime: { NSWorkspace.shared.open(Paths.runtimeDir) }
            )
        }
        settingsWindow?.show(initialPane: initialPane)
    }

    private func installMainMenu(
        coordinator: BlinkCoordinator,
        runtimeStore: RuntimeConfigStore,
        hotkeyDisplay: String
    ) {
        let (menu, controller) = MainMenuBuilder.build(
            coordinator: coordinator,
            runtimeStore: runtimeStore,
            hotkeyDisplay: hotkeyDisplay,
            updaterController: updaterController,
            onShowSettings: { [weak self] in self?.showSettingsWindow() },
            onShowPermissions: { [weak self] in self?.showPermissionsWindow() },
            onResetPermissions: { PermissionsActions.resetPermissions() },
            onOpenRuns: { NSWorkspace.shared.open(Paths.runsDir) },
            onOpenRuntime: { NSWorkspace.shared.open(Paths.runtimeDir) },
            onShowHelp: {
                if let url = URL(string: "https://github.com/henryz2004/blink") {
                    NSWorkspace.shared.open(url)
                }
            }
        )
        NSApp.mainMenu = menu
        mainMenuController = controller
    }

    private func shouldShowPermissionSetup() -> Bool {
        Paths.requiresFirstRunOnboarding()
            || !Self.requiredPermissionsGranted(caller: "AppDelegate.shouldShowPermissionSetup")
    }

    private static func requiredPermissionsGranted(caller: String) -> Bool {
        let accessibility = AXIsProcessTrusted()
        let screenRecording = CGPreflightScreenCaptureAccess()
        let inputMonitoring = HotkeyManager.inputMonitoringGranted()
        TCCDiagnostics.log(
            "required_permissions caller=\(caller) accessibility=\(accessibility) screen_recording_preflight=\(screenRecording) input_monitoring=\(inputMonitoring)"
        )
        return accessibility && screenRecording && inputMonitoring
    }

    private static func logLaunchIdentity() {
        let bundle = Bundle.main
        let info = bundle.infoDictionary ?? [:]
        TCCDiagnostics.log(
            "launch_identity bundle_id=\(bundle.bundleIdentifier ?? "nil") bundle_url=\(bundle.bundleURL.path) executable=\(bundle.executableURL?.path ?? "nil") version=\(info["CFBundleShortVersionString"] as? String ?? "nil") build=\(info["CFBundleVersion"] as? String ?? "nil")"
        )
    }

    private func showFirstHotkeyNudgeIfNeeded() {
        // Re-evaluate against the filesystem rather than a cached flag so the
        // post-wizard "Done" path (which writes the marker mid-launch) still
        // qualifies. The nudge-shown marker, written below, prevents repeats.
        guard Paths.shouldShowFirstHotkeyNudge() else { return }
        Paths.markFirstHotkeyNudgeShown()
        let anchor = menubar.statusItemScreenFrame()
            ?? NSRect(x: NSScreen.main?.visibleFrame.midX ?? 720,
                      y: NSScreen.main?.visibleFrame.maxY ?? 900,
                      width: 1,
                      height: 1)
        firstHotkeyOverlay.show(
            text: "Press \(hotkeyDisplay) on any window to try it.",
            anchor: anchor,
            autoDismissAfter: 4.0
        ) { _ in }
    }

    private func showFailureAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static var hasUsableSparkleConfig: Bool {
        guard
            let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        else {
            return false
        }
        return feedURL.hasPrefix("https://")
            && !feedURL.contains("example.com")
            && !publicKey.isEmpty
            && !publicKey.contains("REPLACE_WITH")
    }
}
