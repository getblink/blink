import AppKit
import ApplicationServices
import Foundation

enum FocusedContextCapture {
    struct Snapshot {
        let uploadPayload: [String: Any]
        let meaningfulDraftText: String?
    }

    static func capture(allowContentRetention: Bool) -> [String: Any] {
        captureSnapshot(allowContentRetention: allowContentRetention).uploadPayload
    }

    static func captureSnapshot(allowContentRetention: Bool) -> Snapshot {
        guard AXIsProcessTrusted() else {
            return Snapshot(uploadPayload: [
                "permission_status": "denied",
                "warnings": ["accessibility_not_trusted"],
            ], meaningfulDraftText: nil)
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let focusedError = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard focusedError == .success, let rawFocused = focusedRef else {
            return Snapshot(uploadPayload: [
                "permission_status": "granted",
                "warnings": ["no_focused_ui_element"],
            ], meaningfulDraftText: nil)
        }
        let focused = rawFocused as! AXUIElement

        var payload: [String: Any] = [
            "permission_status": "granted",
            "role": shortenedRole(stringAttr(focused, kAXRoleAttribute as CFString)) as Any,
            "subrole": stringAttr(focused, kAXSubroleAttribute as CFString) as Any,
            "title": stringAttr(focused, kAXTitleAttribute as CFString) as Any,
            "description": stringAttr(focused, kAXDescriptionAttribute as CFString) as Any,
            "label": stringAttr(focused, kAXLabelValueAttribute as CFString) as Any,
            "placeholder": stringAttr(focused, "AXPlaceholderValue" as CFString) as Any,
            "value": stringAttr(focused, kAXValueAttribute as CFString) as Any,
            "selected_text": stringAttr(focused, kAXSelectedTextAttribute as CFString) as Any,
        ]
        if let bounds = focusedBoundsRect(focused) {
            payload["bounds"] = [
                "x": bounds.origin.x,
                "y": bounds.origin.y,
                "width": bounds.size.width,
                "height": bounds.size.height,
            ]
        }
        if let range = selectedRangeAttr(focused) {
            payload["selected_range"] = [
                "location": range.location,
                "length": range.length,
            ]
        }
        let meaningfulDraft = meaningfulText(payload["value"] as? String)
        if payload["value"] is String {
            payload["meaningful_value_char_count"] = meaningfulDraft?.count ?? 0
            if let meaningfulDraft {
                payload["nearby_relevant_text"] = String(meaningfulDraft.prefix(400))
                payload["draft_present"] = true
            } else {
                payload["draft_present"] = false
            }
        } else {
            payload["draft_present"] = false
            payload["meaningful_value_char_count"] = 0
        }

        var pid: pid_t = 0
        if AXUIElementGetPid(focused, &pid) == .success,
           let app = NSRunningApplication(processIdentifier: pid) {
            payload["app_name"] = app.localizedName as Any
            payload["bundle_id"] = app.bundleIdentifier as Any
        }
        return Snapshot(
            uploadPayload: sanitizeForUpload(payload, allowContentRetention: allowContentRetention),
            meaningfulDraftText: meaningfulDraft
        )
    }

    /// Best-effort query of the system-focused element's caret position in
    /// AppKit screen coordinates (origin bottom-left, +Y up). Returns nil
    /// when accessibility is not granted, no element is focused, or the
    /// element doesn't expose `AXBoundsForRange` (some browsers and custom
    /// text views).
    static func caretScreenPoint() -> CGPoint? {
        guard AXIsProcessTrusted() else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let rawFocused = focusedRef else { return nil }
        let focused = rawFocused as! AXUIElement

        guard var range = selectedRangeAttr(focused) else { return nil }
        // After a paste, the selected range is usually a zero-length caret
        // at the insertion point. Some apps report a non-zero length when
        // the user had a selection that got replaced — anchor the bounds
        // query at the END of the range so confetti emerges where the
        // caret actually is.
        let caretLocation = range.location + range.length
        var caretRange = CFRange(location: caretLocation, length: 0)

        let primaryHeight = NSScreen.screens.first?.frame.height
        guard let primaryHeight else { return nil }

        if let rect = boundsForRange(focused, range: &caretRange) {
            return CGPoint(x: rect.midX, y: primaryHeight - rect.midY)
        }
        // Fallback: the trailing edge of the original range, which some apps
        // honor even when the zero-length probe fails.
        if range.length > 0,
           let rect = boundsForRange(focused, range: &range) {
            return CGPoint(x: rect.maxX, y: primaryHeight - rect.midY)
        }
        return nil
    }

    private static func boundsForRange(
        _ element: AXUIElement,
        range: inout CFRange
    ) -> CGRect? {
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &ref
        ) == .success, let ref else { return nil }
        guard CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        let axValue = ref as! AXValue
        guard AXValueGetType(axValue) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
        guard rect.width >= 0, rect.height > 0 else { return nil }
        return rect
    }

    static func meaningfulText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let scalars = trimmed.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        }
        let text = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func sanitizeForUpload(
        _ payload: [String: Any],
        allowContentRetention: Bool
    ) -> [String: Any] {
        var sanitized = payload
        sanitized = boundField("value", limit: 1000, in: sanitized)
        sanitized = boundField("selected_text", limit: 500, in: sanitized)
        sanitized = boundField("nearby_relevant_text", limit: 400, in: sanitized)

        guard !allowContentRetention else {
            return sanitized
        }

        sanitized = redactField("value", in: sanitized)
        sanitized = redactField("selected_text", in: sanitized)
        sanitized = redactField("nearby_relevant_text", in: sanitized)
        return sanitized
    }

    private static func stringAttr(_ element: AXUIElement, _ name: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func selectedRangeAttr(_ element: AXUIElement) -> CFRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &ref
        ) == .success, let ref else { return nil }
        guard CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        let axValue = ref as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func focusedBoundsRect(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        let posOK = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success
        let sizeOK = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success
        guard posOK, sizeOK, let posRef, let sizeRef else { return nil }
        let posValue = posRef as! AXValue
        let sizeValue = sizeRef as! AXValue
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func shortenedRole(_ role: String?) -> String? {
        guard let role else { return nil }
        return role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
    }

    private static func boundField(
        _ key: String,
        limit: Int,
        in payload: [String: Any]
    ) -> [String: Any] {
        guard let value = payload[key] as? String else { return payload }
        var result = payload
        result[key] = String(value.prefix(limit))
        result["\(key)_char_count"] = value.count
        result["\(key)_truncated"] = value.count > limit
        return result
    }

    private static func redactField(
        _ key: String,
        in payload: [String: Any]
    ) -> [String: Any] {
        guard payload[key] != nil else { return payload }
        var result = payload
        result.removeValue(forKey: key)
        result["\(key)_redacted"] = true
        return result
    }
}
