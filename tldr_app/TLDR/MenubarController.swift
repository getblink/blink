import AppKit
import Combine
import Sparkle

@MainActor
final class MenubarController: NSObject {
    private let coordinator: TLDRCoordinator
    private let runtimeStore: RuntimeConfigStore
    private let onShowPermissions: () -> Void
    private let onShowControlWindow: () -> Void
    private let hotkeyDisplay: String
    private var statusItem: NSStatusItem!
    private var statusLabel: NSMenuItem!
    private var modelMenu: NSMenu?
    private var modelObserver: AnyCancellable?
    private var soundsObserver: AnyCancellable?
    private var soundsMenuItem: NSMenuItem?
    private var nudgesObserver: AnyCancellable?
    private var nudgesMenuItem: NSMenuItem?
    private var updateMenuItem: NSMenuItem?
    private weak var updaterController: SPUStandardUpdaterController?
    private var thinkingTimer: Timer?
    private var thinkingTick = 0
    private var statusPulseGeneration = 0

    deinit {
        thinkingTimer?.invalidate()
    }

    init(
        coordinator: TLDRCoordinator,
        runtimeStore: RuntimeConfigStore,
        hotkeyDisplay: String,
        onShowPermissions: @escaping () -> Void,
        onShowControlWindow: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.runtimeStore = runtimeStore
        self.hotkeyDisplay = hotkeyDisplay
        self.onShowPermissions = onShowPermissions
        self.onShowControlWindow = onShowControlWindow
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
        soundsObserver = runtimeStore.$soundsEnabled.sink { [weak self] enabled in
            Task { @MainActor in
                self?.soundsMenuItem?.state = enabled ? .on : .off
            }
        }
        nudgesObserver = runtimeStore.$nudgesEnabled.sink { [weak self] enabled in
            Task { @MainActor in
                self?.nudgesMenuItem?.state = enabled ? .on : .off
            }
        }
    }

    /// Screen-space frame of the status item button, used to anchor a nudge
    /// tip just below it. Returns `nil` if the button has no window yet
    /// (rare — only before `install()` finishes attaching the status item).
    func statusItemScreenFrame() -> NSRect? {
        guard let button = statusItem?.button,
              let window = button.window else { return nil }
        let inWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(inWindow)
    }

    /// Brief subtle pulse to draw attention to the menubar icon.
    /// Bypasses thinking-animation generation so it can run while idle.
    func pulseForNudge() {
        guard let button = statusItem?.button else { return }
        button.wantsLayer = true
        pulseButtonScale(to: 1.18, duration: 0.18) { [weak self] in
            Task { @MainActor in
                self?.pulseButtonScale(to: 1.0, duration: 0.32, completion: nil)
            }
        }
    }

