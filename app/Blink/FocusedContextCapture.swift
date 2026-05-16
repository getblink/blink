import AppKit
import ApplicationServices
import Foundation

enum FocusedContextCapture {
    enum TextTargetDecision {
        case textTarget
        case confidentNoTextTarget
    }

    struct Snapshot {
        let uploadPayload: [String: Any]
        let meaningfulDraftText: String?
        /// Focused element bounds in AppKit-screen coordinates (origin
        /// bottom-left, +Y up). Differs from `uploadPayload["bounds"]`,
        /// which is left in the raw AX top-left-origin frame for the
        /// server. `nil` when AX is denied or no element is focused.
        let focusedBoundsScreen: CGRect?
        /// Caret position in AppKit-screen coordinates. Already Y-flipped.
        let caretScreenPoint: CGPoint?
        /// One of: `native_ax`, `chromium_input`, `chromium_contenteditable`,
        /// `electron_partial`, `terminal_none`, `unknown`. Drives
        /// per-app marker gating in ScreenAnnotator and instructs the
        /// model on how much to trust caret_prefix/caret_suffix.
        let sourceConfidence: String
    }

    /// Max UTF-16 code units of `value` carried before/after the caret.
    /// Tuned so a single beat (sentence or chat reply prefix) almost
    /// always fits while staying well below `value`'s 1000-char upload
    /// cap so the model isn't fighting for budget.
    static let caretPrefixLimit = 200
    static let caretSuffixLimit = 100

    static func capture(allowContentRetention: Bool) -> [String: Any] {
        captureSnapshot(allowContentRetention: allowContentRetention).uploadPayload
    }

