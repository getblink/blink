import AppKit
import Sparkle
import SwiftUI

/// Tabbed Settings scene (`⌘,`). Toolbar-tab style à la System Settings.
///
/// The shell stays AppKit (NSWindow + NSToolbar in `.preference` style) because
/// Blink's app entry point is `NSApplicationMain` + `NSApplicationDelegate`,
/// not a SwiftUI `App`. Each pane *body* is a SwiftUI view, hosted via
/// `NSHostingView`, so the layout uses `Form { Section { LabeledContent } }`
/// rhythm and bindings against `RuntimeConfigStore` instead of hand-rolled
/// `NSPopUpButton` change handlers + Combine sinks.
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
    private var activeHostingView: NSView?

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

    func show(initialPane: Pane = .general) {
        if window == nil { buildWindow() }
        select(pane: initialPane)
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
        teardownActivePane()
        activePane = pane
        window?.title = pane.title
        if #available(macOS 11.0, *) {
            window?.toolbar?.selectedItemIdentifier = pane.toolbarIdentifier
        }
        let host = hostingView(for: pane)
        host.translatesAutoresizingMaskIntoConstraints = false
        paneContainer.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: paneContainer.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: paneContainer.trailingAnchor),
            host.topAnchor.constraint(equalTo: paneContainer.topAnchor),
            host.bottomAnchor.constraint(equalTo: paneContainer.bottomAnchor),
        ])
        activeHostingView = host
    }

    /// Pane swap must release the prior `NSHostingView` (not just remove it
    /// from its superview). Without dropping the strong ref, the previous
    /// SwiftUI view's `.onDisappear` may not fire promptly — and the
    /// Permissions pane's `Timer.publish(...).autoconnect()` keeps polling.
    private func teardownActivePane() {
        activeHostingView?.removeFromSuperview()
        activeHostingView = nil
    }

    // MARK: - Pane factory

    private func hostingView(for pane: Pane) -> NSView {
        if #available(macOS 14.0, *) {
            switch pane {
            case .general:
                return NSHostingView(rootView: GeneralSettingsView(
                    runtimeStore: runtimeStore,
                    hotkeyDisplay: hotkeyDisplay
                ))
            case .style:
                return NSHostingView(rootView: StyleSettingsView(
                    runtimeStore: runtimeStore
                ))
            case .permissions:
                return NSHostingView(rootView: PermissionsSettingsView(
                    onShowPermissions: onShowPermissions,
                    onResetPermissions: onResetPermissions
                ))
            case .advanced:
                let updateAction: (() -> Void)? = updaterController.map { controller in
                    { [weak controller] in controller?.checkForUpdates(nil) }
                }
                return NSHostingView(rootView: AdvancedSettingsView(
                    onOpenRuns: onOpenRuns,
                    onOpenRuntime: onOpenRuntime,
                    onCheckForUpdates: updateAction
                ))
            }
        } else {
            // Deployment target is macOS 14 (per project.pbxproj), so this
            // path shouldn't fire — but keep a graceful empty view rather
            // than crashing if a future drop changes the target.
            let placeholder = NSTextField(labelWithString: "Requires macOS 14.0 or later.")
            placeholder.alignment = .center
            return placeholder
        }
    }

    // MARK: - Actions

    @objc private func selectPane(_ sender: NSToolbarItem) {
        guard let pane = Pane.allCases.first(where: { $0.toolbarIdentifier == sender.itemIdentifier }) else { return }
        select(pane: pane)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        teardownActivePane()
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
            // Leave `isBordered = false` (the default). In `.preference` toolbar
            // style, a bordered item shrinks the hit area to the image bounds
            // and pushes the label outside the clickable region; the unbordered
            // style lets the toolbar render the standard tab where the entire
            // icon-plus-label column is one hit target.
            return item
        }
    }
}
