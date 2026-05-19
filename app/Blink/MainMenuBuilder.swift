import AppKit
import Combine
import Sparkle

/// Retains live Combine sinks so the View ▸ Model, View ▸ Reasoning,
/// View ▸ Sounds, and View ▸ Nudges items stay in sync with
/// `RuntimeConfigStore`. Owned by `AppDelegate`.
@MainActor
final class MainMenuController: NSObject {
    fileprivate let coordinator: BlinkCoordinator
    fileprivate let runtimeStore: RuntimeConfigStore
    fileprivate let hotkeyDisplay: String
    fileprivate weak var updaterController: SPUStandardUpdaterController?
    fileprivate let onShowSettings: () -> Void
    fileprivate let onShowPermissions: () -> Void
    fileprivate let onResetPermissions: () -> Void
    fileprivate let onOpenRuns: () -> Void
    fileprivate let onOpenRuntime: () -> Void
    fileprivate let onShowHelp: () -> Void

    fileprivate weak var soundsItem: NSMenuItem?
    fileprivate weak var nudgesItem: NSMenuItem?
    fileprivate weak var modelSubmenu: NSMenu?
    fileprivate weak var reasoningSubmenu: NSMenu?
    fileprivate weak var checkForUpdatesItem: NSMenuItem?

    private var modelObserver: AnyCancellable?
    private var thinkingObserver: AnyCancellable?
    private var soundsObserver: AnyCancellable?
    private var nudgesObserver: AnyCancellable?

    init(
        coordinator: BlinkCoordinator,
        runtimeStore: RuntimeConfigStore,
        hotkeyDisplay: String,
        updaterController: SPUStandardUpdaterController?,
        onShowSettings: @escaping () -> Void,
        onShowPermissions: @escaping () -> Void,
        onResetPermissions: @escaping () -> Void,
        onOpenRuns: @escaping () -> Void,
        onOpenRuntime: @escaping () -> Void,
        onShowHelp: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.runtimeStore = runtimeStore
        self.hotkeyDisplay = hotkeyDisplay
        self.updaterController = updaterController
        self.onShowSettings = onShowSettings
        self.onShowPermissions = onShowPermissions
        self.onResetPermissions = onResetPermissions
        self.onOpenRuns = onOpenRuns
        self.onOpenRuntime = onOpenRuntime
        self.onShowHelp = onShowHelp
    }

    fileprivate func startObservers() {
        modelObserver = runtimeStore.$model.sink { [weak self] selected in
            Task { @MainActor in
                self?.refreshModelSubmenu(selected: selected)
            }
        }
        thinkingObserver = runtimeStore.$thinkingLevel.sink { [weak self] level in
            Task { @MainActor in
                self?.refreshReasoningSubmenu(level: level)
            }
        }
        soundsObserver = runtimeStore.$soundsEnabled.sink { [weak self] enabled in
            Task { @MainActor in
                self?.soundsItem?.state = enabled ? .on : .off
            }
        }
        nudgesObserver = runtimeStore.$nudgesEnabled.sink { [weak self] enabled in
            Task { @MainActor in
                self?.nudgesItem?.state = enabled ? .on : .off
            }
        }
    }

