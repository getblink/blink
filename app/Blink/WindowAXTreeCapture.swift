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
    /// Keep a little headroom under the server's `AX_TREE_MAX_CHARS` backstop
    /// so elision markers and future wrapper text do not accidentally push the
    /// request into a naive server-side head clamp.
    static let defaultTextBudgetChars = 38_000
    static let defaultAfterAnchorRatio = 0.65
    /// Per-node value clamp used when a node's value SUBSUMES a pure-text
    /// subtree we collapse into it (see `walk`). More generous than the inline
    /// leaf clamp so a normal chat paragraph survives collapse intact; a
    /// pathological single-node value (a whole file in one AXValue) exceeds it
    /// and keeps its children instead of being cut.
    static let defaultCollapseValueChars = 1200

    /// Raw AX roles (post-`shortenRole`) whose nodes are plain-text leaves:
    /// their content lives entirely in value/title, with no URLs or interactive
    /// affordances. When ALL of a container's children are these, the
    /// container's own AXValue is just their concatenation — so we collapse the
    /// subtree into one value line rather than print the text twice.
    private static let plainTextLeafRoles: Set<String> = ["StaticText", "ListMarker"]

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
        maxValueChars: Int = defaultMaxValueChars,
        textBudgetChars: Int = defaultTextBudgetChars
    ) -> Result? {
        guard AXIsProcessTrusted() else { return nil }
        let focused = focusedElement()
        guard let root = focusedWindowElement(focused: focused) else { return nil }
        // Bound AX messaging: an unresponsive app must not stall the submit
        // path. The timeout set on the app/window root propagates to its
        // element tree. Mirrors FocusedContextCapture.textTargetDecision.
        AXUIElementSetMessagingTimeout(root, 0.2)

        var lines: [String] = []
        var focusedLineIndex: Int?
        var nodeCount = 0
        var nodeTruncated = false

        // `attrs` is pre-fetched by the caller (the root fetches its own) so the
        // collapse decision and the recursive descent share one IPC per node.
        func walk(_ element: AXUIElement, _ attrs: [CFTypeRef?], depth: Int, indent: Int) {
            if nodeCount >= maxNodes {
                nodeTruncated = true
                return
            }
            nodeCount += 1
            let role = shortenRole(attrs[0] as? String)
            let roleDesc = (attrs[1] as? String)?.nonBlank
            let title = (attrs[2] as? String)?.nonBlank
            let desc = (attrs[3] as? String)?.nonBlank
            let rawValue = stringValue(attrs[4])
            let name = title ?? desc

            // Fetch children + their attributes once; reused for both the
            // collapse decision below and the recursive descent (no double IPC).
            let children = depth < maxDepth ? childrenOf(element) : []
            let childAttrs = children.map { copyMultiple($0, nodeAttributes) }
            let childrenAllPlainText = !children.isEmpty && childAttrs.allSatisfy {
                guard let childRole = shortenRole($0[0] as? String) else { return false }
                return plainTextLeafRoles.contains(childRole)
            }

            // De-duplication: a container's AXValue is the concatenation of its
            // text descendants, so emitting BOTH the value line and the child
            // text lines doubles the tokens (observed ~2x on chat/article
            // surfaces). When the children are all plain text, collapse the
            // subtree into the single value line; if the value is too long to
            // hold safely, drop the redundant value and let the children carry
            // the full text instead (no content loss either way).
            var value = rawValue
            var descend = true
            if rawValue != nil, childrenAllPlainText {
                if rawValue!.count <= defaultCollapseValueChars {
                    descend = false
                } else {
                    value = nil
                }
            }
            let clampedValue = value?.clamped(to: descend ? maxValueChars : defaultCollapseValueChars)

            // Collapse empty structural wrappers: a node with no name and no
            // value carries no content of its own, so emit nothing and keep its
            // children at the current indent.
            let childIndent: Int
            if let line = formatLine(role: role, roleDesc: roleDesc, name: name, value: clampedValue, indent: indent) {
                if focusedLineIndex == nil,
                   let focused,
                   CFEqual(element, focused) {
                    focusedLineIndex = lines.count
                }
                lines.append(line)
                childIndent = indent + 1
            } else {
                childIndent = indent
            }

            guard descend else { return }
            for (child, childAttr) in zip(children, childAttrs) {
                if nodeCount >= maxNodes {
                    nodeTruncated = true
                    break
                }
                walk(child, childAttr, depth: depth + 1, indent: childIndent)
            }
        }

        walk(root, copyMultiple(root, nodeAttributes), depth: 0, indent: 0)

        guard !lines.isEmpty else { return nil }
        if nodeTruncated {
            lines.append("[… tree truncated at \(maxNodes) nodes]")
        }
        let selected = anchoredWindowText(
            for: lines,
            anchorIndex: focusedLineIndex,
            budget: textBudgetChars,
            requiredIndexes: nodeTruncated ? [lines.count - 1] : []
        )
        return Result(text: selected.text, nodeCount: nodeCount, truncated: nodeTruncated)
    }

    /// Select a budgeted window from a flat, indented AX dump.
    ///
    /// When the tree fits, this returns it unchanged. When it does not fit, it
    /// keeps the anchor line, its ancestors (for orientation), and then expands
    /// around the anchor with a bias toward following lines. If no anchor is
    /// available, it falls back to a tail window so long scroll surfaces preserve
    /// recent/bottom content instead of the old DFS-top prefix.
    static func anchoredWindowText(
        for rawLines: [String],
        anchorIndex: Int?,
        budget: Int,
        afterRatio: Double = defaultAfterAnchorRatio,
        requiredIndexes: Set<Int> = []
    ) -> (text: String, truncated: Bool) {
        let lines = rawLines.enumerated().map { index, text in
            TreeLine(index: index, text: text, depth: indentationDepth(text), chars: text.count + 1)
        }
        guard !lines.isEmpty else { return ("", false) }
        let fullChars = lines.reduce(0) { $0 + $1.chars }
        guard budget > 0, fullChars > budget else {
            return (rawLines.joined(separator: "\n"), false)
        }

        let clampedRatio = min(max(afterRatio, 0), 1)
        let kept: Set<Int>
        if let anchorIndex, lines.indices.contains(anchorIndex) {
            kept = anchoredIndexes(
                lines: lines,
                anchorIndex: anchorIndex,
                budget: budget,
                afterRatio: clampedRatio,
                requiredIndexes: requiredIndexes
            )
        } else {
            kept = tailIndexes(lines: lines, budget: budget, requiredIndexes: requiredIndexes)
        }
        return (assemble(lines: lines, kept: kept), true)
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
    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedRef else {
            return nil
        }
        return (focusedRef as! AXUIElement)
    }

    private static func focusedWindowElement(focused: AXUIElement?) -> AXUIElement? {
        guard let focused else { return nil }
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

    // MARK: - Budget selection

    private struct TreeLine {
        let index: Int
        let text: String
        let depth: Int
        let chars: Int
    }

    private static func indentationDepth(_ line: String) -> Int {
        let spaces = line.prefix { $0 == " " }.count
        return spaces / 2
    }

    private static func anchoredIndexes(
        lines: [TreeLine],
        anchorIndex: Int,
        budget: Int,
        afterRatio: Double,
        requiredIndexes: Set<Int>
    ) -> Set<Int> {
        var kept = requiredIndexes.filter { lines.indices.contains($0) }
        kept.formUnion(ancestorIndexes(lines: lines, anchorIndex: anchorIndex))
        kept.insert(anchorIndex)

        var used = kept.reduce(0) { $0 + lines[$1].chars }
        guard used < budget else { return kept }

        let remaining = budget - used
        var afterBudget = Int(Double(remaining) * afterRatio)
        var beforeBudget = remaining - afterBudget
        var before = anchorIndex - 1
        var after = anchorIndex + 1

        while before >= 0 || after < lines.count {
            var progressed = false
            if after < lines.count, afterBudget > 0 {
                progressed = tryAdd(
                    index: after,
                    lines: lines,
                    kept: &kept,
                    sideBudget: &afterBudget,
                    used: &used,
                    totalBudget: budget
                ) || progressed
                if progressed || kept.contains(after) { after += 1 }
            }
            if before >= 0, beforeBudget > 0 {
                let added = tryAdd(
                    index: before,
                    lines: lines,
                    kept: &kept,
                    sideBudget: &beforeBudget,
                    used: &used,
                    totalBudget: budget
                )
                progressed = added || progressed
                if added || kept.contains(before) { before -= 1 }
            }
            if !progressed {
                break
            }
        }

        // Spend any leftover budget on either side, preserving the after-first
        // bias but avoiding stranded budget when one side is already exhausted.
        while used < budget, before >= 0 || after < lines.count {
            var progressed = false
            if after < lines.count {
                var sideBudget = budget - used
                let added = tryAdd(
                    index: after,
                    lines: lines,
                    kept: &kept,
                    sideBudget: &sideBudget,
                    used: &used,
                    totalBudget: budget
                )
                progressed = added || progressed
                if added || kept.contains(after) { after += 1 }
            }
            if used < budget, before >= 0 {
                var sideBudget = budget - used
                let added = tryAdd(
                    index: before,
                    lines: lines,
                    kept: &kept,
                    sideBudget: &sideBudget,
                    used: &used,
                    totalBudget: budget
                )
                progressed = added || progressed
                if added || kept.contains(before) { before -= 1 }
            }
            if !progressed {
                break
            }
        }

        return kept
    }

    private static func tailIndexes(
        lines: [TreeLine],
        budget: Int,
        requiredIndexes: Set<Int>
    ) -> Set<Int> {
        var kept = requiredIndexes.filter { lines.indices.contains($0) }
        var used = kept.reduce(0) { $0 + lines[$1].chars }
        for line in lines.reversed() {
            if kept.contains(line.index) { continue }
            guard used + line.chars <= budget else { break }
            kept.insert(line.index)
            used += line.chars
        }
        return kept
    }

    private static func tryAdd(
        index: Int,
        lines: [TreeLine],
        kept: inout Set<Int>,
        sideBudget: inout Int,
        used: inout Int,
        totalBudget: Int
    ) -> Bool {
        guard lines.indices.contains(index), !kept.contains(index) else { return false }
        let cost = lines[index].chars
        guard cost <= sideBudget, used + cost <= totalBudget else { return false }
        kept.insert(index)
        used += cost
        sideBudget -= cost
        return true
    }

    private static func ancestorIndexes(lines: [TreeLine], anchorIndex: Int) -> Set<Int> {
        var ancestors: Set<Int> = []
        var minDepth = lines[anchorIndex].depth
        guard anchorIndex > 0 else { return ancestors }
        for index in stride(from: anchorIndex - 1, through: 0, by: -1) {
            if lines[index].depth < minDepth {
                ancestors.insert(index)
                minDepth = lines[index].depth
                if minDepth == 0 { break }
            }
        }
        return ancestors
    }

    private static func assemble(lines: [TreeLine], kept: Set<Int>) -> String {
        let indexes = kept.sorted()
        guard !indexes.isEmpty else { return "" }
        var output: [String] = []
        var previous: Int?
        for index in indexes {
            if let previous, index != previous + 1 {
                output.append(elisionLine(lines[(previous + 1)..<index]))
            } else if previous == nil, index > 0 {
                output.append(elisionLine(lines[0..<index]))
            }
            output.append(lines[index].text)
            previous = index
        }
        if let last = indexes.last, last < lines.count - 1 {
            output.append(elisionLine(lines[(last + 1)..<lines.count]))
        }
        return output.joined(separator: "\n")
    }

    private static func elisionLine(_ omitted: ArraySlice<TreeLine>) -> String {
        let chars = omitted.reduce(0) { $0 + $1.chars }
        return "[... \(omitted.count) lines / \(chars) chars omitted ...]"
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
