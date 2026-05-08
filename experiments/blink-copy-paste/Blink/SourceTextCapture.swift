import AppKit
import ApplicationServices
import Foundation

/// Best-effort exact source-text capture for the source hotkey.
///
/// Source screenshots remain the durable fallback, but text selections should
/// not have to go through OCR just to preserve paragraph breaks.
enum SourceTextCapture {
    private struct SavedPasteboardItem {
        let types: [NSPasteboard.PasteboardType]
        let data: [NSPasteboard.PasteboardType: Data]
    }

    private static let defaultMaxChars = 8000
    private static let pollInterval: TimeInterval = 0.02

    static func capture(
        maxChars: Int = defaultMaxChars,
        copyTimeout: TimeInterval = 0.6
    ) -> [String: Any] {
        let startedAt = Date()
        let startedPerf = ProcessInfo.processInfo.systemUptime
        var warnings: [String] = []

        guard AXIsProcessTrusted() else {
            warnings.append("accessibility_not_trusted_for_source_text")
            return payload(
                status: "no_text",
                method: "accessibility_untrusted",
                text: "",
                maxChars: maxChars,
                startedAt: startedAt,
                startedPerf: startedPerf,
                warnings: warnings
            )
        }

        let axResult = readAXSelectedText()
        warnings.append(contentsOf: axResult.warnings)
        if let text = axResult.text {
            return payload(
                status: "ok",
                method: "ax_selected_text",
                text: text,
                maxChars: maxChars,
                startedAt: startedAt,
                startedPerf: startedPerf,
                warnings: warnings
            )
        }

        let pasteboard = NSPasteboard.general
        let savedItems = snapshot(pasteboard: pasteboard)
        let originalChangeCount = pasteboard.changeCount
        let restoreStartedPerf = ProcessInfo.processInfo.systemUptime
        defer {
            restore(pasteboard: pasteboard, items: savedItems)
            let restoreMS = durationMS(since: restoreStartedPerf)
            if restoreMS > 80 {
                NSLog("[blink] source clipboard restore took %.2fms", restoreMS)
            }
        }

        do {
            try synthesizeCmdC()
        } catch {
            warnings.append("cmd_c_failed:\(error.localizedDescription)")
            return payload(
                status: "no_text",
                method: "cmd_c",
                text: "",
                maxChars: maxChars,
                startedAt: startedAt,
                startedPerf: startedPerf,
                warnings: warnings
            )
        }

        // This timeout is intentionally a little conservative. If an app
        // processes Cmd+C after we restore, that late copy can still replace
        // the user's clipboard; waiting here lowers that race without making
        // source capture feel stuck.
        let deadline = Date().addingTimeInterval(copyTimeout)
        var copiedText: String?
        repeat {
            Thread.sleep(forTimeInterval: pollInterval)
            guard pasteboard.changeCount != originalChangeCount else { continue }
            let text = pasteboard.string(forType: .string) ?? ""
            if !normalize(text).isEmpty {
                copiedText = text
                break
            }
        } while Date() < deadline

        if let copiedText {
            return payload(
                status: "ok",
                method: "cmd_c",
                text: copiedText,
                maxChars: maxChars,
                startedAt: startedAt,
                startedPerf: startedPerf,
                warnings: warnings
            )
        }

        warnings.append("cmd_c_no_plain_text")
        return payload(
            status: "no_text",
            method: "cmd_c",
            text: "",
            maxChars: maxChars,
            startedAt: startedAt,
            startedPerf: startedPerf,
            warnings: warnings
        )
    }

    private static func readAXSelectedText() -> (text: String?, warnings: [String]) {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let focusedError = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard focusedError == .success, let rawFocused = focusedRef else {
            return (nil, ["ax_focused_element_unavailable:\(axErrorCode(focusedError))"])
        }

        guard CFGetTypeID(rawFocused) == AXUIElementGetTypeID() else {
            return (nil, ["ax_focused_element_wrong_type"])
        }
        let focused = rawFocused as! AXUIElement
        var selectedTextRef: CFTypeRef?
        let selectedTextError = AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            &selectedTextRef
        )
        guard selectedTextError == .success, let selected = selectedTextRef as? String else {
            return (nil, ["ax_selected_text_unavailable:\(axErrorCode(selectedTextError))"])
        }

        let normalized = normalize(selected)
        if normalized.isEmpty {
            return (nil, ["ax_selected_text_empty"])
        }
        return (selected, [])
    }

    private static func payload(
        status: String,
        method: String,
        text: String,
        maxChars: Int,
        startedAt: Date,
        startedPerf: TimeInterval,
        warnings: [String]
    ) -> [String: Any] {
        let normalized = normalize(text)
        let rawChars = normalized.count
        let truncated = rawChars > maxChars
        let packetText = truncated
            ? String(normalized.prefix(maxChars)).trimmingCharacters(in: .whitespacesAndNewlines)
            : normalized
        return [
            "schema_version": 1,
            "status": status,
            "method": method,
            "captured_at": isoString(startedAt),
            "duration_ms": durationMS(since: startedPerf),
            "max_chars": maxChars,
            "raw_text_chars": rawChars,
            "text_chars": packetText.count,
            "truncated": truncated,
            "warnings": warnings,
            "text": status == "ok" ? packetText : "",
        ]
    }

    private static func normalize(_ value: String) -> String {
        var text = value.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")
        var lines = text.components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeFirst()
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    private static func snapshot(pasteboard: NSPasteboard) -> [SavedPasteboardItem] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            var data: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let bytes = item.data(forType: type) {
                    data[type] = bytes
                }
            }
            return SavedPasteboardItem(types: item.types, data: data)
        }
    }

    private static func restore(pasteboard: NSPasteboard, items: [SavedPasteboardItem]) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { saved in
            let item = NSPasteboardItem()
            for type in saved.types {
                if let bytes = saved.data[type] {
                    item.setData(bytes, forType: type)
                }
            }
            return item
        }
        pasteboard.writeObjects(restored)
    }

    private static func synthesizeCmdC() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw CaptureError.noEventSource
        }
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)
        else {
            throw CaptureError.eventPostFailed
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

    private enum CaptureError: LocalizedError {
        case noEventSource
        case eventPostFailed

        var errorDescription: String? {
            switch self {
            case .noEventSource:
                return "CGEventSource creation failed"
            case .eventPostFailed:
                return "could not synthesize Cmd+C"
            }
        }
    }

    private static func axErrorCode(_ code: AXError) -> String {
        switch code {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegal_argument"
        case .invalidUIElement: return "invalid_ui_element"
        case .invalidUIElementObserver: return "invalid_ui_element_observer"
        case .cannotComplete: return "cannot_complete"
        case .attributeUnsupported: return "attribute_unsupported"
        case .actionUnsupported: return "action_unsupported"
        case .notificationUnsupported: return "notification_unsupported"
        case .notImplemented: return "not_implemented"
        case .notificationAlreadyRegistered: return "notification_already_registered"
        case .notificationNotRegistered: return "notification_not_registered"
        case .apiDisabled: return "api_disabled"
        case .noValue: return "no_value"
        case .parameterizedAttributeUnsupported: return "parameterized_attribute_unsupported"
        case .notEnoughPrecision: return "not_enough_precision"
        @unknown default: return "ax_error_\(code.rawValue)"
        }
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    private static func durationMS(since start: TimeInterval) -> Double {
        let duration = ProcessInfo.processInfo.systemUptime - start
        return round(duration * 100_000) / 100
    }
}
