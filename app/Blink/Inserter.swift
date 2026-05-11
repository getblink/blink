import AppKit
import ApplicationServices
import Foundation

/// Clipboard + Cmd+V insertion. Leaves the inserted text on the pasteboard so
/// that if Cmd+V doesn't land (no focused text field, AX denied, app refused),
/// the user can still recover via manual paste.
enum Inserter {
    enum InsertOutcome {
        case pasted
        case skippedNoTextTarget
    }

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
    ///     beat before the keystroke or the paste reaches Blink instead.
    ///   - completion: called on the main queue with success/failure.
    static func insert(
        text: String,
        activationDelay: TimeInterval = 0,
        completion: @escaping (Result<InsertOutcome, Error>) -> Void
    ) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay) {
            if shouldSkipPasteForFocusedElement() {
                completion(.success(.skippedNoTextTarget))
                return
            }
            do {
                try synthesizeCmdV()
            } catch {
                completion(.failure(error))
                return
            }
            completion(.success(.pasted))
        }
    }

    private static func shouldSkipPasteForFocusedElement() -> Bool {
        guard AXIsProcessTrusted(),
              let focused = FocusedContextCapture.systemWideFocusedElement() else {
            return false
        }
        return FocusedContextCapture.textTargetDecision(starting: focused) == .confidentNoTextTarget
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
