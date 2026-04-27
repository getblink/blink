import AppKit
import ApplicationServices
import Foundation

/// Shape that mirrors `docs/ARTIFACT_SCHEMA.md` → `target_metadata`. Any field
/// we can't populate natively MUST land in `warnings` — never silently dropped.
struct TargetMetadata {
    var status: String
    var frontmostApp: String?
    var frontmostWindowTitle: String?
    var frontmostPid: Int?
    var workspaceFrontmostApp: String?
    var workspaceFrontmostWindowTitle: String?
    var workspaceFrontmostPid: Int?
    var focusedApp: String?
    var focusedAppPid: Int?
    var focusedAppBundleId: String?
    var focusedRole: String?
    var focusedSubrole: String?
    var focusedTitle: String?
    var focusedDescription: String?
    var focusedValue: String?
    var focusedValuePreview: String?
    var focusedLabel: String?
    var focusedBounds: CGRect?
    var accessibilityTrusted: Bool
    var warnings: [String]
    var error: String?
    var errorDetail: String?

    func asDictionary() -> [String: Any] {
        // Top-level uses the shortened preview (like the research runner).
        // Embed the untruncated value under `_full`.
        var dict: [String: Any] = [
            "status": status,
            "frontmost_app": frontmostApp as Any,
            "frontmost_window_title": frontmostWindowTitle as Any,
            "frontmost_pid": frontmostPid as Any,
            "workspace_frontmost_app": workspaceFrontmostApp as Any,
            "workspace_frontmost_window_title": workspaceFrontmostWindowTitle as Any,
            "workspace_frontmost_pid": workspaceFrontmostPid as Any,
            "focused_app": focusedApp as Any,
            "focused_app_pid": focusedAppPid as Any,
            "focused_app_bundle_id": focusedAppBundleId as Any,
            "focused_role": focusedRole as Any,
            "focused_subrole": focusedSubrole as Any,
            "focused_title": focusedTitle as Any,
            "focused_description": focusedDescription as Any,
            "focused_value_preview": focusedValuePreview as Any,
            "focused_label": focusedLabel as Any,
            "focused_bounds": focusedBounds.map {
                ["x": $0.origin.x, "y": $0.origin.y, "width": $0.size.width, "height": $0.size.height]
            } as Any,
            "permission": ["accessibility_trusted": accessibilityTrusted],
            "warnings": warnings,
            "error": error as Any,
            "error_detail": errorDetail as Any,
        ]

        var full = dict
        full["focused_value"] = focusedValue as Any
        full.removeValue(forKey: "focused_value_preview")
        dict["_full"] = full
        return dict
    }
}

enum TargetMetadataCapture {
    private static let valuePreviewChars = 120

    /// Read the focused AX element and assemble a `TargetMetadata` snapshot.
    ///
    /// This is a best-effort native capture; it is NOT yet at full parity with
    /// the research-loop Python (which also reads focus resolution strategies,
    /// sibling trees, chrome_ax_empty heuristics). Gaps land in `warnings`.
    static func capture() -> TargetMetadata {
        var warnings: [String] = []
        let trusted = AXIsProcessTrusted()
        if !trusted {
            warnings.append("accessibility_not_trusted")
        }

        var metadata = TargetMetadata(
            status: trusted ? "ok" : "permission_denied",
            frontmostApp: nil,
            frontmostWindowTitle: nil,
            frontmostPid: nil,
            workspaceFrontmostApp: nil,
            workspaceFrontmostWindowTitle: nil,
            workspaceFrontmostPid: nil,
            focusedApp: nil,
            focusedAppPid: nil,
            focusedAppBundleId: nil,
            focusedRole: nil,
            focusedSubrole: nil,
            focusedTitle: nil,
            focusedDescription: nil,
            focusedValue: nil,
            focusedValuePreview: nil,
            focusedLabel: nil,
            focusedBounds: nil,
            accessibilityTrusted: trusted,
            warnings: warnings,
            error: trusted ? nil : "accessibility_not_trusted",
            errorDetail: nil
        )

        let workspaceApp = NSWorkspace.shared.frontmostApplication
        metadata.workspaceFrontmostApp = workspaceApp?.localizedName
        metadata.workspaceFrontmostPid = workspaceApp.map { Int($0.processIdentifier) }

        guard trusted else { return metadata }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let focusedError = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
        )
        guard focusedError == .success, let raw = focusedRef else {
            metadata.status = "not_found"
            metadata.error = axErrorCode(focusedError)
            metadata.warnings.append("no_focused_ui_element")
            return metadata
        }
        let focused = raw as! AXUIElement

