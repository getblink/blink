import AppKit
import Combine

/// Standalone control window. Single-glance action surface: large status
/// label, hotkey reminder, retention footer; configuration lives in the
/// Settings scene. Toolbar carries Summarize (primary action), Model and
/// Reasoning popups, and a Settings shortcut.
@MainActor
final class ControlWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate, LibraryStripDelegate {
    private let coordinator: BlinkCoordinator
    private let runtimeStore: RuntimeConfigStore
    private let hotkey: Hotkey
    private let onShowSettings: () -> Void

    private var window: NSWindow?
    private var statusLabel: NSTextField?
    private var modelPopup: NSPopUpButton?
    private var reasoningPopup: NSPopUpButton?
    // Tracked so we can light up the right cap when its modifier/key fires.
    private var keycaps: [(part: String, view: KeycapView)] = []
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var libraryStrip: LibraryStripView?
    private var libraryStripAddErrorLabel: NSTextField?

    private var statusSubscription: AnyCancellable?
    private var modelSubscription: AnyCancellable?
    private var reasoningSubscription: AnyCancellable?
    private var librarySubscription: AnyCancellable?

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
        hotkey: Hotkey,
        onShowSettings: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.runtimeStore = runtimeStore
        self.hotkey = hotkey
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
        // Skip reactivate when the user is mid-drag (dragging a file toward
        // the library strip). NSApp.activate during a drag can interrupt the
        // drag session on some macOS versions. We detect this via the most
        // recent draggingEntered timestamp from the strip.
        let dragAge = libraryStrip.map { Date().timeIntervalSince($0.lastDragEnteredAt) } ?? .infinity
        if dragAge > 1.0 {
            NSApp.activate(ignoringOtherApps: true)
        }
        // Re-show paths (menubar item, dock click, second show()) need to
        // tear down stale subscriptions before re-subscribing.
        stopSubscriptions()
        startSubscriptions()
        startKeyMonitor()
    }

    private func buildWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 160),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Blink"
        win.isReleasedWhenClosed = false
        win.delegate = self
        // Bumped to `.v2` to invalidate the stale taller frames users had
        // saved before the content-driven sizing landed. `setFrameAutosaveName`
        // returns `false` on first launch (nothing to restore), in which case
        // we center the window instead of leaving it parked at the screen's
        // bottom-left corner where the contentRect origin (0, 0) lands.
        let restoredFrame = win.setFrameAutosaveName("BlinkControl.v2")
        if #available(macOS 11.0, *) {
            win.toolbarStyle = .unified
        }
        win.titleVisibility = .hidden

        let toolbar = NSToolbar(identifier: "BlinkControlToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconAndLabel
        win.toolbar = toolbar

        let content = buildContent()
        win.contentView = content
        // Size the window to the natural fitting height of the content so
        // there's no dead vertical space under the footer copy.
        let target = content.fittingSize
        win.setContentSize(NSSize(width: max(target.width, 520), height: target.height))
        win.contentMinSize = NSSize(width: 480, height: target.height)
        if !restoredFrame {
            win.center()
        }
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

        // Hotkey row: each modifier/key rendered as a keycap badge so the
        // shortcut is the visual focal point. Sits above a smaller hint line
        // that explains what the shortcut does.
        let keycapRow = NSStackView()
        keycapRow.orientation = .horizontal
        keycapRow.alignment = .centerY
        keycapRow.spacing = 6
        // Required hugging keeps the row tight around its caps — without
        // this, the parent vertical stack stretches the row to its leading
        // width and `distribution = .fill` blows up the first cap.
        keycapRow.setHuggingPriority(.required, for: .horizontal)
        keycaps.removeAll()
        for part in hotkey.displayParts {
            let cap = KeycapView(label: part)
            keycapRow.addArrangedSubview(cap)
            keycaps.append((part: part, view: cap))
        }

        let hotkeyHint = NSTextField(labelWithString: "Press anywhere to summarize the focused window.")
        hotkeyHint.font = NSFont.systemFont(ofSize: 13)
        hotkeyHint.textColor = .secondaryLabelColor
        hotkeyHint.maximumNumberOfLines = 2
        hotkeyHint.preferredMaxLayoutWidth = 480

        let hotkeyBlock = NSStackView(views: [keycapRow, hotkeyHint])
        hotkeyBlock.orientation = .vertical
        hotkeyBlock.alignment = .leading
        hotkeyBlock.spacing = 8
        stack.addArrangedSubview(hotkeyBlock)

        // Attachment library strip — horizontally-scrolling file pill row.
        let strip = LibraryStripView()
        strip.delegate = self
        libraryStrip = strip
        stack.addArrangedSubview(strip)
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 0),
            strip.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: 0),
        ])
        // Sync current library state
        strip.update(
            entries: AttachmentLibrary.shared.entries,
            unavailableIDs: AttachmentLibrary.shared.unavailableIDs
        )

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
            // Equality pins the host's height to the stack's natural height
            // so the window content view shrinks to fit, no dead space below.
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        return host
    }

    /// A small rounded "keycap" badge that renders a single modifier or key
    /// glyph and animates between a resting and a pressed appearance. Stacked
    /// horizontally to display a hotkey (e.g. ⌃ ⌥ Space) as a row of visual
    /// keys rather than inline text.
    fileprivate final class KeycapView: NSView {
        private let field: NSTextField
        private var pressed: Bool = false

        init(label: String) {
            self.field = NSTextField(labelWithString: label)
            super.init(frame: .zero)

            field.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
            field.alignment = .center
            field.isBordered = false
            field.drawsBackground = false
            field.isEditable = false
            field.isSelectable = false
            field.translatesAutoresizingMaskIntoConstraints = false

            wantsLayer = true
            translatesAutoresizingMaskIntoConstraints = false
            layer?.cornerRadius = 6
            layer?.borderWidth = 0.5
            addSubview(field)

            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: 28),
                // Pin the cap's width to the glyph's intrinsic width plus 10pt
                // of horizontal padding on each side. Without this hard
                // equality the parent stack stretches the cap to fill the
                // leftover space — which is what made `⌃` span the window.
                widthAnchor.constraint(equalTo: field.widthAnchor, constant: 20),
                // Floor: keep narrow caps from collapsing below the cap's
                // height (so single-char glyphs still read as a square badge).
                widthAnchor.constraint(greaterThanOrEqualTo: heightAnchor),
                field.centerYAnchor.constraint(equalTo: centerYAnchor),
                field.centerXAnchor.constraint(equalTo: centerXAnchor),
            ])

            applyAppearance(animated: false)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("KeycapView not coder-compatible") }

        func setPressed(_ value: Bool) {
            guard pressed != value else { return }
            pressed = value
            applyAppearance(animated: true)
        }

        private func applyAppearance(animated: Bool) {
            let bg = pressed
                ? NSColor.systemBlue.withAlphaComponent(0.92).cgColor
                : NSColor.controlBackgroundColor.withAlphaComponent(0.7).cgColor
            let border = pressed
                ? NSColor.systemBlue.cgColor
                : NSColor.separatorColor.cgColor
            let textColor: NSColor = pressed ? .white : .labelColor

            let apply: () -> Void = { [weak self] in
                guard let self else { return }
                self.layer?.backgroundColor = bg
                self.layer?.borderColor = border
                self.field.textColor = textColor
            }
            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.12
                    ctx.allowsImplicitAnimation = true
                    apply()
                }
            } else {
                apply()
            }
        }
    }

    // MARK: - Live key-press feedback

    private func startKeyMonitor() {
        stopKeyMonitor()
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            // Global monitor fires when Blink is NOT frontmost — exactly the
            // case the user cares about, since the hotkey is global.
            MainActor.assumeIsolated { self?.handleKeyEvent(event) }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKeyEvent(event) }
            return event
        }
    }

    private func stopKeyMonitor() {
        if let token = globalKeyMonitor {
            NSEvent.removeMonitor(token)
            globalKeyMonitor = nil
        }
        if let token = localKeyMonitor {
            NSEvent.removeMonitor(token)
            localKeyMonitor = nil
        }
        // Reset everything to unpressed when monitoring stops so the next
        // show() doesn't briefly flash stale state from the prior session.
        for (_, cap) in keycaps { cap.setPressed(false) }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hotkeyKeyCode = UInt16(hotkey.keyCode)
        for (part, cap) in keycaps {
            if let modifier = Self.modifierFlag(forPart: part) {
                cap.setPressed(flags.contains(modifier))
            } else {
                // Non-modifier (the actual key) — track its keyDown/keyUp.
                // flagsChanged events don't carry a meaningful keyCode for
                // non-modifier caps, so we ignore them here.
                switch event.type {
                case .keyDown where event.keyCode == hotkeyKeyCode:
                    cap.setPressed(true)
                case .keyUp where event.keyCode == hotkeyKeyCode:
                    cap.setPressed(false)
                default:
                    break
                }
            }
        }
    }

    private static func modifierFlag(forPart part: String) -> NSEvent.ModifierFlags? {
        switch part {
        case "⌃": return .control
        case "⌥": return .option
        case "⇧": return .shift
        case "⌘": return .command
        case "fn": return .function
        default: return nil
        }
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
        librarySubscription = AttachmentLibrary.shared.$entries
            .combineLatest(AttachmentLibrary.shared.$unavailableIDs)
            .receive(on: RunLoop.main)
            .sink { [weak self] entries, unavailableIDs in
                MainActor.assumeIsolated {
                    self?.libraryStrip?.update(entries: entries, unavailableIDs: unavailableIDs)
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
        librarySubscription = nil
    }

    // MARK: - LibraryStripDelegate

    func libraryStripDidDrop(urls: [URL]) {
        let proxyConfig = RuntimeEnvironment.proxyConfig()
        for url in urls {
            do {
                let result = try AttachmentLibrary.shared.addFile(at: url)
                if result.largeSizeWarning {
                    // Brief status message; doesn't block the add
                    coordinator.statusSubject.send("Large file (>25 MB) staged — may slow Blink")
                }
                if let cfg = proxyConfig {
                    AttachmentLibrary.shared.scheduleDescription(entryID: result.entry.id, proxyConfig: cfg)
                }
            } catch AttachmentError.fileTooLarge(let size) {
                let mb = size / (1024 * 1024)
                coordinator.statusSubject.send("File too large (\(mb) MB) — 100 MB limit")
            } catch {
                coordinator.statusSubject.send("Couldn't add file: \(error.localizedDescription)")
            }
        }
    }

    func libraryStripDragEntered() {
        // lastDragEnteredAt is tracked by the strip itself; nothing extra to do here
    }

    func libraryStripDidRequestRemove(id: String) {
        AttachmentLibrary.shared.removeEntry(id: id)
    }

    func libraryStripDidRequestShowInFinder(id: String) {
        guard let entry = AttachmentLibrary.shared.entries.first(where: { $0.id == id }),
              let url = AttachmentLibrary.shared.resolveURLSync(for: entry) else {
            coordinator.statusSubject.send("File unavailable")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func libraryStripDidRequestRetry(id: String) {
        guard let cfg = RuntimeEnvironment.proxyConfig() else { return }
        AttachmentLibrary.shared.retryDescription(entryID: id, proxyConfig: cfg)
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
        stopKeyMonitor()
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