    func setUpdater(_ updaterController: SPUStandardUpdaterController?) {
        self.updaterController = updaterController
        updateMenuItem?.isEnabled = updaterController != nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        statusLabel = NSMenuItem(title: "Idle - press \(hotkeyDisplay)", action: nil, keyEquivalent: "")
        statusLabel.isEnabled = false
        menu.addItem(statusLabel)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Open TLDR Window…", action: #selector(openControlWindow), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Summarize frontmost window (\(hotkeyDisplay))", action: #selector(triggerSummarize), keyEquivalent: "")
            .target = self

        menu.addItem(withTitle: "Open runs folder", action: #selector(openRunsFolder), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Open ~/.tldr", action: #selector(openRuntimeFolder), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Permissions...", action: #selector(openPermissions), keyEquivalent: "")
            .target = self
        let soundsItem = NSMenuItem(title: "Sounds", action: #selector(toggleSounds(_:)), keyEquivalent: "")
        soundsItem.target = self
        soundsItem.state = runtimeStore.soundsEnabled ? .on : .off
        soundsMenuItem = soundsItem
        menu.addItem(soundsItem)
        let nudgesItem = NSMenuItem(title: "Nudges", action: #selector(toggleNudges(_:)), keyEquivalent: "")
        nudgesItem.target = self
        nudgesItem.state = runtimeStore.nudgesEnabled ? .on : .off
        nudgesItem.toolTip = "Briefly remind you to use TLDR when you're shuttling between apps"
        nudgesMenuItem = nudgesItem
        menu.addItem(nudgesItem)
        let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = self
        updateItem.isEnabled = updaterController != nil
        updateMenuItem = updateItem
        menu.addItem(updateItem)

        let retentionItem = NSMenuItem(
            title: "Summaries and suggestions are stored to improve TLDR; screenshots are not retained.",
            action: nil,
            keyEquivalent: ""
        )
        retentionItem.isEnabled = false
        menu.addItem(retentionItem)

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
        for name in ModelChoices.optionsIncluding(current: current)
        where seen.insert(name).inserted {
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

    @objc private func openControlWindow() {
        onShowControlWindow()
    }

    @objc private func toggleSounds(_ sender: NSMenuItem) {
        runtimeStore.soundsEnabled.toggle()
    }

    @objc private func toggleNudges(_ sender: NSMenuItem) {
        runtimeStore.nudgesEnabled.toggle()
    }

    @objc private func checkForUpdates(_ sender: NSMenuItem) {
        updaterController?.checkForUpdates(sender)
    }

    private func updateIndicator(for status: String) {
        let normalized = status.lowercased()
        let title: String
        let pulse: (color: NSColor, duration: TimeInterval)?
        if normalized.contains("failed") || normalized.contains("empty") {
            stopThinkingAnimation()
            title = "TLDR!"
            pulse = (.systemRed, 0.4)
        } else if normalized.contains("ready")
            || normalized.contains("copied")
            || normalized.contains("inserted")
            || normalized.contains("pasted") {
            stopThinkingAnimation()
            title = "TLDR"
            if normalized.contains("ready") {
                pulse = (.controlAccentColor, 0.3)
            } else {
                pulse = nil
            }
        } else if normalized.contains("capturing") || normalized.contains("calling") || normalized.contains("thinking") {
            startThinkingAnimation()
            title = "TLDR..."
            pulse = nil
        } else {
            stopThinkingAnimation()
            title = "TLDR"
            pulse = nil
        }
        statusItem.button?.title = title
        statusItem.button?.toolTip = "TLDR: \(status)"
        if let pulse {
            pulseStatusItem(color: pulse.color, duration: pulse.duration)
        }
    }

    private func startThinkingAnimation() {
        guard thinkingTimer == nil else { return }
        thinkingTick = 0
        statusItem.button?.wantsLayer = true
        thinkingTimer = Timer.scheduledTimer(withTimeInterval: 0.32, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.advanceThinkingAnimation()
            }
        }
    }

    private func advanceThinkingAnimation() {
        let dots = String(repeating: ".", count: thinkingTick % 4)
        statusItem.button?.title = "TLDR\(dots)"
        pulseButtonScale(to: 0.94, duration: 0.13) { [weak self] in
            Task { @MainActor in
                self?.pulseButtonScale(to: 1.0, duration: 0.16, completion: nil)
            }
        }
        thinkingTick += 1
    }

    private func stopThinkingAnimation() {
        thinkingTimer?.invalidate()
        thinkingTimer = nil
        thinkingTick = 0
        statusPulseGeneration += 1
        statusItem.button?.layer?.removeAllAnimations()
        statusItem.button?.layer?.transform = CATransform3DIdentity
    }

    private func pulseButtonScale(to scale: CGFloat, duration: TimeInterval, completion: (() -> Void)?) {
        guard let button = statusItem.button else {
            completion?()
            return
        }
        button.wantsLayer = true
        let from = button.layer?.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat ?? 1.0
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = from
        animation.toValue = scale
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        button.layer?.add(animation, forKey: "statusScale")
        button.layer?.transform = CATransform3DMakeScale(scale, scale, 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            completion?()
        }
    }

    private func pulseStatusItem(color: NSColor, duration: TimeInterval) {
        guard let button = statusItem.button else { return }
        statusPulseGeneration += 1
        let generation = statusPulseGeneration
        let normalTitle = button.title
        let highlighted = NSAttributedString(
            string: normalTitle,
            attributes: [.foregroundColor: color]
        )
        button.attributedTitle = highlighted
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard generation == self.statusPulseGeneration else { return }
            button.attributedTitle = NSAttributedString(string: self.statusItem.button?.title ?? normalTitle)
        }
    }
}