        metadata.focusedRole = shortenedRole(stringAttr(focused, kAXRoleAttribute as CFString))
        metadata.focusedSubrole = stringAttr(focused, kAXSubroleAttribute as CFString)
        metadata.focusedTitle = stringAttr(focused, kAXTitleAttribute as CFString)
        metadata.focusedDescription = stringAttr(focused, kAXDescriptionAttribute as CFString)
        metadata.focusedLabel = stringAttr(focused, kAXLabelValueAttribute as CFString)
            ?? stringAttr(focused, "AXDescription" as CFString)

        let rawValue = stringAttr(focused, kAXValueAttribute as CFString)
        metadata.focusedValue = rawValue
        metadata.focusedValuePreview = rawValue.map { truncate($0, limit: valuePreviewChars) }
        metadata.focusedBounds = focusedBoundsRect(focused)

        var pid: pid_t = 0
        if AXUIElementGetPid(focused, &pid) == .success {
            metadata.focusedAppPid = Int(pid)
            if let app = NSRunningApplication(processIdentifier: pid) {
                metadata.focusedApp = app.localizedName
                metadata.focusedAppBundleId = app.bundleIdentifier
                metadata.frontmostApp = app.localizedName
                metadata.frontmostPid = Int(pid)
            }
        }

        if metadata.frontmostApp == nil {
            metadata.frontmostApp = metadata.workspaceFrontmostApp
            metadata.frontmostPid = metadata.workspaceFrontmostPid
            metadata.warnings.append("fell_back_to_workspace_frontmost")
        }
        if metadata.frontmostApp != metadata.workspaceFrontmostApp {
            metadata.warnings.append("focused_owner_differs_from_workspace_frontmost")
        }

