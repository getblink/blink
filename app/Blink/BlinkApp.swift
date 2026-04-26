import AppKit
import CoreGraphics
import IOKit.hid

@main
final class BlinkAppMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menubar-only; no Dock icon
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: TrialCoordinator!
    private var menubar: MenubarController!
    private var hotkeys: HotkeyManager!
    private var permissionsWindow: PermissionsWindowController?
    private var controlCenterWindow: ControlCenterWindowController?
    private var runtimeStore: RuntimeConfigStore?
    private var runStore: RunInspectorStore?
    private var hotkeyRetryTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register this app in the TCC database for Screen Recording so it
        // appears in System Settings → Privacy & Security → Screen Recording
        // before the user ever triggers a capture. Calling this is the only
        // way to make the entry appear without us first making an in-process
        // capture API call. CGPreflightScreenCaptureAccess does NOT register.
        _ = CGRequestScreenCaptureAccess()

        // Register for Input Monitoring the same way. CGEventTap creation does
        // not reliably register the app in TCC; IOHIDRequestAccess does.
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)

        let config = Config.load()
        let runtimeStore = RuntimeConfigStore()
        let runStore = RunInspectorStore()
        self.runtimeStore = runtimeStore
        self.runStore = runStore
        coordinator = TrialCoordinator(config: config, runtimeStore: runtimeStore)
        coordinator.onArtifactsChange = { [weak self] in
            self?.runStore?.refresh()
        }
        coordinator.onFailureNotice = { [weak self] title, message in
            self?.showFailureAlert(title: title, message: message)
        }
        menubar = MenubarController(coordinator: coordinator, onShowPermissions: { [weak self] in
            self?.showPermissionsWindow()
        }, onShowControlCenter: { [weak self] in
            self?.showControlCenter()
        })
        menubar.install()

        hotkeys = HotkeyManager(
            onSetSource: { [weak self] in self?.coordinator.setSource() },
            onRunTarget: { [weak self] in self?.coordinator.runTarget() }
        )
        if !hotkeys.start() {
            showPermissionsWindow()
            // Retry periodically — the user often grants Input Monitoring /
            // Accessibility after the first failed install, and we shouldn't
            // require a restart for the tap to come alive.
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

    func showControlCenter() {
        guard let runtimeStore, let runStore else { return }
        if controlCenterWindow == nil {
            controlCenterWindow = ControlCenterWindowController(
                runtimeStore: runtimeStore,
                runStore: runStore
            )
        }
        controlCenterWindow?.show()
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
