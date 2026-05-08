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
    /// AppKit screen coordinates (origin bottom-left, +Y up). Tries, in
    /// order: the focused element's selected range, the plural-ranges
    /// attribute, descendants of a focused container (Chromium webviews,
    /// AXGroups), and finally a bounds-based approximation for input-shaped
    /// elements that don't honor parameterized range queries. Returns nil
    /// only when accessibility is denied or no plausible target was found.
    static func caretScreenPoint() -> CGPoint? {
        guard AXIsProcessTrusted() else { return nil }
        guard let focused = systemWideFocusedElement() else { return nil }
        guard let primaryHeight = NSScreen.screens.first?.frame.height,
              primaryHeight > 0 else { return nil }

        let candidates = candidateElements(starting: focused)
        for candidate in candidates {
            if let p = caretFromRangeAttrs(candidate, primaryHeight: primaryHeight) {
                return p
            }
        }
        for candidate in candidates {
            if let p = caretFromBoundsApproximation(candidate, primaryHeight: primaryHeight) {
                return p
            }
        }
        return nil
    }

    private static func systemWideFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &ref
        ) == .success, let ref else { return nil }
        return (ref as! AXUIElement)
    }

    /// Returns the focused element plus a bounded set of descendants /
    /// alternate-root candidates that might be the real text input. Each
    /// element appears at most once. Bounded to keep the AX queries cheap
    /// even on huge webviews.
    private static func candidateElements(starting focused: AXUIElement) -> [AXUIElement] {
        var results: [AXUIElement] = [focused]
        var seen = Set<UInt>()
        seen.insert(addressKey(focused))

        func enqueue(_ element: AXUIElement) {
            let key = addressKey(element)
            if seen.contains(key) { return }
            seen.insert(key)
            results.append(element)
        }

        // The focused window's own focused element — sometimes more specific
        // than the system-wide one (e.g., when the system-wide focus is a
        // generic container).
        if let window = elementAttr(focused, kAXWindowAttribute as CFString),
           let windowFocused = elementAttr(window, kAXFocusedUIElementAttribute as CFString) {
            enqueue(windowFocused)
        }

        // Bounded BFS over children to find descendants that look like
        // text inputs. Helps in Chromium / Electron where the focused
        // element is the AXWebArea/AXGroup, not the contenteditable child.
        let maxNodes = 32
        let maxDepth = 3
        var queue: [(AXUIElement, Int)] = [(focused, 0)]
        var queued = Set<UInt>()
        queued.insert(addressKey(focused))
        var visitedDuringBFS = 0
        while !queue.isEmpty, visitedDuringBFS < maxNodes {
            let (node, depth) = queue.removeFirst()
            visitedDuringBFS += 1
            if depth >= maxDepth { continue }
            let role = stringAttr(node, kAXRoleAttribute as CFString)
            // Only descend through elements that plausibly contain a text
            // input — otherwise the BFS wastes attribute calls.
            if depth > 0, !roleIsContainer(role), !roleLooksLikeTextInput(role) {
                continue
            }
            let children = childrenAttr(node)
            for child in children {
                let childRole = stringAttr(child, kAXRoleAttribute as CFString)
                if roleLooksLikeTextInput(childRole) || hasSelectedTextRange(child) {
                    enqueue(child)
                }
                if roleIsContainer(childRole) {
                    let key = addressKey(child)
                    if !queued.contains(key) {
                        queued.insert(key)
                        queue.append((child, depth + 1))
                    }
                }
                if visitedDuringBFS >= maxNodes { break }
            }
        }
        return results
    }

    /// Layer 1 + Layer 2: try `kAXSelectedTextRangeAttribute` (singular)
    /// then `"AXSelectedTextRanges"` (plural). For each, query
    /// `AXBoundsForRange` at a zero-length caret at the end of the range,
    /// with a trailing-edge fallback for non-zero ranges.
    private static func caretFromRangeAttrs(
        _ element: AXUIElement,
        primaryHeight: CGFloat
    ) -> CGPoint? {
        var ranges: [CFRange] = []
        if let singular = selectedRangeAttr(element) {
            ranges.append(singular)
        }
        if let plural = selectedRangesAttr(element) {
            for r in plural where !ranges.contains(where: { $0.location == r.location && $0.length == r.length }) {
                ranges.append(r)
            }
        }
        for range in ranges {
            let caretLocation = range.location + range.length
            var caretRange = CFRange(location: caretLocation, length: 0)
            if let rect = boundsForRange(element, range: &caretRange) {
                return CGPoint(x: rect.midX, y: primaryHeight - rect.midY)
            }
            if range.length > 0 {
                var fullRange = range
                if let rect = boundsForRange(element, range: &fullRange) {
                    return CGPoint(x: rect.maxX, y: primaryHeight - rect.midY)
                }
            }
        }
        return nil
    }

    /// Layer 4: when no parameterized-range query lands, approximate the
    /// caret as the right-mid of the element's bounds — but only if the
    /// element is an input-shaped text input. Big webviews / scroll areas
    /// get rejected so we fall through to the modal fallback instead of
    /// firing confetti at a meaningless screen edge.
    private static func caretFromBoundsApproximation(
        _ element: AXUIElement,
        primaryHeight: CGFloat
    ) -> CGPoint? {
        let role = stringAttr(element, kAXRoleAttribute as CFString)
        guard roleLooksLikeTextInput(role) else { return nil }
        guard let bounds = focusedBoundsRect(element) else { return nil }
        guard bounds.width >= 24, bounds.height > 0,
              bounds.height <= 200,
              bounds.width.isFinite, bounds.height.isFinite else { return nil }
        let aspect = bounds.width / max(bounds.height, 1)
        guard aspect >= 1, aspect <= 200 else { return nil }
        return CGPoint(x: bounds.maxX - 4, y: primaryHeight - bounds.midY)
    }

    private static func selectedRangesAttr(_ element: AXUIElement) -> [CFRange]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            "AXSelectedTextRanges" as CFString,
            &ref
        ) == .success, let ref else { return nil }
        guard let array = ref as? [AXValue] else { return nil }
        var out: [CFRange] = []
        for value in array {
            guard AXValueGetType(value) == .cfRange else { continue }
            var range = CFRange()
            if AXValueGetValue(value, .cfRange, &range) {
                out.append(range)
            }
        }
        return out.isEmpty ? nil : out
    }

    private static func elementAttr(_ element: AXUIElement, _ name: CFString) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &ref) == .success,
              let ref else { return nil }
        guard CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    private static func childrenAttr(_ element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &ref
        ) == .success, let ref else { return [] }
        guard let array = ref as? [AXUIElement] else { return [] }
        return array
    }

    private static func hasSelectedTextRange(_ element: AXUIElement) -> Bool {
        selectedRangeAttr(element) != nil || selectedRangesAttr(element) != nil
    }

    private static func roleLooksLikeTextInput(_ role: String?) -> Bool {
        guard let role else { return false }
        let normalized = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        switch normalized {
        case "TextField", "TextArea", "ComboBox", "SearchField":
            return true
        default:
            return false
        }
    }

    private static func roleIsContainer(_ role: String?) -> Bool {
        guard let role else { return false }
        let normalized = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        switch normalized {
        case "WebArea", "Group", "ScrollArea", "SplitGroup", "Application", "Window":
            return true
        default:
            return false
        }
    }

    private static func addressKey(_ element: AXUIElement) -> UInt {
        // CFHash returns a CFHashCode (UInt) and pairs naturally with the
        // CFEqual identity that AXUIElement honors.
        CFHash(element)
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
        guard CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        let posValue = posRef as! AXValue
        let sizeValue = sizeRef as! AXValue
        guard AXValueGetType(posValue) == .cgPoint,
              AXValueGetType(sizeValue) == .cgSize else { return nil }
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
