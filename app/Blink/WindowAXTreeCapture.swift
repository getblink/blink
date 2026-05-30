import ApplicationServices
import Foundation

/// Captures the focused window's full accessibility tree as compact indented
/// text. Unlike `FocusedContextCapture` (which describes only the focused
/// element), this walks the whole window — including nodes above and below the
/// visible viewport — so the server can give the model scrolling context the
/// viewport-bound screenshot can't.
///
/// Clamping is layered so a pathological page can't blow memory or the upload:
///   - `maxNodes`: hard ceiling on the walk (memory/upload safety backstop).
///   - `maxValueChars`: per-node value clamp (terminals/editors hold an entire
///     document in a single `AXValue`).
///   - `maxDepth`: guards against cyclic/very deep trees.
/// The server applies the final token-budget clamp (`AX_TREE_MAX_CHARS`) on
/// top, so these client caps stay generous and rarely need to change.
enum WindowAXTreeCapture {
    struct Result {
        let text: String
        let nodeCount: Int
        /// True when the node cap stopped the walk before the tree was fully
        /// enumerated. Surfaced as a trailing marker in `text` so the model
        /// knows content was cut.
        let truncated: Bool
    }

    static let defaultMaxNodes = 4000
    static let defaultMaxDepth = 60
    static let defaultMaxValueChars = 500

    /// Attributes fetched per node in a single batched IPC call. Ordered so the
    /// returned array indexes line up with the locals in `walk`.
    private static let nodeAttributes: [String] = [
        kAXRoleAttribute as String,
        kAXRoleDescriptionAttribute as String,
        kAXTitleAttribute as String,
        kAXDescriptionAttribute as String,
        kAXValueAttribute as String,
    ]

    static func capture(
        maxNodes: Int = defaultMaxNodes,
        maxDepth: Int = defaultMaxDepth,
        maxValueChars: Int = defaultMaxValueChars
    ) -> Result? {
        guard AXIsProcessTrusted() else { return nil }
        guard let root = focusedWindowElement() else { return nil }
        // Bound AX messaging: an unresponsive app must not stall the submit
        // path. The timeout set on the app/window root propagates to its
        // element tree. Mirrors FocusedContextCapture.textTargetDecision.
        AXUIElementSetMessagingTimeout(root, 0.2)

        var lines: [String] = []
        var nodeCount = 0
        var truncated = false

        func walk(_ element: AXUIElement, depth: Int, indent: Int) {
            if nodeCount >= maxNodes {
                truncated = true
                return
            }
            nodeCount += 1
            let attrs = copyMultiple(element, nodeAttributes)
            let role = shortenRole(attrs[0] as? String)
            let roleDesc = (attrs[1] as? String)?.nonBlank
            let title = (attrs[2] as? String)?.nonBlank
            let desc = (attrs[3] as? String)?.nonBlank
            let value = stringValue(attrs[4])?.clamped(to: maxValueChars)

            let name = title ?? desc
            // Collapse empty structural wrappers: a node with no name and no
            // value carries no semantic content of its own, so emit nothing and
            // keep its children at the current indent. This is the "collapse
            // empty containers" projection that drives most of the token win.
            let line = formatLine(role: role, roleDesc: roleDesc, name: name, value: value, indent: indent)
            let childIndent: Int
            if let line {
                lines.append(line)
                childIndent = indent + 1
            } else {
                childIndent = indent
            }

            guard depth < maxDepth else { return }
            for child in childrenOf(element) {
                if nodeCount >= maxNodes {
                    truncated = true
                    break
                }
                walk(child, depth: depth + 1, indent: childIndent)
            }
        }

        walk(root, depth: 0, indent: 0)

        guard !lines.isEmpty else { return nil }
        if truncated {
            lines.append("[… tree truncated at \(maxNodes) nodes]")
        }
        return Result(text: lines.joined(separator: "\n"), nodeCount: nodeCount, truncated: truncated)
    }

    // MARK: - Formatting

    /// One line per emitted node: `<indent><lead> "name" = "value"`. Returns
    /// nil for nameless, valueless nodes so the caller can collapse them.
    private static func formatLine(
        role: String?,
        roleDesc: String?,
        name: String?,
        value: String?,
        indent: Int
    ) -> String? {
        if name == nil, value == nil {
            return nil
        }
        let lead = roleDesc ?? role ?? "node"
        var line = String(repeating: "  ", count: indent) + lead
        if let name {
            line += " \"\(name)\""
        }
        // Suppress value when it merely repeats the name (common for buttons /
        // static text where title and value coincide).
        if let value, value != name {
            line += " = \"\(value)\""
        }
        return line
    }

    // MARK: - AX access

    /// Resolve the active window element. Prefers the focused element's window;
    /// falls back to the owning application's focused window.
    private static func focusedWindowElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedRef else {
            return nil
        }
        let focused = focusedRef as! AXUIElement

        if let window = elementAttr(focused, kAXWindowAttribute as CFString) {
            return window
        }
        if let top = elementAttr(focused, kAXTopLevelUIElementAttribute as CFString) {
            return top
        }
        var pid: pid_t = 0
        if AXUIElementGetPid(focused, &pid) == .success {
            let app = AXUIElementCreateApplication(pid)
            if let window = elementAttr(app, kAXFocusedWindowAttribute as CFString) {
                return window
            }
        }
        // Last resort: the focused element itself yields at least its subtree.
        return focused
    }

    /// Batched read of several attributes in one IPC round-trip. Missing or
    /// errored attributes come back as nil at their index. Keeps the per-node
    /// cost to ~1 call instead of one per attribute.
    private static func copyMultiple(_ element: AXUIElement, _ names: [String]) -> [CFTypeRef?] {
        var valuesRef: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            element,
            names as CFArray,
            AXCopyMultipleAttributeOptions(),
            &valuesRef
        )
        guard error == .success,
              let values = valuesRef as? [CFTypeRef],
              values.count == names.count else {
            return Array(repeating: nil, count: names.count)
        }
        return values.map { value -> CFTypeRef? in
            if CFGetTypeID(value) == AXValueGetTypeID(),
               AXValueGetType(value as! AXValue) == .axError {
                return nil
            }
            if CFEqual(value, kCFNull) {
                return nil
            }
            return value
        }
    }

    private static func elementAttr(_ element: AXUIElement, _ name: CFString) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    private static func childrenOf(_ element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &ref
        ) == .success, let array = ref as? [AXUIElement] else { return [] }
        return array
    }

    /// Coerce an `AXValue` attribute into display text. Strings pass through;
    /// numbers/bools are stringified; geometry/range AXValues carry no useful
    /// text and are dropped.
    static func stringValue(_ ref: CFTypeRef?) -> String? {
        guard let ref else { return nil }
        if let string = ref as? String { return string.nonBlank }
        if let number = ref as? NSNumber { return number.stringValue }
        return nil
    }

    static func shortenRole(_ role: String?) -> String? {
        guard let role else { return nil }
        return role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
    }
}

private extension String {
    var nonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Clamp to `limit` characters, collapsing internal newlines to spaces so a
    /// single node stays a single line. Appends an ellipsis when cut.
    func clamped(to limit: Int) -> String {
        let flattened = replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)) + "…"
    }
}
