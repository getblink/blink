import AppKit
import Combine

@MainActor
final class MenubarController: NSObject {
    private let coordinator: TLDRCoordinator
    private let runtimeStore: RuntimeConfigStore
    private let onShowPermissions: () -> Void
    private var statusItem: NSStatusItem!
    private var statusLabel: NSMenuItem!
    private var autoPasteItem: NSMenuItem!
    private var cancellables: Set<AnyCancellable> = []

    init(
        coordinator: TLDRCoordinator,
        runtimeStore: RuntimeConfigStore,
        onShowPermissions: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.runtimeStore = runtimeStore
        self.onShowPermissions = onShowPermissions
    }

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "TLDR"
        statusItem.button?.toolTip = "TLDR reply assistant"
        statusItem.menu = buildMenu()

        coordinator.onStatusChange = { [weak self] text in
            Task { @MainActor in
                self?.statusLabel.title = text
                self?.updateIndicator(for: text)
            }
        }

        runtimeStore.$autoPaste
            .sink { [weak self] enabled in
                self?.autoPasteItem?.state = enabled ? .on : .off
            }
            .store(in: &cancellables)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        statusLabel = NSMenuItem(title: "Idle - press Ctrl+Shift+T", action: nil, keyEquivalent: "")
        statusLabel.isEnabled = false
        menu.addItem(statusLabel)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Summarize frontmost window (Ctrl+Shift+T)", action: #selector(triggerSummarize), keyEquivalent: "")
            .target = self

        autoPasteItem = NSMenuItem(title: "Auto-paste suggestions", action: #selector(toggleAutoPaste), keyEquivalent: "")
        autoPasteItem.target = self
        autoPasteItem.state = runtimeStore.autoPaste ? .on : .off
        menu.addItem(autoPasteItem)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Open runs folder", action: #selector(openRunsFolder), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Open ~/.tldr", action: #selector(openRuntimeFolder), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Permissions...", action: #selector(openPermissions), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())

        menu.addItem(withTitle: "Quit TLDR", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func triggerSummarize() {
        coordinator.summarizeFrontmostWindow()
    }

    @objc private func toggleAutoPaste() {
        runtimeStore.autoPaste.toggle()
    }

    @objc private func openRunsFolder() {
        NSWorkspace.shared.open(Paths.runsDir)
    }

    @objc private func openRuntimeFolder() {
        NSWorkspace.shared.open(Paths.runtimeDir)
    }

    @objc private func openPermissions() {
        onShowPermissions()
    }

    private func updateIndicator(for status: String) {
        let normalized = status.lowercased()
        let title: String
        if normalized.contains("failed") || normalized.contains("empty") {
            title = "TLDR!"
        } else if normalized.contains("ready") || normalized.contains("copied") || normalized.contains("pasted") {
            title = "TLDR"
        } else if normalized.contains("capturing") || normalized.contains("calling") || normalized.contains("thinking") {
            title = "TLDR..."
        } else {
            title = "TLDR"
        }
        statusItem.button?.title = title
        statusItem.button?.toolTip = "TLDR: \(status)"
    }
}
