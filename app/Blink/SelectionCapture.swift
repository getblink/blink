import AppKit
import ApplicationServices
import Foundation

/// Best-effort harvest of the user's currently-selected text at the moment
/// of a capture. Runs synchronously on the capture queue *before* Blink's
/// overlay activates so the AX query and any synthesized Cmd+C lands on
/// the source app, not Blink's own panel.
///
/// AX-first via `kAXSelectedTextAttribute`. When AX is empty and the
/// focused element is a shape where AX selection is known unreliable
/// (Chromium contenteditable, Electron, Safari article body), fall back
/// to synthetic Cmd+C with pasteboard snapshot/restore. Terminal bundles
/// are excluded from the fallback — Cmd+C there is SIGINT, not copy.
enum SelectionCapture {
    struct Selection {
        let text: String
        let source: Source
        /// True when `text` was truncated against `maxChars`.
        let truncated: Bool
        /// Character count of the *original* selection before truncation.
        let originalCharCount: Int
    }

    enum Source: String {
        case ax = "ax"
        case syntheticCopy = "synthetic_copy"
    }

    /// 8KB worth of characters. The ceiling protects model context against
    /// users selecting a whole article; a follow-up that needs the full
    /// document should attach a file instead.
    static let defaultMaxChars = 8192

    /// Synchronous capture. Intended to be called from the capture queue
    /// inside `BlinkCoordinator.captureFrame`, immediately after the
    /// screenshot lands and before any main-thread overlay dispatch.
    /// Returns nil when AX is denied, no focused element, or no selection
    /// could be resolved.
    static func captureSync(maxChars: Int = defaultMaxChars) -> Selection? {
        guard AXIsProcessTrusted() else { return nil }
        guard let context = focusedElementContext() else { return nil }

        if let raw = readAXSelection(context.element),
           let selection = sanitize(raw, source: .ax, maxChars: maxChars) {
            return selection
        }
        guard shouldTrySyntheticCopy(role: context.role, bundleID: context.bundleID) else {
            return nil
        }
        guard let raw = synthesizeCopyAndRead(maxWaitMS: 120) else { return nil }
        return sanitize(raw, source: .syntheticCopy, maxChars: maxChars)
    }

    // MARK: - AX

    private struct FocusedContext {
        let element: AXUIElement
        let role: String?
        let bundleID: String?
    }

    private static func focusedElementContext() -> FocusedContext? {
        guard let focused = FocusedContextCapture.systemWideFocusedElement() else {
            return nil
        }
        AXUIElementSetMessagingTimeout(focused, 0.1)
        let role = readRole(focused)
        var pid: pid_t = 0
        var bundleID: String?
        if AXUIElementGetPid(focused, &pid) == .success,
           let app = NSRunningApplication(processIdentifier: pid) {
            bundleID = app.bundleIdentifier
        }
        return FocusedContext(element: focused, role: role, bundleID: bundleID)
    }

    private static func readRole(_ element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &ref
        ) == .success, let raw = ref as? String else { return nil }
        return raw.hasPrefix("AX") ? String(raw.dropFirst(2)) : raw
    }

    private static func readAXSelection(_ element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &ref
        ) == .success, let raw = ref as? String, !raw.isEmpty else {
            return nil
        }
        return raw
    }

    // MARK: - Synthetic Cmd+C fallback

    /// Gate the fallback narrowly:
    /// - Terminals get hard-skipped (Cmd+C is SIGINT, not copy).
    /// - Chromium-family bundles get the fallback because contenteditable
    ///   AX selection is broken there.
    /// - Otherwise, only roles that plausibly hold a hidden selection:
    ///   text inputs, static text (Safari paragraphs), web areas / groups.
    private static func shouldTrySyntheticCopy(role: String?, bundleID: String?) -> Bool {
        if let bundleID, FocusedContextCapture.terminalBundles.contains(bundleID) {
            return false
        }
        if let bundleID,
           FocusedContextCapture.chromiumBundlePrefixes.contains(where: { bundleID.hasPrefix($0) }) {
            return true
        }
        guard let role else { return false }
        if FocusedContextCapture.roleLooksLikeTextInput(role) {
            return true
        }
        switch role {
        case "StaticText", "WebArea", "Group", "ScrollArea":
            return true
        default:
            return false
        }
    }

    /// Snapshot the pasteboard, post Cmd+C, poll `changeCount` for up to
    /// `maxWaitMS`, then read the new string and restore the prior contents.
    /// If `changeCount` doesn't move within the window, the focused app
    /// had nothing to copy (no selection) and we leave the pasteboard
    /// untouched.
    private static func synthesizeCopyAndRead(maxWaitMS: Int) -> String? {
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboard(pasteboard)
        let initialChangeCount = pasteboard.changeCount

        guard postSyntheticCmdC() else { return nil }

        let pollIntervalMS = 10
        var elapsedMS = 0
        while elapsedMS < maxWaitMS {
            Thread.sleep(forTimeInterval: TimeInterval(pollIntervalMS) / 1000.0)
            elapsedMS += pollIntervalMS
            if pasteboard.changeCount != initialChangeCount {
                break
            }
        }
        if pasteboard.changeCount == initialChangeCount {
            // Nothing was selected; pasteboard untouched.
            return nil
        }
        let copied = pasteboard.string(forType: .string)
        restorePasteboard(pasteboard, snapshot: snapshot)
        return copied
    }

    private static func postSyntheticCmdC() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }

    private static func snapshotPasteboard(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        // Items returned from `pasteboardItems` are tied to the current
        // pasteboard generation. Deep-copy the data into fresh items so
        // they survive the `clearContents` we'll do during restore.
        guard let items = pasteboard.pasteboardItems else { return [] }
        var snapshot: [NSPasteboardItem] = []
        for item in items {
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            snapshot.append(copy)
        }
        return snapshot
    }

    private static func restorePasteboard(
        _ pasteboard: NSPasteboard,
        snapshot: [NSPasteboardItem]
    ) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }
        // Tag the restored payload with the nspasteboard.org transient
        // type so clipboard managers (Maccy, Paste, Raycast) don't record
        // the restore as a fresh user copy.
        let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        if let first = snapshot.first {
            first.setData(Data(), forType: transientType)
        }
        pasteboard.writeObjects(snapshot)
    }

    // MARK: - Sanitization

    /// Strip control characters (preserving newlines and tabs) and trim
    /// outer whitespace. Truncate to `maxChars` characters; return nil
    /// when the result is empty.
    private static func sanitize(
        _ raw: String,
        source: Source,
        maxChars: Int
    ) -> Selection? {
        let scalars = raw.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar)
        }
        let cleaned = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        if cleaned.count <= maxChars {
            return Selection(
                text: cleaned,
                source: source,
                truncated: false,
                originalCharCount: cleaned.count
            )
        }
        let truncated = String(cleaned.prefix(maxChars))
        return Selection(
            text: truncated,
            source: source,
            truncated: true,
            originalCharCount: cleaned.count
        )
    }
}

extension SelectionCapture.Selection {
    /// Envelope payload. Honors content-retention consent: when retention
    /// is disabled, `text` is dropped and replaced with `text_redacted=true`.
    func uploadPayload(allowContentRetention: Bool) -> [String: Any] {
        var payload: [String: Any] = [
            "source": source.rawValue,
            "char_count": originalCharCount,
            "truncated": truncated,
        ]
        if allowContentRetention {
            payload["text"] = text
        } else {
            payload["text_redacted"] = true
        }
        return payload
    }
}
