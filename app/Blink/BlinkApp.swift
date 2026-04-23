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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: TrialCoordinator!
    private var menubar: MenubarController!
    private var hotkeys: HotkeyManager!
    private var permissionsWindow: PermissionsWindowController?
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
        coordinator = TrialCoordinator(config: config)
        menubar = MenubarController(coordinator: coordinator, onShowPermissions: { [weak self] in
            self?.showPermissionsWindow()
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
            guard let self = self else { timer.invalidate(); return }
            if self.hotkeys.start() {
                timer.invalidate()
                self.hotkeyRetryTimer = nil
            }
        }
    }

    func showPermissionsWindow() {
        if permissionsWindow == nil {
            permissionsWindow = PermissionsWindowController()
        }
        permissionsWindow?.show()
    }
}
