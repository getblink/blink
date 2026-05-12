import AppKit
import Combine

/// Standalone control window. Single-glance action surface: large status
/// label, hotkey reminder, retention footer; configuration lives in the
/// Settings scene. Toolbar carries Summarize (primary action), Model and
/// Reasoning popups, and a Settings shortcut.
@MainActor
final class ControlWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private let coordinator: BlinkCoordinator
    private let runtimeStore: RuntimeConfigStore
    private let hotkeyDisplay: String
    private let onShowSettings: () -> Void

    private var window: NSWindow?
    private var statusLabel: NSTextField?
    private var modelPopup: NSPopUpButton?
    private var reasoningPopup: NSPopUpButton?

    private var statusSubscription: AnyCancellable?
    private var modelSubscription: AnyCancellable?
    private var reasoningSubscription: AnyCancellable?

    private enum ToolbarID {
        static let summarize = NSToolbarItem.Identifier("BlinkControl.summarize")
        static let model = NSToolbarItem.Identifier("BlinkControl.model")
        static let reasoning = NSToolbarItem.Identifier("BlinkControl.reasoning")
        static let settings = NSToolbarItem.Identifier("BlinkControl.settings")
    }

    /// The app that was frontmost just before this window took focus, so the
    /// "Summarize" button targets *that* app rather than Blink itself.
    /// Captured on show; consumed on Summarize click.
    private weak var previousFrontmost: NSRunningApplication?

    init(
        coordinator: BlinkCoordinator,
        runtimeStore: RuntimeConfigStore,
        hotkeyDisplay: String,
        onShowSettings: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.runtimeStore = runtimeStore
        self.hotkeyDisplay = hotkeyDisplay
        self.onShowSettings = onShowSettings
    }

    func show() {
        if window == nil { buildWindow() }
        // Snapshot the app that's currently frontmost BEFORE we steal focus
        // — that's the one Summarize should target. windowDidBecomeKey is
        // unreliable here because our own activation may already be in
        // flight by the time it fires.
        let frontmost = NSWorkspace.shared.frontmostApplication
        let ownPID = NSRunningApplication.current.processIdentifier
        if let frontmost, frontmost.processIdentifier != ownPID {
            previousFrontmost = frontmost
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Re-show paths (menubar item, dock click, second show()) need to
        // tear down stale subscriptions before re-subscribing.
        stopSubscriptions()
        startSubscriptions()
    }

    private func buildWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 220),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Blink"
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.setFrameAutosaveName("BlinkControl")
        if #available(macOS 11.0, *) {
            win.toolbarStyle = .unified
        }
        win.titleVisibility = .hidden

        let toolbar = NSToolbar(identifier: "BlinkControlToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconAndLabel
        win.toolbar = toolbar

        win.contentView = buildContent()
        win.contentMinSize = NSSize(width: 480, height: 200)
        window = win
    }

    private func buildContent() -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false

        let backdrop: NSView
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            backdrop = view
        } else {
            let effect = NSVisualEffectView()
            effect.material = .contentBackground
            effect.blendingMode = .behindWindow
            effect.state = .followsWindowActiveState
            backdrop = effect
        }
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(backdrop)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let status = NSTextField(labelWithString: coordinator.statusSubject.value)
        status.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        status.textColor = .labelColor
        status.lineBreakMode = .byTruncatingTail
        status.toolTip = "Current Blink status."
        statusLabel = status
        stack.addArrangedSubview(status)

        let hotkeyReminder = NSTextField(labelWithString: "Press \(hotkeyDisplay) anywhere to summarize the focused window.")
        hotkeyReminder.font = NSFont.systemFont(ofSize: 13)
        hotkeyReminder.textColor = .secondaryLabelColor
        hotkeyReminder.maximumNumberOfLines = 2
        hotkeyReminder.preferredMaxLayoutWidth = 480
        stack.addArrangedSubview(hotkeyReminder)

        let footer = NSTextField(wrappingLabelWithString:
            "Summaries and suggestions are stored to improve Blink; "
            + "screenshots are not retained."
        )
        footer.font = NSFont.systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor
        footer.maximumNumberOfLines = 0
        footer.preferredMaxLayoutWidth = 480
        stack.addArrangedSubview(footer)

        host.addSubview(stack)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: host.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.topAnchor.constraint(equalTo: host.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor),
        ])
        return host
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

    private func startSubscriptions() {
        statusSubscription = coordinator.statusSubject
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                MainActor.assumeIsolated {
                    self?.statusLabel?.stringValue = text
                }
            }
        modelSubscription = runtimeStore.$model
            .receive(on: RunLoop.main)
            .sink { [weak self] selected in
                MainActor.assumeIsolated {
                    guard let self, let popup = self.modelPopup else { return }
                    if popup.itemTitle(at: popup.indexOfSelectedItem) != selected {
                        self.rebuildModelPopup(popup, current: selected)
                    }
                }
            }
        reasoningSubscription = runtimeStore.$thinkingLevel
            .receive(on: RunLoop.main)
            .sink { [weak self] level in
                MainActor.assumeIsolated {
                    guard let self, let popup = self.reasoningPopup else { return }
                    let target = ReasoningLevels.title(for: level)
                    if popup.itemTitle(at: popup.indexOfSelectedItem) != target {
                        popup.selectItem(withTitle: target)
                    }
                }
            }
    }

    private func stopSubscriptions() {
        statusSubscription = nil
        modelSubscription = nil
        reasoningSubscription = nil
    }

    // MARK: - Actions

    @objc private func summarize() {
        // The control window is currently frontmost (the user just clicked
        // a button in it). Summarizing right now would capture Blink itself.
        // Activate the app the user was in before opening the window, give
        // AppKit a tick to actually shift focus, then trigger the same path
        // the global hotkey takes.
        if let prev = previousFrontmost,
           !prev.isTerminated,
           prev.processIdentifier != NSRunningApplication.current.processIdentifier {
            prev.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                let now = DispatchTime.now()
                self?.coordinator.summarizeFrontmostWindow(pressedAt: now, summarizeEnteredAt: now)
            }
        } else {
            let now = DispatchTime.now()
            coordinator.summarizeFrontmostWindow(pressedAt: now, summarizeEnteredAt: now)
        }
    }

    @objc private func modelChanged(_ sender: NSPopUpButton) {
        guard let title = sender.titleOfSelectedItem else { return }
        runtimeStore.model = title
    }

    @objc private func reasoningChanged(_ sender: NSPopUpButton) {
        guard let title = sender.titleOfSelectedItem else { return }
        runtimeStore.thinkingLevel = ReasoningLevels.value(for: title)
    }

    @objc private func openSettings() {
        onShowSettings()
    }

    func windowWillClose(_ notification: Notification) {
        stopSubscriptions()
    }

    // MARK: - NSToolbarDelegate

    nonisolated func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        MainActor.assumeIsolated { () -> NSToolbarItem? in
            switch itemIdentifier {
            case ToolbarID.summarize:
                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Summarize"
                item.paletteLabel = "Summarize"
                item.toolTip = "Summarize the previously-frontmost window."
                if #available(macOS 11.0, *) {
                    item.image = NSImage(
                        systemSymbolName: "sparkles",
                        accessibilityDescription: "Summarize"
                    )
                }
                item.target = self
                item.action = #selector(summarize)
                item.isBordered = true
                return item

            case ToolbarID.model:
                let popup = NSPopUpButton(frame: .zero, pullsDown: false)
                popup.controlSize = .small
                popup.target = self
                popup.action = #selector(modelChanged(_:))
                popup.toolTip = "Backend model used for summaries and replies."
                rebuildModelPopup(popup, current: runtimeStore.model)
                modelPopup = popup
                popup.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
                    popup.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
                    popup.heightAnchor.constraint(equalToConstant: 24),
                ])
                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Model"
                item.paletteLabel = "Model"
                item.view = popup
                return item

            case ToolbarID.reasoning:
                let popup = NSPopUpButton(frame: .zero, pullsDown: false)
                popup.controlSize = .small
                popup.target = self
                popup.action = #selector(reasoningChanged(_:))
                popup.toolTip = "How much the model thinks before answering."
                popup.addItems(withTitles: ReasoningLevels.titles)
                popup.selectItem(withTitle: ReasoningLevels.title(for: runtimeStore.thinkingLevel))
                reasoningPopup = popup
                popup.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
                    popup.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
                    popup.heightAnchor.constraint(equalToConstant: 24),
                ])
                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Reasoning"
                item.paletteLabel = "Reasoning"
                item.view = popup
                return item

            case ToolbarID.settings:
                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Settings"
                item.paletteLabel = "Settings"
                item.toolTip = "Open Settings (⌘,)"
                if #available(macOS 11.0, *) {
                    item.image = NSImage(
                        systemSymbolName: "gearshape",
                        accessibilityDescription: "Settings"
                    )
                }
                item.target = self
                item.action = #selector(openSettings)
                item.isBordered = true
                return item

            default:
                return nil
            }
        }
    }

    nonisolated func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarID.summarize, .flexibleSpace, ToolbarID.model, ToolbarID.reasoning, ToolbarID.settings]
    }

    nonisolated func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarID.summarize, ToolbarID.model, ToolbarID.reasoning, ToolbarID.settings, .flexibleSpace, .space]
    }
}
