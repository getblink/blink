import AppKit
import ApplicationServices
import Foundation

/// Clipboard + Cmd+V insertion. Leaves the inserted content on the pasteboard
/// so that if Cmd+V doesn't land (no focused text field, AX denied, app
/// refused), the user can still recover via manual paste.
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

    /// Wait between the text paste and the file paste in the two-stage flow.
    /// Long enough for the destination's paste handler to consume stage 1
    /// before we swap the pasteboard out from under it.
    private static let interStageDelay: TimeInterval = 0.12

    /// Wait between the stage-2 Cmd+V and restoring the recovery payload.
    /// Larger than `interStageDelay` because some destinations (Gmail's
    /// file-upload handler in particular) take >120ms to read the pasteboard
    /// after the keystroke arrives. A short race here means the file paste
    /// silently no-ops.
    private static let recoveryWritebackDelay: TimeInterval = 0.25

    /// - Parameters:
    ///   - text: the text to paste.
    ///   - fileURLs: optional file URLs to include alongside the text. When
    ///     non-empty, paste is split into two Cmd+V keystrokes: text first,
    ///     then files. Web compose surfaces (Gmail, Slack web) treat any paste
    ///     containing a file as a file-only paste and drop the text — a
    ///     combined multi-item paste would lose one half. Native Mail.app
    ///     handles both stages without issue.
    ///   - activationDelay: how long to wait before posting the first Cmd+V.
    ///     The overlay restores the previous frontmost app on close, but
    ///     `NSRunningApplication.activate` lands asynchronously — give it a
    ///     beat before the keystroke or the paste reaches Blink instead.
    ///   - completion: called on the main queue with success/failure.
    static func insert(
        text: String,
        fileURLs: [URL] = [],
        activationDelay: TimeInterval = 0,
        previousApp: NSRunningApplication? = nil,
        completion: @escaping (Result<InsertOutcome, Error>) -> Void
    ) {
        // When the overlay is pinned (or otherwise stays key during the
        // paste), the synthesized Cmd+V would land in Blink itself. Force
        // focus back to the prior frontmost app before the activation
        // delay so the paste reaches its intended destination.
        if let previousApp, !previousApp.isActive {
            previousApp.activate(options: [])
        }
        if fileURLs.isEmpty {
            insertTextOnly(text: text, activationDelay: activationDelay, completion: completion)
        } else if text.isEmpty {
            insertFilesOnly(fileURLs: fileURLs, activationDelay: activationDelay, completion: completion)
        } else {
            insertTwoStage(text: text, fileURLs: fileURLs, activationDelay: activationDelay, completion: completion)
        }
    }

    private static func insertTextOnly(
        text: String,
        activationDelay: TimeInterval,
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

    private static func insertFilesOnly(
        fileURLs: [URL],
        activationDelay: TimeInterval,
        completion: @escaping (Result<InsertOutcome, Error>) -> Void
    ) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(fileURLs.map { $0 as NSURL })

        DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay) {
            // Files-only: don't gate on text-target detection — destinations
            // like Mail's attachment well aren't text fields by AX's reckoning.
            do {
                try synthesizeCmdV()
            } catch {
                completion(.failure(error))
                return
            }
            completion(.success(.pasted))
        }
    }

    private static func insertTwoStage(
        text: String,
        fileURLs: [URL],
        activationDelay: TimeInterval,
        completion: @escaping (Result<InsertOutcome, Error>) -> Void
    ) {
        let pasteboard = NSPasteboard.general
        // Stage 1: text only.
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay) {
            if shouldSkipPasteForFocusedElement() {
                // Restore the combined payload so the user can manually
                // recover both text and files in one paste.
                writeCombined(text: text, fileURLs: fileURLs)
                completion(.success(.skippedNoTextTarget))
                return
            }
            do {
                try synthesizeCmdV()
            } catch {
                writeCombined(text: text, fileURLs: fileURLs)
                completion(.failure(error))
                return
            }

            // Stage 2: swap to files-only, then post second Cmd+V.
            DispatchQueue.main.asyncAfter(deadline: .now() + interStageDelay) {
                // Focus can shift in the 120ms window (autocomplete popup,
                // reflow stealing focus, user click). If it did, swap to a
                // files-only pasteboard so manual Cmd+V recovers the
                // attachments without duplicating the already-pasted text.
                if shouldSkipPasteForFocusedElement() {
                    pasteboard.clearContents()
                    pasteboard.writeObjects(fileURLs.map { $0 as NSURL })
                    completion(.success(.pasted))
                    return
                }
                pasteboard.clearContents()
                pasteboard.writeObjects(fileURLs.map { $0 as NSURL })
                do {
                    try synthesizeCmdV()
                } catch {
                    writeCombined(text: text, fileURLs: fileURLs)
                    completion(.failure(error))
                    return
                }
                // After stage 2's paste handler has had a chance to consume
                // the files, restore the combined payload for manual recovery.
                DispatchQueue.main.asyncAfter(deadline: .now() + recoveryWritebackDelay) {
                    writeCombined(text: text, fileURLs: fileURLs)
                    completion(.success(.pasted))
                }
            }
        }
    }

    private static func writeCombined(text: String, fileURLs: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if fileURLs.isEmpty {
            pasteboard.setString(text, forType: .string)
            return
        }
        let textItem = NSPasteboardItem()
        textItem.setString(text, forType: .string)
        var objects: [NSPasteboardWriting] = [textItem]
        objects.append(contentsOf: fileURLs.map { $0 as NSURL })
        pasteboard.writeObjects(objects)
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