    func refreshModelSubmenu(selected: String) {
        guard let menu = modelSubmenu else { return }
        var matched = false
        for item in menu.items {
            if let name = item.representedObject as? String {
                let isSelected = (name == selected)
                item.state = isSelected ? .on : .off
                matched = matched || isSelected
            }
        }
        if !matched {
            let item = NSMenuItem(
                title: selected,
                action: #selector(selectModel(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = selected
            item.state = .on
            menu.insertItem(item, at: 0)
        }
    }

    func refreshReasoningSubmenu(level: String?) {
        guard let menu = reasoningSubmenu else { return }
        let activeTitle = ReasoningLevels.title(for: level)
        for item in menu.items {
            let title = item.title
            item.state = (title == activeTitle) ? .on : .off
        }
    }

    func setUpdater(_ controller: SPUStandardUpdaterController?) {
        self.updaterController = controller
        // Keep the menu item visible even when Sparkle isn't configured (e.g.
        // local dev builds with an http:// feed URL) so the menu shape is
        // predictable across builds. Disabled state + tooltip explains why it
        // can't be invoked.
        checkForUpdatesItem?.isHidden = false
        checkForUpdatesItem?.isEnabled = (controller != nil)
        checkForUpdatesItem?.toolTip = controller == nil
            ? "Update channel not configured in this build."
            : nil
    }

    // MARK: - Actions

    @objc fileprivate func showSettings() { onShowSettings() }
    @objc fileprivate func showPermissions() { onShowPermissions() }
    @objc fileprivate func resetPermissions() { onResetPermissions() }
    @objc fileprivate func openRuns() { onOpenRuns() }
    @objc fileprivate func openRuntime() { onOpenRuntime() }
    @objc fileprivate func openHelp() { onShowHelp() }

    @objc fileprivate func checkForUpdates(_ sender: Any?) {
        // Sparkle's update window inherits frontmost-app context — activate
        // Blink first so the modal floats above whatever the user was looking
        // at when they clicked.
        NSApp.activate(ignoringOtherApps: true)
        updaterController?.checkForUpdates(sender)
    }

    @objc fileprivate func summarizeFrontmost() {
        let now = DispatchTime.now()
        coordinator.summarizeFrontmostWindow(pressedAt: now, summarizeEnteredAt: now)
    }

    @objc fileprivate func rerollSuggestions() {
        coordinator.rerollCurrentSuggestions()
    }

    @objc fileprivate func dismissOverlay() {
        coordinator.dismissOverlay()
    }

    @objc fileprivate func toggleSounds() {
        runtimeStore.soundsEnabled.toggle()
    }

    @objc fileprivate func toggleNudges() {
        runtimeStore.nudgesEnabled.toggle()
    }

    @objc fileprivate func selectModel(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        runtimeStore.model = name
    }

    @objc fileprivate func selectReasoning(_ sender: NSMenuItem) {
        runtimeStore.thinkingLevel = ReasoningLevels.value(for: sender.title)
    }
}

// MARK: - NSMenuItemValidation

extension MainMenuController: NSMenuItemValidation {
    nonisolated func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        MainActor.assumeIsolated {
            switch menuItem.action {
            case #selector(rerollSuggestions),
                 #selector(dismissOverlay):
                return coordinator.isOverlayActive
            case #selector(checkForUpdates(_:)):
                return updaterController != nil
            default:
                return true
            }
        }
    }
}

@MainActor
enum MainMenuBuilder {
    static func build(
        coordinator: BlinkCoordinator,
        runtimeStore: RuntimeConfigStore,
        hotkeyDisplay: String,
        updaterController: SPUStandardUpdaterController?,
        onShowSettings: @escaping () -> Void,
        onShowPermissions: @escaping () -> Void,
        onResetPermissions: @escaping () -> Void,
        onOpenRuns: @escaping () -> Void,
        onOpenRuntime: @escaping () -> Void,
        onShowHelp: @escaping () -> Void
    ) -> (menu: NSMenu, controller: MainMenuController) {
        let controller = MainMenuController(
            coordinator: coordinator,
            runtimeStore: runtimeStore,
            hotkeyDisplay: hotkeyDisplay,
            updaterController: updaterController,
            onShowSettings: onShowSettings,
            onShowPermissions: onShowPermissions,
            onResetPermissions: onResetPermissions,
            onOpenRuns: onOpenRuns,
            onOpenRuntime: onOpenRuntime,
            onShowHelp: onShowHelp
        )

        let root = NSMenu()
        root.addItem(makeAppMenu(controller: controller))
        root.addItem(makeEditMenu())
        root.addItem(makeActionMenu(controller: controller, hotkeyDisplay: hotkeyDisplay))
        root.addItem(makeViewMenu(controller: controller, runtimeStore: runtimeStore))
        let (windowMenuItem, windowMenu) = makeWindowMenu()
        root.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu
        let (helpMenuItem, helpMenu) = makeHelpMenu(controller: controller)
        root.addItem(helpMenuItem)
        NSApp.helpMenu = helpMenu

        controller.startObservers()
        // Seed initial state so checkmarks are correct before the first
        // store mutation.
        controller.refreshModelSubmenu(selected: runtimeStore.model)
        controller.refreshReasoningSubmenu(level: runtimeStore.thinkingLevel)
        controller.soundsItem?.state = runtimeStore.soundsEnabled ? .on : .off
        controller.nudgesItem?.state = runtimeStore.nudgesEnabled ? .on : .off

        return (root, controller)
    }

