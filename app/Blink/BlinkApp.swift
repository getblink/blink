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
    private var onboardingDemoCard: OnboardingDemoCardWindowController?
    private var welcomeWindow: WelcomeWindowController?
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
        coordinator.onSummaryCompleted = { [weak self] success in
            self?.onboardingDemoCard?.noteSummaryCompleted(success: success)
        }
        coordinator.onSuggestionPicked = { [weak self] index in
            self?.onboardingDemoCard?.noteSuggestionPicked(index: index)
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
            isOverlayPinned: { [weak coordinator] in coordinator?.isOverlayPinned ?? false },
            onSummarize: { [weak coordinator, weak nudges, weak self] pressedAt in
                let summarizeEnteredAt = DispatchTime.now()
                Task { @MainActor in
                    nudges?.noteHotkeyInvoked()
                    self?.onboardingDemoCard?.noteHotkeyInvoked()
                }
                coordinator?.summarizeFrontmostWindow(
                    pressedAt: pressedAt,
                    summarizeEnteredAt: summarizeEnteredAt
                )
            },
            onSummaryHotkeyWhileOverlay: { [weak coordinator, weak nudges] pressedAt in
                let summarizeEnteredAt = DispatchTime.now()
                Task { @MainActor in nudges?.noteHotkeyInvoked() }
                coordinator?.handleSummaryHotkeyWhileOverlay(
                    pressedAt: pressedAt,
                    summarizeEnteredAt: summarizeEnteredAt
                )
            },
            onSubmitCollecting: { [weak coordinator] in coordinator?.submitCollectingSession() },
            onCancelCollecting: { [weak coordinator] in coordinator?.cancelCollectingFromUI() },
            onChoicePreflight: { [weak coordinator] index in coordinator?.preflightOverlayChoiceKey(index: index) },
            onChoice: { [weak coordinator] index in coordinator?.chooseSuggestion(index: index) },
            shouldConsumeInsert: { [weak coordinator] in
                coordinator?.shouldConsumeOverlayInsertKey ?? false
            },
            onInsert: { [weak coordinator] in
                _ = coordinator?.insertExpandedSuggestion()
            },
            onCustomInsert: { [weak coordinator] in
                _ = coordinator?.submitCustomInputFromInput()
            },
            onLeaveCustomInput: { [weak coordinator] in coordinator?.leaveCustomInput() },
            onTextEditing: { [weak coordinator] shortcut in
                _ = coordinator?.performCustomInputShortcut(shortcut)
            },
            onReroll: { [weak coordinator] in coordinator?.rerollCurrentSuggestions() },
            onTogglePin: { [weak coordinator] in coordinator?.toggleOverlayPin() },
            onArrowNav: { [weak coordinator] direction in coordinator?.handleArrowNav(direction) },
            onDismiss: { [weak coordinator] in coordinator?.dismissOverlay() }
        )

        if Paths.requiresFirstRunOnboarding() {
            // True first run: show the animated welcome slideshow, then hand
            // off to the live in-window permissions step.
            // Gated on the marker, not permissions, so a later permission
            // revocation re-runs the wizard without replaying the intro.
            runWelcomeSlideshow()
        } else if shouldShowPermissionSetup() {
            // Onboarded already, but permissions are missing — straight to
            // the wizard, no intro.
            showPermissionsWindow()
        } else {
            showControlWindow()
            showFirstHotkeyNudgeIfNeeded()
            startHotkeysIfNeeded()
            // Warm the ScreenCaptureKit XPC connection so the first hotkey
            // capture isn't ~0.8s slower than steady-state (cold SCK daemon).
            ScreenCapture.prewarm()
        }

        // Re-warm SCK whenever the user activates another app — that's exactly
        // when a capture is likely imminent, and it keeps the daemon connection
        // from going cold between captures. prewarm() is debounced and
        // permission-gated, so this can't spam the daemon or trigger a prompt;
        // skip our own activations.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            guard
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app.processIdentifier != NSRunningApplication.current.processIdentifier
            else { return }
            ScreenCapture.prewarm()
        }

        // Warm the capture-feedback surfaces (chime audio route + glass lens
        // render) shortly after launch, off the critical path, so the *first*
        // hotkey press doesn't pay their one-time first-use warmup as a lag.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak coordinator] in
            coordinator?.prewarmCaptureFeedback()
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
        onboardingDemoCard?.noteAppWillTerminate()
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
                    self?.runOnboardingDemo()
                }
            )
        }
        permissionsWindow?.show()
    }

    /// First-run only: the single-window welcome experience — "Welcome to
    /// Blink" landing → 4-slide tour → live in-window permissions. Completion
    /// (permissions granted + hotkey listening) hands off to the demo card. An
    /// early manual close leaves the marker unset so onboarding re-runs next
    /// launch; it no longer opens the separate AppKit wizard.
    private func runWelcomeSlideshow() {
        if let welcomeWindow {
            welcomeWindow.show()
            return
        }
        let welcome = WelcomeWindowController(
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
            // If a prior session already reached permissions (then got
            // relaunched mid-grant), resume there rather than replaying the
            // landing + tour.
            startAtPermissions: Paths.reachedOnboardingPermissions(),
            onComplete: { [weak self] in
                self?.welcomeWindow = nil
                self?.runOnboardingDemo()
            }
        )
        welcomeWindow = welcome
        welcome.show()
    }

    /// Opens the first-run demo card and waits for the user to press the real
    /// summary hotkey themselves on a window of their choice.
    private func runOnboardingDemo() {
        if let existing = onboardingDemoCard {
            existing.show()
            return
        }
        let card = OnboardingDemoCardWindowController(
            hotkeyDisplay: coordinator.currentHotkey.displayString,
            hotkeyParts: coordinator.currentHotkey.displayParts,
            eventClient: eventClient,
            allowLogging: { [weak runtimeStore] in
                runtimeStore?.allowEventLogging ?? false
            },
            clientMetadata: {
                BlinkCoordinator.clientMetadata()
            },
            onOutcome: { [weak self] outcome in
                guard let self else { return }
                self.onboardingDemoCard = nil
                switch outcome {
                case .firstHotkeyLanded, .skipped:
                    // The card is itself the first-hotkey nudge — mark the
                    // marker so the legacy 4-second toast doesn't fire next.
                    Paths.markFirstHotkeyNudgeShown()
                    // Don't pop a window cold. Bounce the Dock icon — Blink is a
                    // regular Dock app, so that's its always-visible home (no
                    // menubar-overflow problem). The landed card has just told
                    // the user Blink lives in the Dock; this draws the eye there.
                    NSApp.requestUserAttention(.informationalRequest)
                }
            }
        )
        onboardingDemoCard = card
        card.show()
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