    static func captureSnapshot(allowContentRetention: Bool) -> Snapshot {
        guard AXIsProcessTrusted() else {
            return Snapshot(
                uploadPayload: [
                    "permission_status": "denied",
                    "warnings": ["accessibility_not_trusted"],
                    "source_confidence": "unknown",
                ],
                meaningfulDraftText: nil,
                focusedBoundsScreen: nil,
                caretScreenPoint: nil,
                sourceConfidence: "unknown"
            )
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let focusedError = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard focusedError == .success, let rawFocused = focusedRef else {
            return Snapshot(
                uploadPayload: [
                    "permission_status": "granted",
                    "warnings": ["no_focused_ui_element"],
                    "source_confidence": "unknown",
                ],
                meaningfulDraftText: nil,
                focusedBoundsScreen: nil,
                caretScreenPoint: nil,
                sourceConfidence: "unknown"
            )
        }
        let focused = rawFocused as! AXUIElement

        let role = shortenedRole(stringAttr(focused, kAXRoleAttribute as CFString))
        let value = stringAttr(focused, kAXValueAttribute as CFString)
        let selectedRange = selectedRangeAttr(focused)

        var payload: [String: Any] = [
            "permission_status": "granted",
            "role": role as Any,
            "subrole": stringAttr(focused, kAXSubroleAttribute as CFString) as Any,
            "title": stringAttr(focused, kAXTitleAttribute as CFString) as Any,
            "description": stringAttr(focused, kAXDescriptionAttribute as CFString) as Any,
            "label": stringAttr(focused, kAXLabelValueAttribute as CFString) as Any,
            "placeholder": stringAttr(focused, "AXPlaceholderValue" as CFString) as Any,
            "value": value as Any,
            "selected_text": stringAttr(focused, kAXSelectedTextAttribute as CFString) as Any,
        ]
        let rawBounds = focusedBoundsRect(focused)
        if let bounds = rawBounds {
            payload["bounds"] = [
                "x": bounds.origin.x,
                "y": bounds.origin.y,
                "width": bounds.size.width,
                "height": bounds.size.height,
            ]
        }
        if let range = selectedRange {
            payload["selected_range"] = [
                "location": range.location,
                "length": range.length,
            ]
        }

        // caret_prefix / caret_suffix: the text immediately around the
        // caret, sliced UTF-16-safely so the model can paste a continuation
        // without having to re-derive what comes before/after itself.
        // Routed through `sanitizeForUpload` so redaction-default users
        // still drop them. Empty results are omitted to keep the payload
        // shape stable.
        let slices = caretSlices(
            value: value,
            selectedRange: selectedRange,
            prefixLimit: caretPrefixLimit,
            suffixLimit: caretSuffixLimit
        )
        if let prefix = slices.prefix { payload["caret_prefix"] = prefix }
        if let suffix = slices.suffix { payload["caret_suffix"] = suffix }

        let caretPoint = caretScreenPoint()
        if let caret = caretPoint {
            payload["caret_screen_point"] = [
                "x": caret.x,
                "y": caret.y,
                "coordinate_space": "appkit_screen",
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
        var bundleID: String?
        if AXUIElementGetPid(focused, &pid) == .success,
           let app = NSRunningApplication(processIdentifier: pid) {
            payload["app_name"] = app.localizedName as Any
            bundleID = app.bundleIdentifier
            payload["bundle_id"] = bundleID as Any
        }

        let confidence = deriveSourceConfidence(
            bundleID: bundleID,
            role: role,
            valueLength: (value ?? "").utf16.count,
            selectedRange: selectedRange
        )
        payload["source_confidence"] = confidence

        // Flip AX bounds (top-left origin, +Y down) into AppKit-screen
        // coords (bottom-left, +Y up) for ScreenAnnotator. Caret + mouse
        // are already AppKit-screen, so this puts every marker on the
        // same coord system before ScreenAnnotator does its image-pixel
        // translation.
        let screenBounds = rawBounds.flatMap { axBoundsToScreen($0) }

        return Snapshot(
            uploadPayload: sanitizeForUpload(payload, allowContentRetention: allowContentRetention),
            meaningfulDraftText: meaningfulDraft,
            focusedBoundsScreen: screenBounds,
            caretScreenPoint: caretPoint,
            sourceConfidence: confidence
        )
    }

    /// Slice `value` around `selectedRange.location` and emit
    /// `prefix` / `suffix` strings, taking up to `prefixLimit` UTF-16
    /// code units before the caret and `suffixLimit` after the
    /// selection end. UTF-16 indices come from AX directly; `String(
    /// decoding:as:)` replaces any orphan surrogate with U+FFFD so a
    /// boundary mid-grapheme yields a valid string instead of crashing.
    static func caretSlices(
        value: String?,
        selectedRange: CFRange?,
        prefixLimit: Int,
        suffixLimit: Int
    ) -> (prefix: String?, suffix: String?) {
        guard let value, let range = selectedRange else { return (nil, nil) }
        guard range.location >= 0, range.length >= 0 else { return (nil, nil) }
        let totalUTF16 = value.utf16.count
        guard range.location <= totalUTF16,
              range.location + range.length <= totalUTF16 else {
            return (nil, nil)
        }
        let codeUnits = Array(value.utf16)
        let caretAt = range.location
        let selectionEnd = range.location + range.length

        let prefixStart = max(0, caretAt - prefixLimit)
        let prefix: String?
        if caretAt > prefixStart {
            let slice = Array(codeUnits[prefixStart..<caretAt])
            let decoded = String(decoding: slice, as: UTF16.self)
            prefix = decoded.isEmpty ? nil : decoded
        } else {
            prefix = nil
        }

        let suffixEnd = min(totalUTF16, selectionEnd + suffixLimit)
        let suffix: String?
        if suffixEnd > selectionEnd {
            let slice = Array(codeUnits[selectionEnd..<suffixEnd])
            let decoded = String(decoding: slice, as: UTF16.self)
            suffix = decoded.isEmpty ? nil : decoded
        } else {
            suffix = nil
        }

        return (prefix, suffix)
    }

    /// Derive a confidence label the model can use to weight the
    /// reliability of `caret_prefix`/`caret_suffix` in this surface.
    /// Cross-app reality (Hammerspoon notes, ghostty#9932, electron
    /// #22908, gemini-cli#16154):
    ///   - native AppKit + browser native inputs: AX is reliable
    ///   - Chromium contentEditable / Electron: AX returns `{0,0}` for
    ///     selectedTextRange even when value is non-empty
    ///   - Terminals: AXBoundsForRange unimplemented, caret semantics
    ///     don't exist as a "draft"
    static func deriveSourceConfidence(
        bundleID: String?,
        role: String?,
        valueLength: Int,
        selectedRange: CFRange?
    ) -> String {
        if let id = bundleID {
            if terminalBundles.contains(id) {
                return "terminal_none"
            }
            if chromiumBundlePrefixes.contains(where: { id.hasPrefix($0) }) {
                if roleLooksLikeTextInput(role) {
                    return "chromium_input"
                }
                return "chromium_contenteditable"
            }
            // Known-Electron allowlist: these apps wrap Electron / a
            // Chromium webview AND report AX data unreliably (focused
            // element often differs from the user's actual input, bounds
            // can be wildly off, selectedTextRange pinned at {0,0}).
            // The selection-shape probe below misses them when the value
            // happens to be empty. Caught dogfooding Conductor: AX
            // reported a TextArea at CG (-1183, 820) with value="" while
            // the user was typing into the chat input near the bottom of
            // the window.
            if knownElectronBundles.contains(id)
                || id.hasPrefix("com.todesktop.")
            {
                return "electron_partial"
            }
        }
        // Electron-flavored probe: a substantial value with selection
        // pinned at {0,0} is the signature of the Electron AX gap. The
        // 16-char floor avoids misfiring on short prefilled fields
        // (e.g. an email-shaped URL bar at caret-0 after Tab); 16 is
        // longer than typical default values but shorter than any
        // meaningful chat draft, so genuine Electron drafts still get
        // flagged.
        if valueLength >= 16,
           let range = selectedRange,
           range.location == 0,
           range.length == 0 {
            return "electron_partial"
        }
        if roleLooksLikeTextInput(role) {
            return "native_ax"
        }
        return "unknown"
    }

    /// Apps where AX caret queries are known broken or conceptually
    /// nonsensical. Drives "skip the caret marker entirely" in
    /// ScreenAnnotator and prompts the model not to trust caret_prefix.
    static let terminalBundles: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "com.warp.warp",
    ]

    /// Chromium-family browsers — native `<input>`/`<textarea>` work
    /// well, contentEditable doesn't. Listed as prefixes because Chrome
    /// has many channel-suffixed variants (`com.google.Chrome.canary`).
    static let chromiumBundlePrefixes: [String] = [
        "com.google.Chrome",
        "org.chromium.Chromium",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.thebrowser.Browser",   // Arc
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    /// Apps that wrap Electron / a Chromium webview and are observed
    /// to misreport AX focused-element data on macOS. Marker drawing is
    /// suppressed on these surfaces (bounds + caret) since drawing them
    /// in the wrong place is worse than not drawing — the model trusts
    /// what it sees. Mouse marker stays universal: `NSEvent.mouseLocation`
    /// doesn't go through AX.
    ///
    /// Extension hint: ToDesktop-wrapped apps (`com.todesktop.*`) are
    /// also matched via prefix in `deriveSourceConfidence`. If a new
    /// Electron app shows up dogfooding, add it here rather than
    /// trying to widen the {0,0} selection probe (that path catches
    /// legitimate native AppKit fields too).
    static let knownElectronBundles: Set<String> = [
        "com.conductor.app",            // Conductor
        "com.tinyspeck.slackmacgap",    // Slack desktop
        "com.hnc.Discord",              // Discord
        "com.microsoft.VSCode",         // VS Code
        "com.microsoft.VSCodeInsiders",
        "com.notion.id",                // Notion
        "com.linear.linear",            // Linear
        "com.figma.Desktop",            // Figma
        "WhatsApp",                     // WhatsApp desktop (legacy id)
        "net.whatsapp.WhatsApp",
        "com.spotify.client",           // Spotify
        "com.github.GitHubClient",      // GitHub Desktop
        "com.postmanlabs.mac",          // Postman
    ]

    /// Flip raw AX bounds (top-left origin, +Y down) into AppKit-screen
    /// coords (bottom-left, +Y up) using the primary display's height.
    /// Returns nil when no screen is attached.
    static func axBoundsToScreen(_ axBounds: CGRect) -> CGRect? {
        guard let primaryHeight = NSScreen.screens.first?.frame.height,
              primaryHeight.isFinite, primaryHeight > 0 else { return nil }
        let flippedY = primaryHeight - axBounds.origin.y - axBounds.size.height
        return CGRect(
            x: axBounds.origin.x,
            y: flippedY,
            width: axBounds.size.width,
            height: axBounds.size.height
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

    static func systemWideFocusedElement() -> AXUIElement? {
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
    static func candidateElements(starting focused: AXUIElement) -> [AXUIElement] {
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

    static func textTargetDecision(starting focused: AXUIElement) -> TextTargetDecision {
        // Bound the AX work: ⌘V is on the main thread after a 150ms delay,
        // and a slow/unresponsive AX app can stall the default 6s timeout.
        AXUIElementSetMessagingTimeout(focused, 0.1)
        let candidates = candidateElements(starting: focused)
        if hasResolvableCaret(candidates: candidates) {
            return .textTarget
        }
        // Belt-and-suspenders for native inputs that don't expose
        // AXBoundsForRange (rare but possible): if the focused element or
        // a focused-child candidate is itself a text-input-shaped role,
        // treat it as a paste target.
        for candidate in candidates {
            let role = stringAttr(candidate, kAXRoleAttribute as CFString)
            if roleLooksLikeTextInput(role) {
                return .textTarget
            }
        }
        let focusedRole = stringAttr(focused, kAXRoleAttribute as CFString)
        return textTargetDecision(focusedRole: focusedRole, descendantRoles: [])
    }

    /// True iff some candidate near the focused element exposes a real text
    /// caret via the parameterized `AXBoundsForRange` attribute. That
    /// attribute only succeeds when the element backs real text storage —
    /// read-only AXStaticText, selectable list rows, web spans, buttons,
    /// etc. fail — making this a much sharper "can ⌘V land here?" signal
    /// than role inspection. The bounds-approximation fallback used by
    /// `caretScreenPoint()` is intentionally skipped here: it returns a
    /// point for any input-shaped frame without confirming editability.
    private static func hasResolvableCaret(candidates: [AXUIElement]) -> Bool {
        // We only care about the *existence* of a caret rect, not its
        // coordinates, so the primary-screen height passed to
        // `caretFromRangeAttrs` doesn't have to be accurate — a non-nil
        // return is the signal. Default to 1 if no screen is attached
        // (headless) so the AXBoundsForRange call still runs.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1
        for candidate in candidates {
            if caretFromRangeAttrs(candidate, primaryHeight: primaryHeight) != nil {
                return true
            }
        }
        return false
    }

    static func textTargetDecision(
        focusedRole: String?,
        descendantRoles: [String]
    ) -> TextTargetDecision {
        if roleLooksLikeTextInput(focusedRole) || descendantRoles.contains(where: roleLooksLikeTextInput) {
            return .textTarget
        }
        return .confidentNoTextTarget
    }

    static func roleLooksLikeTextInput(_ role: String?) -> Bool {
        guard let role else { return false }
        let normalized = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        switch normalized {
        case "TextField", "TextArea", "ComboBox", "SearchField":
            return true
        default:
            return false
        }
    }

    static func roleIsContainer(_ role: String?) -> Bool {
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
        // caret_prefix / caret_suffix slicing already enforces a UTF-16
        // ceiling at extraction time, but bound again on character count
        // so the value's truncation policy doesn't get bypassed via the
        // caret slices. Limits match the upstream caretPrefixLimit /
        // caretSuffixLimit constants.
        sanitized = boundField("caret_prefix", limit: 200, in: sanitized)
        sanitized = boundField("caret_suffix", limit: 100, in: sanitized)

        guard !allowContentRetention else {
            return sanitized
        }

        sanitized = redactField("value", in: sanitized)
        sanitized = redactField("selected_text", in: sanitized)
        sanitized = redactField("nearby_relevant_text", in: sanitized)
        sanitized = redactField("caret_prefix", in: sanitized)
        sanitized = redactField("caret_suffix", in: sanitized)
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
