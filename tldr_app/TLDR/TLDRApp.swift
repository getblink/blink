import AppKit
import CoreGraphics
import IOKit.hid
import Sparkle

@main
final class TLDRAppMain {
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
    private var coordinator: TLDRCoordinator!
    private var menubar: MenubarController!
    private var hotkeys: HotkeyManager!
    private var permissionsWindow: PermissionsWindowController?
    private var controlWindow: ControlWindowController?
    private var runtimeStore: RuntimeConfigStore?
    private var eventClient: TLDREventClient?
    private var nudgeCoordinator: NudgeCoordinator?
    private var hotkeyRetryTimer: Timer?
    private var updaterController: SPUStandardUpdaterController?
    private var hotkeyDisplay: String = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = CGRequestScreenCaptureAccess()
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)

        let config = Config.load()
        let summaryHotkey = Hotkey.loadFromSettings(at: Paths.settingsPath)
        self.hotkeyDisplay = summaryHotkey.displayString
        let runtimeStore = RuntimeConfigStore()
        self.runtimeStore = runtimeStore
        DeviceTokenManager.mintIfNeeded(proxyConfig: RuntimeEnvironment.bootstrapProxyConfig())
        let eventClient = TLDREventClient(proxyConfig: RuntimeEnvironment.proxyConfig())
        self.eventClient = eventClient
        let soundEffects = SoundEffects(runtimeStore: runtimeStore)

        PendingRunStore.sweepAbandonedRuns(
            eventClient: eventClient,
            allowLogging: runtimeStore.allowEventLogging,
            clientMetadata: TLDRCoordinator.clientMetadata()
        )

        coordinator = TLDRCoordinator(
            config: config,
            runtimeStore: runtimeStore,
            eventClient: eventClient,
            summaryHotkey: summaryHotkey,
            soundEffects: soundEffects
        )
        coordinator.onFailureNotice = { [weak self] title, message in
            self?.showFailureAlert(title: title, message: message)
        }

        menubar = MenubarController(
            coordinator: coordinator,
            runtimeStore: runtimeStore,
            hotkeyDisplay: summaryHotkey.displayString,
            onShowPermissions: { [weak self] in self?.showPermissionsWindow() },
            onShowControlWindow: { [weak self] in self?.showControlWindow() }
        )
        menubar.install()
        if Self.hasUsableSparkleConfig {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
            menubar.setUpdater(updaterController)
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
            onSummarize: { [weak coordinator, weak nudges] in
                Task { @MainActor in nudges?.noteHotkeyInvoked() }
                coordinator?.summarizeFrontmostWindow()
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
            onDismiss: { [weak coordinator] in coordinator?.dismissOverlay() }
        )

        showControlWindow()
        if !hotkeys.start() {
            startHotkeyRetry()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // Dock-icon click while no windows are visible should reopen the
        // control window — same role the menubar item plays.
        if !hasVisibleWindows {
            showControlWindow()
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

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyRetryTimer?.invalidate()
        hotkeyRetryTimer = nil
        hotkeys?.stop()
        nudgeCoordinator?.stop()
    }

    func showPermissionsWindow() {
        if permissionsWindow == nil {
            permissionsWindow = PermissionsWindowController()
        }
        permissionsWindow?.show()
    }

    func showControlWindow() {
        guard let runtimeStore else { return }
        if controlWindow == nil {
            controlWindow = ControlWindowController(
                coordinator: coordinator,
                runtimeStore: runtimeStore,
                hotkeyDisplay: hotkeyDisplay,
                onShowPermissions: { [weak self] in self?.showPermissionsWindow() }
            )
        }
        controlWindow?.show()
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