    // MARK: - Submenu builders

    private static func makeAppMenu(controller: MainMenuController) -> NSMenuItem {
        let app = NSMenuItem()
        let menu = NSMenu(title: "Blink")

        menu.addItem(NSMenuItem(
            title: "About Blink",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())

        let checkForUpdates = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(MainMenuController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdates.target = controller
        // Always visible — Sparkle config may arrive after the menu builds,
        // and a stable menu shape is worth more than hiding a disabled row.
        checkForUpdates.isHidden = false
        checkForUpdates.isEnabled = (controller.updaterController != nil)
        if controller.updaterController == nil {
            checkForUpdates.toolTip = "Update channel not configured in this build."
        }
        controller.checkForUpdatesItem = checkForUpdates
        menu.addItem(checkForUpdates)

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(MainMenuController.showSettings),
            keyEquivalent: ","
        )
        settings.target = controller
        menu.addItem(settings)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(
            title: "Hide Blink",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        ))
        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(NSMenuItem(
            title: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit Blink",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        app.submenu = menu
        return app
    }

    private static func makeEditMenu() -> NSMenuItem {
        let edit = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        menu.addItem(NSMenuItem(
            title: "Undo",
            action: Selector(("undo:")),
            keyEquivalent: "z"
        ))
        let redo = NSMenuItem(
            title: "Redo",
            action: Selector(("redo:")),
            keyEquivalent: "z"
        )
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        ))
        menu.addItem(NSMenuItem(
            title: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        ))
        menu.addItem(NSMenuItem(
            title: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        ))
        menu.addItem(NSMenuItem(
            title: "Delete",
            action: #selector(NSText.delete(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        ))
        edit.submenu = menu
        return edit
    }

    private static func makeActionMenu(controller: MainMenuController, hotkeyDisplay: String) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Action")

        let summarize = NSMenuItem(
            title: "Summarize Frontmost Window",
            action: #selector(MainMenuController.summarizeFrontmost),
            keyEquivalent: ""
        )
        summarize.target = controller
        // Display-only annotation; the global hotkey path remains
        // authoritative. We don't bind keyEquivalent here for the same
        // reason ControlWindow's Summarize button doesn't: when the menu
        // is the responder, Blink itself is "frontmost".
        summarize.toolTip = "Press \(hotkeyDisplay) anywhere to summarize the focused window."
        menu.addItem(summarize)

        let reroll = NSMenuItem(
            title: "Reroll Suggestions",
            action: #selector(MainMenuController.rerollSuggestions),
            keyEquivalent: "r"
        )
        reroll.keyEquivalentModifierMask = [.command, .shift]
        reroll.target = controller
        menu.addItem(reroll)

        let dismiss = NSMenuItem(
            title: "Dismiss Overlay",
            action: #selector(MainMenuController.dismissOverlay),
            keyEquivalent: "\u{1B}"  // Escape
        )
        dismiss.keyEquivalentModifierMask = []
        dismiss.target = controller
        menu.addItem(dismiss)

        item.submenu = menu
        return item
    }

    private static func makeViewMenu(controller: MainMenuController, runtimeStore: RuntimeConfigStore) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "View")

