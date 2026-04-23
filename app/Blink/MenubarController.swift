import AppKit

final class MenubarController: NSObject {
    private let coordinator: TrialCoordinator
    private let onShowPermissions: () -> Void
    private var statusItem: NSStatusItem!
    private var statusLabel: NSMenuItem!

    init(coordinator: TrialCoordinator, onShowPermissions: @escaping () -> Void) {
        self.coordinator = coordinator
        self.onShowPermissions = onShowPermissions
    }

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⎈"
        statusItem.button?.toolTip = "Blink copy-paste assistant"
        statusItem.menu = buildMenu()

        coordinator.onStatusChange = { [weak self] text in
            DispatchQueue.main.async { self?.statusLabel.title = text }
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        statusLabel = NSMenuItem(title: "Idle — press ⌃⇧C to set source", action: nil, keyEquivalent: "")
        statusLabel.isEnabled = false
        menu.addItem(statusLabel)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Capture source (⌃⇧C)", action: #selector(triggerSource), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Capture target + paste (⌃⇧V)", action: #selector(triggerTarget), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())

        menu.addItem(withTitle: "Export last 10 runs…", action: #selector(exportRuns), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Open runs folder", action: #selector(openRunsFolder), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())

        menu.addItem(withTitle: "Permissions…", action: #selector(openPermissions), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())

        menu.addItem(withTitle: "Quit Blink", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func triggerSource() { coordinator.setSource() }
    @objc private func triggerTarget() { coordinator.runTarget() }
    @objc private func exportRuns() {
        BundleExporter.exportLastNToDesktop(n: 10) { result in
            DispatchQueue.main.async {
                let alert = NSAlert()
                switch result {
                case .success(let url):
                    alert.messageText = "Exported"
                    alert.informativeText = "Wrote \(url.path)"
                case .failure(let err):
                    alert.alertStyle = .warning
                    alert.messageText = "Export failed"
                    alert.informativeText = "\(err)"
                }
                alert.runModal()
            }
        }
    }
    @objc private func openRunsFolder() {
        NSWorkspace.shared.open(Paths.runsDir)
    }
    @objc private func openPermissions() { onShowPermissions() }
}
