import AppKit
import Combine

/// Standalone control window for Blink. Mirrors the menubar surface so the
/// user can keep the app reachable when the menubar isn't visible
/// (auto-hide, fullscreen apps). Auto-shown on launch; reachable via Dock
/// click and the menubar's "Open Blink Window…" item.
@MainActor
final class ControlWindowController: NSObject, NSWindowDelegate {
    private let coordinator: BlinkCoordinator
    private let runtimeStore: RuntimeConfigStore
    private let hotkeyDisplay: String
    private let onShowPermissions: () -> Void
    /// `nil` when Sparkle isn't configured — the button is omitted entirely
    /// rather than shown disabled, matching the menubar item's gating.
    private let onCheckForUpdates: (() -> Void)?

    private var window: NSWindow?
    private var statusLabel: NSTextField?
    private var modelPopup: NSPopUpButton?
    private var thinkingPopup: NSPopUpButton?
    private var soundsCheckbox: NSButton?
    private var styleWindowController: StyleWindowController?

    private var statusSubscription: AnyCancellable?
    private var modelSubscription: AnyCancellable?
    private var thinkingSubscription: AnyCancellable?
    private var soundsSubscription: AnyCancellable?

    private static let thinkingTitles: [String] = ["Default", "Low", "Medium", "High"]
    private static func thinkingTitle(for level: String?) -> String {
        switch level?.lowercased() {
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        default: return "Default"
        }
    }
    private static func thinkingValue(for title: String) -> String? {
        switch title {
        case "Low": return "low"
        case "Medium": return "medium"
        case "High": return "high"
        default: return nil
        }
    }

    /// The app that was frontmost just before this window took focus, so the
    /// "Summarize" button targets *that* app rather than Blink itself.
    /// Captured on `windowDidBecomeKey`; consumed on Summarize click.
    private weak var previousFrontmost: NSRunningApplication?

    init(
        coordinator: BlinkCoordinator,
        runtimeStore: RuntimeConfigStore,
        hotkeyDisplay: String,
        onShowPermissions: @escaping () -> Void,
        onCheckForUpdates: (() -> Void)?
    ) {
        self.coordinator = coordinator
        self.runtimeStore = runtimeStore
        self.hotkeyDisplay = hotkeyDisplay
        self.onShowPermissions = onShowPermissions
        self.onCheckForUpdates = onCheckForUpdates
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
        // tear down stale subscriptions before re-subscribing — otherwise
        // we replay current values for no reason and rely on AnyCancellable
        // reassignment to dealloc the prior sink.
        stopSubscriptions()
        startSubscriptions()
    }

    private func buildWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Blink"
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // 1. Status row.
        let status = NSTextField(labelWithString: coordinator.statusSubject.value)
        status.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        statusLabel = status
        stack.addArrangedSubview(self.row(label: "Status", control: status))

        // 2. Summarize button (large primary).
        // Note: deliberately no `keyEquivalent = "\r"` — when the control
        // window is key and the user hits Return, the captured "frontmost
        // window" would be Blink itself, which is wrong. The user's intent
        // is "summarize the *previous* app." The hotkey path handles that
        // correctly; this button covers the click case.
        let summarize = NSButton(
            title: "Summarize frontmost window",
            target: self,
            action: #selector(summarize)
        )
        summarize.bezelStyle = .rounded
        summarize.controlSize = .large
        stack.addArrangedSubview(summarize)

        // 3. Hotkey display.
        stack.addArrangedSubview(self.row(
            label: "Hotkey",
            control: NSTextField(labelWithString: hotkeyDisplay)
        ))

        // 4. Model picker.
        let popup = NSPopUpButton()
        popup.target = self
        popup.action = #selector(modelChanged)
        rebuildModelPopup(popup, current: runtimeStore.model)
        modelPopup = popup
        stack.addArrangedSubview(self.row(label: "Model", control: popup))

        // 5. Reasoning level picker. "Default" sends no override and lets the
        // server pick per-model; the rest map to lowercase values the server
        // allowlists.
        let thinking = NSPopUpButton()
        thinking.target = self
        thinking.action = #selector(thinkingChanged)
        thinking.addItems(withTitles: Self.thinkingTitles)
        thinking.selectItem(withTitle: Self.thinkingTitle(for: runtimeStore.thinkingLevel))
        thinkingPopup = thinking
        stack.addArrangedSubview(self.row(label: "Reasoning", control: thinking))

