import AppKit
import Combine
import Sparkle

/// Tabbed Settings scene (`⌘,`). Toolbar-tab style à la System Settings.
/// Houses the configuration controls that used to be on the Control window
/// (Model / Reasoning / Sounds / Nudges / Style), plus a read-only
/// Permissions snapshot and Advanced utilities (open folders, updater).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private let coordinator: BlinkCoordinator
    private let runtimeStore: RuntimeConfigStore
    private let hotkeyDisplay: String
    private let onShowPermissions: () -> Void
    private let onResetPermissions: () -> Void
    private let onOpenRuns: () -> Void
    private let onOpenRuntime: () -> Void
    private weak var updaterController: SPUStandardUpdaterController?

    enum Pane: String, CaseIterable {
        case general, style, permissions, advanced

        var title: String {
            switch self {
            case .general: return "General"
            case .style: return "Style"
            case .permissions: return "Permissions"
            case .advanced: return "Advanced"
            }
        }

        var symbolName: String {
            switch self {
            case .general: return "gearshape"
            case .style: return "slider.horizontal.3"
            case .permissions: return "lock.shield"
            case .advanced: return "wrench.and.screwdriver"
            }
        }

        var toolbarIdentifier: NSToolbarItem.Identifier {
            NSToolbarItem.Identifier("BlinkSettingsPane.\(rawValue)")
        }
    }

    private var window: NSWindow?
    private var paneContainer = NSView()
    private var activePane: Pane = .general
    private var stylePane: StylePaneController?

    // General pane controls (kept around for subscriptions).
    private var modelPopup: NSPopUpButton?
    private var reasoningPopup: NSPopUpButton?
    private var soundsCheckbox: NSButton?
    private var nudgesCheckbox: NSButton?

    // Permissions pane status text fields.
    private var permissionStatusFields: [String: NSTextField] = [:]
    private var permissionsRefreshTimer: Timer?

    private var modelSubscription: AnyCancellable?
    private var reasoningSubscription: AnyCancellable?
    private var soundsSubscription: AnyCancellable?
    private var nudgesSubscription: AnyCancellable?

    init(
        coordinator: BlinkCoordinator,
        runtimeStore: RuntimeConfigStore,
        hotkeyDisplay: String,
        updaterController: SPUStandardUpdaterController?,
        onShowPermissions: @escaping () -> Void,
        onResetPermissions: @escaping () -> Void,
        onOpenRuns: @escaping () -> Void,
        onOpenRuntime: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.runtimeStore = runtimeStore
        self.hotkeyDisplay = hotkeyDisplay
        self.updaterController = updaterController
        self.onShowPermissions = onShowPermissions
        self.onResetPermissions = onResetPermissions
        self.onOpenRuns = onOpenRuns
        self.onOpenRuntime = onOpenRuntime
    }

    deinit {
        permissionsRefreshTimer?.invalidate()
    }

    func show(initialPane: Pane = .general) {
        if window == nil { buildWindow() }
        select(pane: initialPane)
        startSubscriptions()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Window

    private func buildWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Settings"
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.setFrameAutosaveName("BlinkSettings")
        win.contentMinSize = NSSize(width: 540, height: 380)

        let toolbar = NSToolbar(identifier: "BlinkSettingsToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconAndLabel
        if #available(macOS 11.0, *) {
            win.toolbarStyle = .preference
        }
        win.toolbar = toolbar
        if #available(macOS 11.0, *) {
            toolbar.selectedItemIdentifier = Pane.general.toolbarIdentifier
        }

        paneContainer.translatesAutoresizingMaskIntoConstraints = false
        win.contentView = paneContainer
        window = win
    }

    private func select(pane: Pane) {
        // Tear down the previous pane's owned state before swapping in a new
        // view. Without this, the prior StylePaneController would keep its
        // `$style` Combine sink alive — same for the Permissions refresh
        // timer — even after the user moved on to a different tab.
        teardownActivePane()
        activePane = pane
        window?.title = pane.title
        if #available(macOS 11.0, *) {
            window?.toolbar?.selectedItemIdentifier = pane.toolbarIdentifier
        }
        paneContainer.subviews.forEach { $0.removeFromSuperview() }
        let view: NSView
        switch pane {
        case .general: view = buildGeneralPane()
        case .style: view = buildStylePane()
        case .permissions: view = buildPermissionsPane()
        case .advanced: view = buildAdvancedPane()
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        paneContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: paneContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: paneContainer.trailingAnchor),
            view.topAnchor.constraint(equalTo: paneContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: paneContainer.bottomAnchor),
        ])
        refreshPermissionsRow()
    }

    // MARK: - Panes

    private func buildGeneralPane() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24)

        // Model
        let popup = NSPopUpButton()
        popup.target = self
        popup.action = #selector(modelChanged(_:))
        popup.toolTip = "Backend model used for summaries and replies."
        rebuildModelPopup(popup, current: runtimeStore.model)
        modelPopup = popup
        stack.addArrangedSubview(formRow(label: "Model", control: popup))

        // Reasoning
        let reasoning = NSPopUpButton()
        reasoning.target = self
        reasoning.action = #selector(reasoningChanged(_:))
        reasoning.addItems(withTitles: ReasoningLevels.titles)
        reasoning.selectItem(withTitle: ReasoningLevels.title(for: runtimeStore.thinkingLevel))
        reasoning.toolTip = "How much the model thinks before answering. Higher = slower, more careful."
        reasoningPopup = reasoning
        stack.addArrangedSubview(formRow(label: "Reasoning", control: reasoning))

        // Sounds
        let sounds = NSButton(
            checkboxWithTitle: "Play sounds",
            target: self,
            action: #selector(soundsToggled(_:))
        )
        sounds.state = runtimeStore.soundsEnabled ? .on : .off
        sounds.toolTip = "Subtle audio cues when a summary is ready or fails."
        soundsCheckbox = sounds
        stack.addArrangedSubview(sounds)

        // Nudges
        let nudges = NSButton(
            checkboxWithTitle: "Show nudges",
            target: self,
            action: #selector(nudgesToggled(_:))
        )
        nudges.state = runtimeStore.nudgesEnabled ? .on : .off
        nudges.toolTip = "Briefly remind you to use Blink when you're shuttling between apps."
        nudgesCheckbox = nudges
        stack.addArrangedSubview(nudges)

        // Hotkey row (display-only)
        let hotkey = NSTextField(labelWithString: hotkeyDisplay)
        hotkey.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        hotkey.textColor = .labelColor
        let hotkeyHint = NSTextField(labelWithString: "Press anywhere to summarize the focused window.")
        hotkeyHint.font = NSFont.systemFont(ofSize: 11)
        hotkeyHint.textColor = .tertiaryLabelColor
        let hotkeyStack = NSStackView(views: [hotkey, hotkeyHint])
        hotkeyStack.orientation = .vertical
        hotkeyStack.alignment = .leading
        hotkeyStack.spacing = 2
        stack.addArrangedSubview(formRow(label: "Hotkey", control: hotkeyStack))

        return wrapStack(stack)
    }

    private func buildStylePane() -> NSView {
        let pane = StylePaneController(runtimeStore: runtimeStore, contentWidth: 540 - 48)
        stylePane = pane
        pane.startSubscription()
        return pane.contentView
    }

    private func teardownActivePane() {
        // Style pane owns a Combine sink — explicitly stop it so the
        // previous pane doesn't keep observing $style.
        if let pane = stylePane {
            pane.stopSubscription()
            stylePane = nil
        }
        permissionsRefreshTimer?.invalidate()
        permissionsRefreshTimer = nil
        permissionStatusFields.removeAll()
        // General-pane controls are removed from the view hierarchy when
        // we swap panes; drop the strong refs so the in-flight subscriptions
        // stop firing into orphaned popups/checkboxes.
        modelPopup = nil
        reasoningPopup = nil
        soundsCheckbox = nil
        nudgesCheckbox = nil
    }

    private func buildPermissionsPane() -> NSView {
        permissionStatusFields.removeAll()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24)

        let intro = NSTextField(wrappingLabelWithString:
            "Blink relies on three macOS permissions. Re-run setup if a row says \"Not granted\"."
        )
        intro.font = NSFont.systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor
        intro.maximumNumberOfLines = 0
        intro.preferredMaxLayoutWidth = 540 - 48
        stack.addArrangedSubview(intro)

        let snapshot = PermissionsActions.currentSnapshot()
        stack.addArrangedSubview(permissionsRow(key: "accessibility", title: "Accessibility", granted: snapshot.accessibility))
        stack.addArrangedSubview(permissionsRow(key: "inputMonitoring", title: "Input Monitoring", granted: snapshot.inputMonitoring))
        stack.addArrangedSubview(permissionsRow(key: "screenRecording", title: "Screen Recording", granted: snapshot.screenRecording))

        let rerunBtn = NSButton(title: "Re-run setup…", target: self, action: #selector(reRunPermissions))
        rerunBtn.bezelStyle = .rounded
        rerunBtn.toolTip = "Open the first-run permission wizard."
        let resetBtn = NSButton(title: "Reset Permissions…", target: self, action: #selector(resetPermissions))
        resetBtn.bezelStyle = .rounded
        resetBtn.toolTip = "Clear every TCC grant for Blink (requires relaunch)."
        let btnRow = NSStackView(views: [rerunBtn, resetBtn])
        btnRow.orientation = .horizontal
        btnRow.spacing = 8
        stack.addArrangedSubview(btnRow)

        // Refresh the snapshot on a slow cadence while the pane is visible.
        permissionsRefreshTimer?.invalidate()
        permissionsRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissionsRow() }
        }

        return wrapStack(stack)
    }

    private func buildAdvancedPane() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24)

        let runs = NSButton(title: "Open runs folder", target: self, action: #selector(openRuns))
        runs.bezelStyle = .rounded
        runs.toolTip = "Recent capture bundles (screenshots, prompts, responses)."
        let runtime = NSButton(title: "Open ~/.blink", target: self, action: #selector(openRuntime))
        runtime.bezelStyle = .rounded
        runtime.toolTip = "Local config, prompts, runtime state."
        let btnRow = NSStackView(views: [runs, runtime])
        btnRow.orientation = .horizontal
        btnRow.spacing = 8
        stack.addArrangedSubview(btnRow)

        if updaterController != nil {
            let update = NSButton(title: "Check for Updates…", target: self, action: #selector(checkForUpdates(_:)))
            update.bezelStyle = .rounded
            stack.addArrangedSubview(update)
        }

        let footer = NSTextField(wrappingLabelWithString:
            "Summaries and suggestions are stored to improve Blink; screenshots are not retained."
        )
        footer.font = NSFont.systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor
        footer.maximumNumberOfLines = 0
        footer.preferredMaxLayoutWidth = 540 - 48
        stack.addArrangedSubview(footer)

        return wrapStack(stack)
    }

    private func permissionsRow(key: String, title: String, granted: Bool) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let status = NSTextField(labelWithString: granted ? "Granted" : "Not granted")
        status.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        status.textColor = granted ? .systemGreen : .tertiaryLabelColor
        permissionStatusFields[key] = status

        let row = NSStackView(views: [label, NSView(), status])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 12
        row.distribution = .fill
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            row.topAnchor.constraint(equalTo: container.topAnchor),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 540 - 48),
        ])
        return container
    }

    private func refreshPermissionsRow() {
        guard activePane == .permissions else { return }
        let snap = PermissionsActions.currentSnapshot()
        update(field: permissionStatusFields["accessibility"], granted: snap.accessibility)
        update(field: permissionStatusFields["inputMonitoring"], granted: snap.inputMonitoring)
        update(field: permissionStatusFields["screenRecording"], granted: snap.screenRecording)
    }

    private func update(field: NSTextField?, granted: Bool) {
        guard let field else { return }
        field.stringValue = granted ? "Granted" : "Not granted"
        field.textColor = granted ? .systemGreen : .tertiaryLabelColor
    }

    private func wrapStack(_ stack: NSStackView) -> NSView {
        stack.translatesAutoresizingMaskIntoConstraints = false
        let host = NSView()
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.topAnchor.constraint(equalTo: host.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor),
        ])
        return host
    }

    private func formRow(label: String, control: NSView) -> NSView {
        let title = NSTextField(labelWithString: label)
        title.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let row = NSStackView(views: [title, control])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 12
        return row
    }

    private func rebuildModelPopup(_ popup: NSPopUpButton, current: String) {
        popup.removeAllItems()
        var seen = Set<String>()
        for name in ModelChoices.optionsIncluding(current: current)
        where seen.insert(name).inserted {
            popup.addItem(withTitle: name)
        }
        popup.selectItem(withTitle: current)
    }

    // MARK: - Subscriptions

    private func startSubscriptions() {
        modelSubscription = runtimeStore.$model
            .receive(on: RunLoop.main)
            .sink { [weak self] selected in
                MainActor.assumeIsolated {
                    guard let popup = self?.modelPopup else { return }
                    if popup.itemTitle(at: popup.indexOfSelectedItem) != selected {
                        self?.rebuildModelPopup(popup, current: selected)
                    }
                }
            }
        reasoningSubscription = runtimeStore.$thinkingLevel
            .receive(on: RunLoop.main)
            .sink { [weak self] level in
                MainActor.assumeIsolated {
                    guard let popup = self?.reasoningPopup else { return }
                    let target = ReasoningLevels.title(for: level)
                    if popup.itemTitle(at: popup.indexOfSelectedItem) != target {
                        popup.selectItem(withTitle: target)
                    }
                }
            }
        soundsSubscription = runtimeStore.$soundsEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                MainActor.assumeIsolated {
                    self?.soundsCheckbox?.state = enabled ? .on : .off
                }
            }
        nudgesSubscription = runtimeStore.$nudgesEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                MainActor.assumeIsolated {
                    self?.nudgesCheckbox?.state = enabled ? .on : .off
                }
            }
    }

    private func stopSubscriptions() {
        modelSubscription = nil
        reasoningSubscription = nil
        soundsSubscription = nil
        nudgesSubscription = nil
        stylePane?.stopSubscription()
        permissionsRefreshTimer?.invalidate()
        permissionsRefreshTimer = nil
    }

    // MARK: - Actions

    @objc private func modelChanged(_ sender: NSPopUpButton) {
        guard let title = sender.titleOfSelectedItem else { return }
        runtimeStore.model = title
    }

    @objc private func reasoningChanged(_ sender: NSPopUpButton) {
        guard let title = sender.titleOfSelectedItem else { return }
        runtimeStore.thinkingLevel = ReasoningLevels.value(for: title)
    }

    @objc private func soundsToggled(_ sender: NSButton) {
        runtimeStore.soundsEnabled = (sender.state == .on)
    }

    @objc private func nudgesToggled(_ sender: NSButton) {
        runtimeStore.nudgesEnabled = (sender.state == .on)
    }

    @objc private func reRunPermissions() {
        onShowPermissions()
    }

    @objc private func resetPermissions() {
        onResetPermissions()
    }

    @objc private func openRuns() {
        onOpenRuns()
    }

    @objc private func openRuntime() {
        onOpenRuntime()
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        updaterController?.checkForUpdates(sender)
    }

    @objc private func selectPane(_ sender: NSToolbarItem) {
        guard let pane = Pane.allCases.first(where: { $0.toolbarIdentifier == sender.itemIdentifier }) else { return }
        select(pane: pane)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        stopSubscriptions()
    }

    // MARK: - NSToolbarDelegate

    nonisolated func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map { $0.toolbarIdentifier }
    }

    nonisolated func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map { $0.toolbarIdentifier }
    }

    nonisolated func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map { $0.toolbarIdentifier }
    }

    nonisolated func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        MainActor.assumeIsolated { () -> NSToolbarItem? in
            guard let pane = Pane.allCases.first(where: { $0.toolbarIdentifier == itemIdentifier }) else { return nil }
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = pane.title
            item.paletteLabel = pane.title
            item.toolTip = pane.title
            if #available(macOS 11.0, *) {
                item.image = NSImage(
                    systemSymbolName: pane.symbolName,
                    accessibilityDescription: pane.title
                )
            }
            item.target = self
            item.action = #selector(selectPane(_:))
            item.isBordered = true
            return item
        }
    }
}
