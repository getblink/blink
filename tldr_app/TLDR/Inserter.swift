import AppKit
import Foundation

/// Clipboard + Cmd+V insertion that restores the user's previous clipboard
/// contents after a short delay.
///
/// Default per `docs/` plan: save clipboard → set pasteboard → synthesize Cmd+V
/// via CGEventPost into the frontmost app → restore after the target has
/// consumed the paste. Works in nearly every text field. Direct AX insertion
/// (`AXUIElementSetAttributeValue`) is deferred until field evidence shows it
/// is needed.
enum Inserter {
    enum InsertError: LocalizedError {
        case eventPostFailed
        case noEventSource

        var errorDescription: String? {
            switch self {
            case .eventPostFailed: return "couldn't synthesize Cmd+V"
            case .noEventSource: return "CGEventSource creation failed"
            }
        }
    }

    /// - Parameters:
    ///   - text: the text to paste.
    ///   - activationDelay: how long to wait before posting Cmd+V. The
    ///     overlay restores the previous frontmost app on close, but
    ///     `NSRunningApplication.activate` lands asynchronously — give it a
    ///     beat before the keystroke or the paste reaches TLDR instead.
    ///   - restoreDelay: how long to wait before restoring the original
    ///     clipboard. 400ms is typically enough for the target app to consume.
    ///   - completion: called on the main queue with success/failure.
    static func insert(
        text: String,
        activationDelay: TimeInterval = 0,
        restoreDelay: TimeInterval = 0.4,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let pasteboard = NSPasteboard.general
        let savedItems = snapshot(pasteboard: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay) {
            do {
                try synthesizeCmdV()
            } catch {
                restore(pasteboard: pasteboard, items: savedItems)
                completion(.failure(error))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
                restore(pasteboard: pasteboard, items: savedItems)
            }
            completion(.success(()))
        }
    }

    // MARK: - Clipboard snapshot/restore

    private struct SavedItem {
        let types: [NSPasteboard.PasteboardType]
        let data: [NSPasteboard.PasteboardType: Data]
    }

    private static func snapshot(pasteboard: NSPasteboard) -> [SavedItem] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            var data: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let bytes = item.data(forType: type) {
                    data[type] = bytes
                }
            }
            return SavedItem(types: item.types, data: data)
        }
    }

    private static func restore(pasteboard: NSPasteboard, items: [SavedItem]) {
        // If the user's clipboard was empty before we overwrote it, leave our
        // paste content on the pasteboard rather than clearing to nothing —
        // clearing would be a surprise side-effect of the tool running.
        guard !items.isEmpty else { return }
        pasteboard.clearContents()
        let restored: [NSPasteboardItem] = items.map { saved in
            let pbItem = NSPasteboardItem()
            for type in saved.types {
                if let bytes = saved.data[type] {
                    pbItem.setData(bytes, forType: type)
                }
            }
            return pbItem
        }
        pasteboard.writeObjects(restored)
    }

    // MARK: - Cmd+V synthesis

    private static func synthesizeCmdV() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw InsertError.noEventSource
        }
        // Keycode 9 = V.
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else {
            throw InsertError.eventPostFailed
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }
}
