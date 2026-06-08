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
    /// Per-node value clamp for the inline-leaf / mixed-container path (head
    /// clamp, newlines flattened). Sole-carrier leaves — a node with NO children
    /// whose AXValue is the only copy of its text in the tree, e.g. a terminal or
    /// editor that dumps the whole document into one AXValue — get the far larger
    /// tail-preserving clamp instead; see `defaultLeafTailFraction`.
    static let defaultMaxValueChars = 1000
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
    /// Fraction of the text budget kept for a single sole-carrier leaf. Terminals
    /// and editors expose the entire document as one AXValue with no children, so
    /// the small per-node clamp above would amputate ~99% of it. We keep the TAIL
    /// (live content sits at the bottom; the caret is unavailable on terminals)
    /// with newlines intact. Derived from `defaultTextBudgetChars` so retuning the
    /// budget carries the leaf cap with it instead of leaving a stale constant.
    static let defaultLeafTailFraction = 0.5

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
        kAXURLAttribute as String,
        kAXDocumentAttribute as String,
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
        let leafTailChars = Int(Double(textBudgetChars) * defaultLeafTailFraction)

        // Is a child's entire subtree foldable into its ancestor's single line —
        // i.e. pure text with nothing of its own to emit? True for a plain-text
        // leaf (StaticText/ListMarker), or an empty structural node (no
        // name/value/url — see `formatLine`) whose whole subtree is likewise pure
        // text. False the moment we hit something that emits its own line (a link,
        // a named/valued node, an image with a label): that must be preserved, so
        // its ancestor can't be folded away. An empty, childless decorative node
        // (unnamed image, presentational span) emits nothing and contributes no
        // text, so it is ignorable (true) and never blocks the fold. Bounded by
        // `maxDepth`.
        func subtreeIsPureText(_ element: AXUIElement, _ attrs: [CFTypeRef?], depth: Int) -> Bool {
            if let role = shortenRole(attrs[0] as? String), plainTextLeafRoles.contains(role) {
                return true
            }
            let hasName = (((attrs[2] as? String)?.nonBlank) ?? ((attrs[3] as? String)?.nonBlank)) != nil
            let hasValue = stringValue(attrs[4]) != nil
            let hasURL = (displayURL(attrs[5]) ?? displayURL(attrs[6])) != nil
            guard !hasName, !hasValue, !hasURL, depth < maxDepth else { return false }
            let kids = childrenOf(element)
            guard !kids.isEmpty else { return true }
            return kids.allSatisfy {
                subtreeIsPureText($0, copyMultiple($0, nodeAttributes), depth: depth + 1)
            }
        }

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
            // Link/document destination (AXURL ?? AXDocument). The visible text
            // alone ("Open PR") doesn't tell the model where a link points; the
            // URL does. Route/shell noise is dropped in `displayURL`.
            let url = displayURL(attrs[5]) ?? displayURL(attrs[6])
            let name = title ?? desc

            // Fetch children + their attributes once; reused for both the
            // collapse decision below and the recursive descent (no double IPC).
            let children = depth < maxDepth ? childrenOf(element) : []
            let childAttrs = children.map { copyMultiple($0, nodeAttributes) }

            // De-duplication / de-fragmentation. WebKit/Chromium shatter a link's,
            // heading's, list item's, or paragraph's text across many plain-text
            // leaves (one per inline span). When this node's WHOLE subtree is pure
            // text, that text is recoverable as one correctly-spaced line, so we
            // emit it once and skip the fragmented children. Capability-probed
            // chain (no app/bundle sniffing):
            //   Tier 1 — the node already rolls the text up into its own name
            //            (link accname, heading) or value (textarea, list item):
            //            keep that line, drop the children. A too-long value is
            //            dropped instead so the children carry it in full
            //            (formatLine doesn't clamp names, so names always collapse).
            //   Tier 0 — an empty structural wrapper with no name/value of its own
            //            (a web <p>/<div>): synthesize the line from the element's
            //            AXStringForTextMarkerRange, WebKit's rendered text with
            //            inline spans correctly spaced. `textMarkerLine` returns nil
            //            for multi-line results so we fold at paragraph granularity,
            //            and nil on native surfaces (no text markers).
            //   else  — empty wrapper, no marker (native, fragmented, rare): leave
            //            the fragments rather than risk a lossy join.
            var value = rawValue
            var descend = true
            if !children.isEmpty,
               zip(children, childAttrs).allSatisfy({ subtreeIsPureText($0.0, $0.1, depth: depth + 1) }) {
                if let name {
                    descend = false
                    // Guard the one case folding-into-name can lose text: an
                    // aria-label `name` that diverges from the visible child text
                    // (the rolled-up name is NOT a superset). When the rendered
                    // text isn't already covered by the name, surface it in the
                    // value so it survives. No-op for the common name-from-content
                    // case, and on native (no marker).
                    if let rendered = textMarkerLine(for: element),
                       !name.filter({ !$0.isWhitespace }).contains(rendered.filter { !$0.isWhitespace }) {
                        value = rendered
                    }
                } else if let rawValue {
                    if rawValue.count > defaultCollapseValueChars { value = nil } else { descend = false }
                } else if let paragraph = textMarkerLine(for: element) {
                    value = paragraph
                    descend = false
                }
            }
            // Sole-carrier leaf: no children to fall back on, so this value is the
            // ONLY copy of its text in the tree. Clamp gently — keep the TAIL and
            // preserve newlines (see `tailClamped`) instead of the small head
            // clamp that would amputate a terminal/editor buffer.
            let clampedValue: String?
            if children.isEmpty, let leafValue = value, leafValue.count > maxValueChars {
                clampedValue = leafValue.tailClamped(to: leafTailChars)
            } else {
                clampedValue = value?.clamped(to: descend ? maxValueChars : defaultCollapseValueChars)
            }

            // Collapse empty structural wrappers: a node with no name and no
            // value carries no content of its own, so emit nothing and keep its
            // children at the current indent.
            let childIndent: Int
            if let line = formatLine(role: role, roleDesc: roleDesc, name: name, value: clampedValue, url: url, indent: indent) {
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

    /// WebKit/Chromium's rendered text for an element's whole subtree, as a single
    /// trimmed line, via the text-marker parameterized attributes. This is the
    /// ground-truth string the engine lays out, so inline spans come back
    /// contiguous and correctly spaced — no fragment-joining heuristic. Returns nil
    /// when:
    ///   - the surface has no text markers (native AppKit views), or
    ///   - the result spans multiple lines (a multi-paragraph container) — we fold
    ///     at paragraph granularity, so a multi-line result means "descend and let
    ///     each paragraph fold on its own" rather than merging them.
    /// Object-replacement placeholders (`U+FFFC`, inline images) are stripped; the
    /// caller only invokes this for pure-text subtrees, where they shouldn't occur.
    private static func textMarkerLine(for element: AXUIElement) -> String? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, "AXTextMarkerRangeForUIElement" as CFString, element, &rangeRef) == .success,
              let rangeRef else { return nil }
        var stringRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, "AXStringForTextMarkerRange" as CFString, rangeRef, &stringRef) == .success,
              let string = stringRef as? String else { return nil }
        let stripped = string.replacingOccurrences(of: "\u{FFFC}", with: "")
        guard !stripped.contains("\n"), !stripped.contains("\r") else { return nil }
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
        url: String?,
        indent: Int
    ) -> String? {
        if name == nil, value == nil, url == nil {
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
        // Link/document destination, after name/value so the model can resolve
        // where a link goes. Suppressed when the name or value already conveys
        // the same href (with or without scheme) — e.g. a bare-URL link whose
        // visible text IS the URL — so we don't print it twice.
        if let url {
            func echoesURL(_ s: String?) -> Bool {
                guard let s else { return false }
                return s == url || s.hasSuffix("://" + url)
            }
            if !echoesURL(name), !echoesURL(value) {
                line += " (\(url))"
            }
        }
        return line
    }

    /// A link/document destination worth surfacing, or nil for noise. Drops
    /// app-internal route schemes (`tauri://`, `app://`, `devtools://`,
    /// `chrome-extension://`, `blob:`, `data:`, `about:`) and the Electron
    /// `file://…index.html` shell — on Tauri/Electron surfaces these dominate
    /// (a Conductor capture is ~33 `tauri://` routes to ~4 real links), so
    /// emitting them raw would be pure token noise. Strips the `http(s)://`
    /// scheme for economy and caps length so a tracking-query URL can't blow the
    /// budget. Returning nil keeps a route-only node collapsing as before.
    private static func displayURL(_ ref: CFTypeRef?) -> String? {
        let raw: String
        if let url = ref as? URL {
            raw = url.absoluteString
        } else if let string = ref as? String {
            raw = string
        } else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        for noise in ["tauri://", "app://", "devtools://", "chrome-extension://", "blob:", "data:", "about:"] {
            if lower.hasPrefix(noise) { return nil }
        }
        if lower.hasPrefix("file://"), lower.hasSuffix("index.html") { return nil }
        var stripped = trimmed
        for scheme in ["https://", "http://"] where stripped.lowercased().hasPrefix(scheme) {
            stripped = String(stripped.dropFirst(scheme.count))
            break
        }
        guard !stripped.isEmpty else { return nil }
        let cap = 180
        return stripped.count > cap ? String(stripped.prefix(cap)) + "…" : stripped
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

    /// Clamp to `limit` characters by keeping the TAIL, with newlines preserved.
    /// Used for sole-carrier leaves (terminals, editors) where the live content
    /// sits at the end and the line structure carries meaning. Prepends an
    /// ellipsis when cut. The retained newlines mean the emitted node spans
    /// several physical lines; the budget windower treats it as one unit, which is
    /// fine because the suffix is already bounded to `limit`.
    func tailClamped(to limit: Int) -> String {
        guard count > limit else { return self }
        return "…" + String(suffix(limit))
    }
}
