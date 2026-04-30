import AppKit
import CoreGraphics
import IOKit.hid

@main
final class TLDRAppMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: TLDRCoordinator!
    private var menubar: MenubarController!
    private var hotkeys: HotkeyManager!
    private var permissionsWindow: PermissionsWindowController?
    private var runtimeStore: RuntimeConfigStore?
    private var eventClient: TLDREventClient?
    private var hotkeyRetryTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = CGRequestScreenCaptureAccess()
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)

        let config = Config.load()
        let runtimeStore = RuntimeConfigStore()
        self.runtimeStore = runtimeStore
        let eventClient = TLDREventClient(proxyConfig: RuntimeEnvironment.proxyConfig())
        self.eventClient = eventClient

        PendingRunStore.sweepAbandonedRuns(
            eventClient: eventClient,
            allowLogging: runtimeStore.allowEventLogging,
            clientMetadata: TLDRCoordinator.clientMetadata()
        )

        coordinator = TLDRCoordinator(
            config: config,
            runtimeStore: runtimeStore,
            eventClient: eventClient
        )
        coordinator.onFailureNotice = { [weak self] title, message in
            self?.showFailureAlert(title: title, message: message)
        }

        menubar = MenubarController(
            coordinator: coordinator,
            runtimeStore: runtimeStore,
            onShowPermissions: { [weak self] in self?.showPermissionsWindow() }
        )
        menubar.install()

        hotkeys = HotkeyManager(
            isOverlayActive: { [weak coordinator] in coordinator?.isOverlayActive ?? false },
            onSummarize: { [weak coordinator] in coordinator?.summarizeFrontmostWindow() },
            onChoice: { [weak coordinator] index in coordinator?.chooseSuggestion(index: index) },
            onDismiss: { [weak coordinator] in coordinator?.dismissOverlay() }
        )

        showPermissionsWindow()
        if !hotkeys.start() {
            startHotkeyRetry()
        }
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
    }

    func showPermissionsWindow() {
        if permissionsWindow == nil {
            permissionsWindow = PermissionsWindowController()
        }
        permissionsWindow?.show()
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
}
