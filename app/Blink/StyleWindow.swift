import AppKit
import Combine

/// Standalone Style window. Builds an `NSToolbar` with a Reset shortcut
/// and embeds a shared `StylePaneController` so the Settings ▸ Style pane
/// renders the same layout.
@MainActor
final class StyleWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private let runtimeStore: RuntimeConfigStore
    private var window: NSWindow?
    private var pane: StylePaneController?

    private enum ToolbarItem {
        static let reset = NSToolbarItem.Identifier("BlinkStyleReset")
    }

    init(runtimeStore: RuntimeConfigStore) {
        self.runtimeStore = runtimeStore
    }

    func show() {
        if window == nil { buildWindow() }
        pane?.startSubscription()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Blink Style"
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.setFrameAutosaveName("BlinkStyle")

        let pane = StylePaneController(runtimeStore: runtimeStore)
        self.pane = pane
        win.contentView = pane.contentView

        let toolbar = NSToolbar(identifier: "BlinkStyleToolbar")
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.delegate = self
        win.toolbar = toolbar
        if #available(macOS 11.0, *) {
            win.toolbarStyle = .unified
        }
        win.titleVisibility = .visible

        pane.contentView.layoutSubtreeIfNeeded()
        window = win
    }

    func windowWillClose(_ notification: Notification) {
        pane?.stopSubscription()
    }

    // MARK: - NSToolbarDelegate

    nonisolated func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        MainActor.assumeIsolated { () -> NSToolbarItem? in
            guard itemIdentifier == ToolbarItem.reset else { return nil }
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Reset"
            item.paletteLabel = "Reset"
            item.toolTip = "Restore the knobs without clearing About me."
            if #available(macOS 11.0, *) {
                item.image = NSImage(
                    systemSymbolName: "arrow.counterclockwise",
                    accessibilityDescription: "Reset"
                )
            }
            item.target = pane
            item.action = #selector(StylePaneController.reset)
            item.isBordered = true
            return item
        }
    }

    nonisolated func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, ToolbarItem.reset]
    }

    nonisolated func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, ToolbarItem.reset]
    }
}