        let sounds = NSMenuItem(
            title: "Sounds",
            action: #selector(MainMenuController.toggleSounds),
            keyEquivalent: ""
        )
        sounds.target = controller
        sounds.state = runtimeStore.soundsEnabled ? .on : .off
        controller.soundsItem = sounds
        menu.addItem(sounds)

        let nudges = NSMenuItem(
            title: "Nudges",
            action: #selector(MainMenuController.toggleNudges),
            keyEquivalent: ""
        )
        nudges.target = controller
        nudges.state = runtimeStore.nudgesEnabled ? .on : .off
        nudges.toolTip = "Briefly remind you to use Blink when you're shuttling between apps"
        controller.nudgesItem = nudges
        menu.addItem(nudges)

        menu.addItem(.separator())

        // Model submenu.
        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let modelMenu = NSMenu(title: "Model")
        let current = runtimeStore.model
        var seen = Set<String>()
        for name in ModelChoices.optionsIncluding(current: current)
        where seen.insert(name).inserted {
            let entry = NSMenuItem(
                title: name,
                action: #selector(MainMenuController.selectModel(_:)),
                keyEquivalent: ""
            )
            entry.target = controller
            entry.representedObject = name
            entry.state = (name == current) ? .on : .off
            modelMenu.addItem(entry)
        }
        modelItem.submenu = modelMenu
        controller.modelSubmenu = modelMenu
        menu.addItem(modelItem)

        // Reasoning submenu.
        let reasoningItem = NSMenuItem(title: "Reasoning", action: nil, keyEquivalent: "")
        let reasoningMenu = NSMenu(title: "Reasoning")
        let activeTitle = ReasoningLevels.title(for: runtimeStore.thinkingLevel)
        for title in ReasoningLevels.titles {
            let entry = NSMenuItem(
                title: title,
                action: #selector(MainMenuController.selectReasoning(_:)),
                keyEquivalent: ""
            )
            entry.target = controller
            entry.state = (title == activeTitle) ? .on : .off
            reasoningMenu.addItem(entry)
        }
        reasoningItem.submenu = reasoningMenu
        controller.reasoningSubmenu = reasoningMenu
        menu.addItem(reasoningItem)

        item.submenu = menu
        return item
    }

    private static func makeWindowMenu() -> (NSMenuItem, NSMenu) {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")
        menu.addItem(NSMenuItem(
            title: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        ))
        menu.addItem(NSMenuItem(
            title: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        ))
        item.submenu = menu
        return (item, menu)
    }

    private static func makeHelpMenu(controller: MainMenuController) -> (NSMenuItem, NSMenu) {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Help")

        let help = NSMenuItem(
            title: "Blink Help",
            action: #selector(MainMenuController.openHelp),
            keyEquivalent: "?"
        )
        help.target = controller
        menu.addItem(help)
        menu.addItem(.separator())

        let runs = NSMenuItem(
            title: "Open Runs Folder",
            action: #selector(MainMenuController.openRuns),
            keyEquivalent: ""
        )
        runs.target = controller
        menu.addItem(runs)

        let runtime = NSMenuItem(
            title: "Open ~/.blink",
            action: #selector(MainMenuController.openRuntime),
            keyEquivalent: ""
        )
        runtime.target = controller
        menu.addItem(runtime)
        menu.addItem(.separator())

        let permissions = NSMenuItem(
            title: "Permissions…",
            action: #selector(MainMenuController.showPermissions),
            keyEquivalent: ""
        )
        permissions.target = controller
        menu.addItem(permissions)

        let reset = NSMenuItem(
            title: "Reset Permissions…",
            action: #selector(MainMenuController.resetPermissions),
            keyEquivalent: ""
        )
        reset.target = controller
        menu.addItem(reset)

        item.submenu = menu
        return (item, menu)
    }
}