        // 6. Sounds checkbox.
        let sounds = NSButton(checkboxWithTitle: "Play sounds", target: self, action: #selector(soundsToggled))
        sounds.state = runtimeStore.soundsEnabled ? .on : .off
        soundsCheckbox = sounds
        stack.addArrangedSubview(sounds)

        // 7. Action buttons.
        let runsButton = NSButton(title: "Open runs folder", target: self, action: #selector(openRunsFolder))
        runsButton.bezelStyle = .rounded
        let runtimeButton = NSButton(title: "Open ~/.blink", target: self, action: #selector(openRuntimeFolder))
        runtimeButton.bezelStyle = .rounded
        let permsButton = NSButton(title: "Permissions…", target: self, action: #selector(openPermissions))
        permsButton.bezelStyle = .rounded
        let resetPermsButton = NSButton(title: "Reset Permissions…", target: self, action: #selector(resetPermissions))
        resetPermsButton.bezelStyle = .rounded
        let styleButton = NSButton(title: "Style…", target: self, action: #selector(openStyle))
        styleButton.bezelStyle = .rounded
        var rowViews: [NSView] = [runsButton, runtimeButton, styleButton, permsButton, resetPermsButton]
        if onCheckForUpdates != nil {
            let updateButton = NSButton(title: "Check for Updates…", target: self, action: #selector(checkForUpdates))
            updateButton.bezelStyle = .rounded
            rowViews.append(updateButton)
        }
        let buttonRow = NSStackView(views: rowViews)
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        stack.addArrangedSubview(buttonRow)

        // 8. Retention footer.
        let footer = NSTextField(wrappingLabelWithString:
            "Summaries and suggestions are stored to improve Blink; "
            + "screenshots are not retained."
        )
        footer.font = NSFont.systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor
        footer.maximumNumberOfLines = 0
        stack.addArrangedSubview(footer)

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            footer.widthAnchor.constraint(equalToConstant: 480 - 48),
        ])
        win.contentView = content
        // Pin a minimum size so the user can't shrink the window enough to
        // clip the footer / buttons. fittingSize after the constraints
        // are applied gives us the natural intrinsic height of the stack.
        content.layoutSubtreeIfNeeded()
        win.contentMinSize = NSSize(
            width: 480,
            height: max(stack.fittingSize.height, 360)
        )
        window = win
    }

    private func row(label: String, control: NSView) -> NSView {
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

    private func startSubscriptions() {
        // All three publishers fire on main: coordinator's status() dispatches
        // via DispatchQueue.main.async, and RuntimeConfigStore is @MainActor.
        // No Task hop needed — touching @MainActor state directly here.
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
        thinkingSubscription = runtimeStore.$thinkingLevel
            .receive(on: RunLoop.main)
            .sink { [weak self] level in
                MainActor.assumeIsolated {
                    guard let self, let popup = self.thinkingPopup else { return }
                    let target = Self.thinkingTitle(for: level)
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
    }

    private func stopSubscriptions() {
        statusSubscription = nil
        modelSubscription = nil
        thinkingSubscription = nil
        soundsSubscription = nil
    }

    @objc private func summarize() {
        // The control window is currently frontmost (the user just clicked
        // a button in it). Summarizing right now would capture Blink itself.
        // Activate the app the user was in before opening the window, give
        // AppKit a tick to actually shift focus, then trigger the same path
        // the global hotkey takes. Mirrors the activation-delay pattern used
        // by Inserter for paste-back.
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

    @objc private func thinkingChanged(_ sender: NSPopUpButton) {
        guard let title = sender.titleOfSelectedItem else { return }
        runtimeStore.thinkingLevel = Self.thinkingValue(for: title)
    }

    @objc private func soundsToggled(_ sender: NSButton) {
        runtimeStore.soundsEnabled = (sender.state == .on)
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

    @objc private func checkForUpdates() {
        onCheckForUpdates?()
    }

    @objc private func openStyle() {
        if styleWindowController == nil {
            styleWindowController = StyleWindowController(runtimeStore: runtimeStore)
        }
        styleWindowController?.show()
    }

    /// Mirror of `app/scripts/reset_tcc.sh` — clears every TCC service
    /// the app touches so the next launch re-triggers the system prompts.
    /// In-process resets don't apply to the currently-running process, so
    /// we offer to quit on success.
    @objc private func resetPermissions() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.henryz2004.blink"

        let confirm = NSAlert()
        confirm.messageText = "Reset Blink permissions?"
        confirm.informativeText = """
            This clears Accessibility, Screen Recording, Input Monitoring, \
            and related grants for \(bundleID). You'll be re-prompted on \
            next launch. Blink should be quit and relaunched for the reset \
            to take effect.
            """
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Reset")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let services = [
            "Accessibility",
            "ListenEvent",
            "PostEvent",
            "ScreenCapture",
            "SystemPolicyAllFiles",
            "AppleEvents",
        ]
        var failures: [String] = []
        for service in services {
            let proc = Process()
            proc.launchPath = "/usr/bin/tccutil"
            proc.arguments = ["reset", service, bundleID]
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            do {
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus != 0 {
                    failures.append(service)
                }
            } catch {
                failures.append(service)
            }
        }

        let result = NSAlert()
        if failures.isEmpty {
            result.messageText = "Permissions reset"
            result.informativeText = "Quit Blink now and relaunch to re-grant permissions."
            result.alertStyle = .informational
        } else {
            result.messageText = "Reset finished with errors"
            result.informativeText = "tccutil failed for: \(failures.joined(separator: ", "))."
            result.alertStyle = .warning
        }
        result.addButton(withTitle: "Quit Blink")
        result.addButton(withTitle: "Later")
        if result.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        stopSubscriptions()
    }
}
