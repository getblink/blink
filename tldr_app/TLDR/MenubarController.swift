import AppKit
import Combine

@MainActor
final class MenubarController: NSObject {
    static let modelOptions: [String] = [
        "gemini-3.1-flash-lite-preview",
        "gemini-3.1-pro-preview",
        "gemini-3-flash-preview",
        "gemma-4-26b-a4b-it",
    ]

    private let coordinator: TLDRCoordinator
    private let runtimeStore: RuntimeConfigStore
    private let onShowPermissions: () -> Void
    private var statusItem: NSStatusItem!
    private var statusLabel: NSMenuItem!
    private var modelMenu: NSMenu?
    private var modelObserver: AnyCancellable?

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

        modelObserver = runtimeStore.$model.sink { [weak self] selected in
            Task { @MainActor in
                self?.refreshModelMenuStates(selected: selected)
            }
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        statusLabel = NSMenuItem(title: "Idle - press Ctrl+Shift+T", action: nil, keyEquivalent: "")
        statusLabel.isEnabled = false
        menu.addItem(statusLabel)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Summarize frontmost window (Ctrl+Shift+T)", action: #selector(triggerSummarize), keyEquivalent: "")
            .target = self

        menu.addItem(withTitle: "Open runs folder", action: #selector(openRunsFolder), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Open ~/.tldr", action: #selector(openRuntimeFolder), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Permissions...", action: #selector(openPermissions), keyEquivalent: "")
            .target = self

        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        modelItem.submenu = buildModelMenu()
        menu.addItem(modelItem)

        menu.addItem(.separator())

        menu.addItem(withTitle: "Quit TLDR", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private func buildModelMenu() -> NSMenu {
        let menu = NSMenu()
        let current = runtimeStore.model
        var seen = Set<String>()
        var options = Self.modelOptions
        if !options.contains(current) {
            options.insert(current, at: 0)
        }
        for name in options where seen.insert(name).inserted {
            let item = NSMenuItem(title: name, action: #selector(selectModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = (name == current) ? .on : .off
            menu.addItem(item)
        }
        modelMenu = menu
        return menu
    }

    private func refreshModelMenuStates(selected: String) {
        guard let menu = modelMenu else { return }
        var matched = false
        for item in menu.items {
            if let name = item.representedObject as? String {
                let isSelected = (name == selected)
                item.state = isSelected ? .on : .off
                matched = matched || isSelected
            }
        }
        if !matched {
            let item = NSMenuItem(title: selected, action: #selector(selectModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = selected
            item.state = .on
            menu.insertItem(item, at: 0)
        }
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        runtimeStore.model = name
    }

    @objc private func triggerSummarize() {
        coordinator.summarizeFrontmostWindow()
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