        return metadata
    }

    static func captureCaret() -> [String: Any] {
        guard AXIsProcessTrusted() else {
            return [
                "status": "permission_denied",
                "error": "accessibility_not_trusted",
            ]
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let focusedError = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
        )
        guard focusedError == .success, let rawFocused = focusedRef else {
            return [
                "status": "not_found",
                "error": axErrorCode(focusedError),
            ]
        }
        let focused = rawFocused as! AXUIElement

        var selectedRangeRef: CFTypeRef?
        let selectedRangeError = AXUIElementCopyAttributeValue(
            focused, kAXSelectedTextRangeAttribute as CFString, &selectedRangeRef
        )
        if selectedRangeError == .success,
           let selectedRangeRef,
           let range = selectedRange(selectedRangeRef) {
            var payload: [String: Any] = [
                "status": "ok",
                "range": [
                    "location": range.location,
                    "length": range.length,
                ],
            ]
            var boundsRef: CFTypeRef?
            let boundsError = AXUIElementCopyParameterizedAttributeValue(
                focused,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                selectedRangeRef,
                &boundsRef
            )
            if boundsError == .success, let boundsRef, let bounds = rectPayload(boundsRef) {
                payload["bounds"] = bounds
            } else {
                payload["bounds"] = NSNull()
                payload["bounds_status"] = axErrorCode(boundsError)
            }
            payload["range_probe"] = rangeProbeDiagnostics(focused, range: range)
            payload["text_marker"] = textMarkerDiagnostics(focused, selectedRange: range)
            return payload
        }

        let textMarker = textMarkerDiagnostics(focused, selectedRange: nil)
        var lineRef: CFTypeRef?
        let lineError = AXUIElementCopyAttributeValue(
            focused, kAXInsertionPointLineNumberAttribute as CFString, &lineRef
        )
        if lineError == .success, let lineNumber = lineRef as? NSNumber {
            return [
                "status": "line_only",
                "line_number": lineNumber.intValue,
                "text_marker": textMarker,
            ]
        }

        if selectedRangeError == .attributeUnsupported || selectedRangeError == .noValue {
            return [
                "status": "unsupported",
                "text_marker": textMarker,
            ]
        }
        return [
            "status": "error",
            "error": axErrorCode(selectedRangeError),
            "text_marker": textMarker,
        ]
    }

    // MARK: - AX helpers

    private static func stringAttr(_ element: AXUIElement, _ name: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &ref) == .success,
              let value = ref as? String else { return nil }
        return value
    }

    private static func focusedBoundsRect(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        let posOK = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success
        let sizeOK = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success
        guard posOK && sizeOK else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        let pv = posRef as! AXValue
        let sv = sizeRef as! AXValue
        guard AXValueGetValue(pv, .cgPoint, &origin),
              AXValueGetValue(sv, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func selectedRange(_ value: CFTypeRef) -> CFRange? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func rectPayload(_ value: CFTypeRef) -> [String: Double]? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
        return [
            "x": rect.origin.x,
            "y": rect.origin.y,
            "width": rect.size.width,
            "height": rect.size.height,
        ]
    }

    private static func rangePayload(_ value: CFTypeRef) -> [String: Int]? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return ["location": range.location, "length": range.length]
    }

    private static func axRangeValue(_ range: CFRange) -> AXValue? {
        var mutableRange = range
        return AXValueCreate(.cfRange, &mutableRange)
    }

    private static func parameterizedValue(
        _ element: AXUIElement,
        _ attribute: CFString,
        _ parameter: CFTypeRef
    ) -> (AXError, CFTypeRef?) {
        var ref: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element,
            attribute,
            parameter,
            &ref
        )
        return (error, ref)
    }

    private static func parameterizedRectSnapshot(
        _ element: AXUIElement,
        _ attribute: CFString,
        _ parameter: CFTypeRef
    ) -> [String: Any] {
        let (error, ref) = parameterizedValue(element, attribute, parameter)
        var snapshot: [String: Any] = ["status": axErrorCode(error)]
        if error == .success, let ref, let rect = rectPayload(ref) {
            snapshot["rect"] = rect
        }
        return snapshot
    }

    private static func parameterizedStringSnapshot(
        _ element: AXUIElement,
        _ attribute: CFString,
        _ parameter: CFTypeRef
    ) -> [String: Any] {
        let (error, ref) = parameterizedValue(element, attribute, parameter)
        var snapshot: [String: Any] = ["status": axErrorCode(error)]
        if error == .success, let value = ref as? String {
            snapshot["text"] = truncate(value, limit: 500)
        }
        return snapshot
    }

    private static func parameterizedNumberSnapshot(
        _ element: AXUIElement,
        _ attribute: CFString,
        _ parameter: CFTypeRef
    ) -> [String: Any] {
        let (error, ref) = parameterizedValue(element, attribute, parameter)
        var snapshot: [String: Any] = ["status": axErrorCode(error)]
        if error == .success, let value = ref as? NSNumber {
            snapshot["value"] = value
        }
        return snapshot
    }

    private static func parameterizedRangeSnapshot(
        _ element: AXUIElement,
        _ attribute: CFString,
        _ parameter: CFTypeRef
    ) -> [String: Any] {
        let (error, ref) = parameterizedValue(element, attribute, parameter)
        var snapshot: [String: Any] = ["status": axErrorCode(error)]
        if error == .success, let ref, let range = rangePayload(ref) {
            snapshot["range"] = range
        }
        return snapshot
    }

    private static func rangeSnapshot(_ element: AXUIElement, range: CFRange) -> [String: Any] {
        guard let rangeValue = axRangeValue(range) else {
            return ["status": "invalid_range"]
        }
        return [
            "range": ["location": range.location, "length": range.length],
            "bounds": parameterizedRectSnapshot(
                element,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                rangeValue
            ),
            "string": parameterizedStringSnapshot(
                element,
                kAXStringForRangeParameterizedAttribute as CFString,
                rangeValue
            ),
        ]
    }

    private static func rangeProbeDiagnostics(_ element: AXUIElement, range: CFRange) -> [String: Any] {
        var diagnostics: [String: Any] = [:]
        if range.length == 0 {
            diagnostics["caret_or_next_character"] = rangeSnapshot(
                element,
                range: CFRange(location: range.location, length: 1)
            )
            if range.location > 0 {
                diagnostics["previous_character"] = rangeSnapshot(
                    element,
                    range: CFRange(location: range.location - 1, length: 1)
                )
            }
        }

        let indexParameter = NSNumber(value: range.location)
        let lineSnapshot = parameterizedNumberSnapshot(
            element,
            kAXLineForIndexParameterizedAttribute as CFString,
            indexParameter
        )
        diagnostics["line_for_index"] = lineSnapshot
        if let lineNumber = lineSnapshot["value"] as? NSNumber {
            let lineParameter = NSNumber(value: lineNumber.intValue)
            let lineRangeSnapshot = parameterizedRangeSnapshot(
                element,
                kAXRangeForLineParameterizedAttribute as CFString,
                lineParameter
            )
            diagnostics["range_for_line"] = lineRangeSnapshot
            if let lineRange = lineRangeSnapshot["range"] as? [String: Int],
               let location = lineRange["location"],
               let length = lineRange["length"] {
                diagnostics["line_range"] = rangeSnapshot(
                    element,
                    range: CFRange(location: location, length: length)
                )
            }
        }
        return diagnostics
    }

    private static func markerRangeSnapshot(
        _ element: AXUIElement,
        markerRange: CFTypeRef
    ) -> [String: Any] {
        [
            "bounds": parameterizedRectSnapshot(
                element,
                "AXBoundsForTextMarkerRange" as CFString,
                markerRange
            ),
            "string": parameterizedStringSnapshot(
                element,
                "AXStringForTextMarkerRange" as CFString,
                markerRange
            ),
            "length": parameterizedNumberSnapshot(
                element,
                "AXLengthForTextMarkerRange" as CFString,
                markerRange
            ),
            "debug": parameterizedStringSnapshot(
                element,
                "AXTextMarkerRangeDebugDescription" as CFString,
                markerRange
            ),
        ]
    }

    private static func markerSnapshot(
        _ element: AXUIElement,
        marker: CFTypeRef
    ) -> [String: Any] {
        [
            "valid": parameterizedNumberSnapshot(
                element,
                "AXTextMarkerIsValid" as CFString,
                marker
            ),
            "index": parameterizedNumberSnapshot(
                element,
                "AXIndexForTextMarker" as CFString,
                marker
            ),
            "debug": parameterizedStringSnapshot(
                element,
                "AXTextMarkerDebugDescription" as CFString,
                marker
            ),
        ]
    }

    private static func markerRangeForUnorderedMarkers(
        _ element: AXUIElement,
        _ first: CFTypeRef,
        _ second: CFTypeRef
    ) -> (AXError, CFTypeRef?) {
        let markers = [first, second] as CFArray
        return parameterizedValue(
            element,
            "AXTextMarkerRangeForUnorderedTextMarkers" as CFString,
            markers
        )
    }

    private static func adjacentMarkerRangeSnapshot(
        _ element: AXUIElement,
        marker: CFTypeRef,
        adjacentAttribute: CFString
    ) -> [String: Any] {
        let (adjacentError, adjacentRef) = parameterizedValue(element, adjacentAttribute, marker)
        var snapshot: [String: Any] = ["marker_status": axErrorCode(adjacentError)]
        guard adjacentError == .success, let adjacentRef else {
            return snapshot
        }
        snapshot["marker"] = markerSnapshot(element, marker: adjacentRef)
        let (rangeError, rangeRef) = markerRangeForUnorderedMarkers(element, marker, adjacentRef)
        snapshot["range_status"] = axErrorCode(rangeError)
        if rangeError == .success, let rangeRef {
            snapshot["range"] = markerRangeSnapshot(element, markerRange: rangeRef)
        }
        return snapshot
    }

    private static func textMarkerDiagnostics(
        _ element: AXUIElement,
        selectedRange: CFRange?
    ) -> [String: Any] {
        var diagnostics: [String: Any] = [:]
        var selectedMarkerRangeRef: CFTypeRef?
        let selectedMarkerRangeError = AXUIElementCopyAttributeValue(
            element,
            "AXSelectedTextMarkerRange" as CFString,
            &selectedMarkerRangeRef
        )
        diagnostics["selected_marker_range_status"] = axErrorCode(selectedMarkerRangeError)
        if selectedMarkerRangeError == .success, let selectedMarkerRangeRef {
            diagnostics["selected_marker_range"] = markerRangeSnapshot(
                element,
                markerRange: selectedMarkerRangeRef
            )
        }

        guard let selectedRange else {
            return diagnostics
        }

        let indexParameter = NSNumber(value: selectedRange.location)
        let (markerError, markerRef) = parameterizedValue(
            element,
            "AXTextMarkerForIndex" as CFString,
            indexParameter
        )
        diagnostics["index_marker_status"] = axErrorCode(markerError)
        guard markerError == .success, let markerRef else {
            return diagnostics
        }

        diagnostics["index_marker"] = markerSnapshot(element, marker: markerRef)
        let (lineRangeError, lineRangeRef) = parameterizedValue(
            element,
            "AXLineTextMarkerRangeForTextMarker" as CFString,
            markerRef
        )
        diagnostics["line_marker_range_status"] = axErrorCode(lineRangeError)
        if lineRangeError == .success, let lineRangeRef {
            diagnostics["line_marker_range"] = markerRangeSnapshot(
                element,
                markerRange: lineRangeRef
            )
        }
        diagnostics["next_marker_range"] = adjacentMarkerRangeSnapshot(
            element,
            marker: markerRef,
            adjacentAttribute: "AXNextTextMarkerForTextMarker" as CFString
        )
        diagnostics["previous_marker_range"] = adjacentMarkerRangeSnapshot(
            element,
            marker: markerRef,
            adjacentAttribute: "AXPreviousTextMarkerForTextMarker" as CFString
        )
        return diagnostics
    }

    private static func shortenedRole(_ role: String?) -> String? {
        guard let role = role else { return nil }
        return role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
    }

    private static func truncate(_ s: String, limit: Int) -> String {
        if s.count <= limit { return s }
        let idx = s.index(s.startIndex, offsetBy: limit)
        return s[..<idx] + "…"
    }

    private static func axErrorCode(_ err: AXError) -> String {
        switch err {
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
        @unknown default: return "unknown"
        }
    }
}
