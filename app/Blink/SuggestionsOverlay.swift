import AppKit

enum OverlayArrowDirection {
    case up
    case down
}

final class SuggestionsPanel: NSPanel {
    var onLocalKeyDown: ((NSEvent) -> Bool)?
    weak var customReplyField: CustomReplyField?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let field = customReplyField,
           field.isEditing,
           field.performTextFieldKeyEquivalent(with: event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        // Selectable suggestion text means the window's field editor can be
        // first responder while the overlay is up — give the overlay router
        // first crack at keyDowns so 1-4/Enter/Esc keep steering the panel
        // even when text is selected. Router already handles the
        // customInputActive case, so this is a no-op for typing into the
        // custom reply field.
        if event.type == .keyDown {
            if onLocalKeyDown?(event) == true {
                return
            }
            // Router didn't match. If the custom-input field is the active
            // editor, let the event reach it for typing/native shortcuts.
            // Otherwise swallow: the first responder is most likely a
            // selectable suggestion text field's field editor, whose
            // default `keyDown` calls NSResponder.beep() on unmatched
            // keys — and the user reads that as a "boop" sitting on top
            // of the Blink chime. The panel's own `keyDown` override
            // already implements this swallow, but `sendEvent` skips it
            // when a child field editor is first responder.
            if customReplyField?.isEditing != true {
                return
            }
        }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        if onLocalKeyDown?(event) == true {
            return
        }
        // Swallow unhandled keys while the panel is the key window so stray
        // characters don't beep via NSResponder's default chain or leak past
        // the modal. When the panel isn't key (e.g. loading or collecting
        // states), preserve the original passthrough behavior.
        if isKeyWindow {
            return
        }
        super.keyDown(with: event)
    }
}

/// Body text of a suggestion card. Selectable so users can copy out a
/// suggestion, but with click-vs-drag detection so a plain click still
/// behaves like the card click (insert) and only an actual drag enters
/// native text selection.
private final class SelectableSuggestionTextField: NSTextField {
    var onClick: (() -> Void)?
    private static let dragThreshold: CGFloat = 4.0

    override func mouseDown(with event: NSEvent) {
        // Double / triple click flips to word / line selection; let AppKit
        // own that path so users keep the standard selection gestures.
        if event.clickCount > 1 {
            super.mouseDown(with: event)
            return
        }
        guard let window else {
            super.mouseDown(with: event)
            return
        }
        let startPoint = event.locationInWindow
        let mask: NSEvent.EventTypeMask = [.leftMouseUp, .leftMouseDragged]
        let thresholdSquared = Self.dragThreshold * Self.dragThreshold
        while let next = window.nextEvent(matching: mask) {
            switch next.type {
            case .leftMouseDragged:
                let dx = next.locationInWindow.x - startPoint.x
                let dy = next.locationInWindow.y - startPoint.y
                if dx * dx + dy * dy >= thresholdSquared {
                    // Hand off to native drag-selection from the original
                    // mouseDown so AppKit's tracking loop anchors at the
                    // initial click location.
                    super.mouseDown(with: event)
                    return
                }
            case .leftMouseUp:
                onClick?()
                return
            default:
                break
            }
        }
    }
}

private final class MultilineInputTextView: NSTextView {
    var onFocusChanged: ((Bool) -> Void)?
    var onKeyDown: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocusChanged?(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { onFocusChanged?(false) }
        return result
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}

final class CustomReplyField: NSView, NSTextViewDelegate {
    var onFocusChanged: ((Bool) -> Void)?
    var onLocalKeyDown: ((NSEvent) -> Bool)?
    var onTextChanged: ((String) -> Void)?
    var onContentHeightChanged: ((CGFloat) -> Void)?

    private(set) var scrollView: NSScrollView!
    private(set) var textView: NSTextView!
    private var placeholderLabel: NSTextField!
    private var lastContentHeight: CGFloat = 0

    var stringValue: String {
        get { textView.string }
        set {
            textView.string = newValue
            updatePlaceholder()
            checkContentHeight()
        }
    }

    var placeholderAttributedString: NSAttributedString? {
        didSet { updatePlaceholder() }
    }

    var font: NSFont? {
        get { textView.font }
        set { textView.font = newValue }
    }

    var textColor: NSColor? {
        get { textView.textColor }
        set { textView.textColor = newValue }
    }

    var isEditing: Bool {
        window?.firstResponder === textView
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        return window?.makeFirstResponder(textView) ?? false
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        let textContainer = NSTextContainer(
            size: NSSize(width: frame.width, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 0

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)

        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        let inner = MultilineInputTextView(
            frame: NSRect(origin: .zero, size: frame.size),
            textContainer: textContainer
        )
        inner.isRichText = false
        inner.isAutomaticQuoteSubstitutionEnabled = false
        inner.isAutomaticDashSubstitutionEnabled = false
        inner.isAutomaticTextCompletionEnabled = false
        inner.drawsBackground = false
        inner.textContainerInset = .zero
        inner.isVerticallyResizable = true
        inner.isHorizontallyResizable = false
        inner.autoresizingMask = [.width]
        inner.insertionPointColor = .labelColor
        inner.onFocusChanged = { [weak self] focused in
            self?.onFocusChanged?(focused)
        }
        inner.onKeyDown = { [weak self] event in
            self?.onLocalKeyDown?(event) ?? false
        }
        inner.delegate = self

        let sv = NSScrollView(frame: NSRect(origin: .zero, size: frame.size))
        sv.documentView = inner
        sv.hasVerticalScroller = false
        sv.hasHorizontalScroller = false
        sv.drawsBackground = false
        sv.borderType = .noBorder
        sv.autoresizingMask = [.width, .height]
        sv.contentView.drawsBackground = false

        let placeholder = NSTextField(labelWithString: "")
        placeholder.isEditable = false
        placeholder.isBordered = false
        placeholder.drawsBackground = false
        placeholder.textColor = .secondaryLabelColor
        placeholder.lineBreakMode = .byTruncatingTail
        placeholder.frame = NSRect(origin: .zero, size: frame.size)

        addSubview(sv)
        addSubview(placeholder)

        self.scrollView = sv
        self.textView = inner
        self.placeholderLabel = placeholder
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        placeholderLabel.frame = NSRect(
            x: 0, y: 0, width: bounds.width, height: bounds.height
        )
        textView.minSize = NSSize(width: 0, height: bounds.height)
        textView.maxSize = NSSize(
            width: bounds.width, height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.containerSize = NSSize(
            width: bounds.width, height: CGFloat.greatestFiniteMagnitude
        )
    }

    func contentTextHeight() -> CGFloat {
        guard let lm = textView.layoutManager,
              let tc = textView.textContainer else {
            return SuggestionsOverlay.customInputTextHeight
        }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        return max(ceil(used.height), SuggestionsOverlay.customInputTextHeight)
    }

    private func checkContentHeight() {
        let h = contentTextHeight()
        if h != lastContentHeight {
            lastContentHeight = h
            onContentHeightChanged?(h)
        }
    }

    private func updatePlaceholder() {
        let empty = textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        placeholderLabel.isHidden = !empty
        if let attr = placeholderAttributedString {
            placeholderLabel.attributedStringValue = attr
        }
    }

    // MARK: - NSTextViewDelegate

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            return false
        }
        if commandSelector == #selector(NSResponder.insertTab(_:))
            || commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            return true
        }
        return false
    }

    func textDidChange(_ notification: Notification) {
        updatePlaceholder()
        checkContentHeight()
        onTextChanged?(stringValue)
    }

    // MARK: - Key equivalents

    func performTextFieldKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              flags.intersection([.control, .option]).isEmpty,
              let characters = event.charactersIgnoringModifiers?.lowercased(),
              ["a", "c", "v", "x"].contains(characters)
        else {
            return false
        }
        return textView.performKeyEquivalent(with: event)
    }

    func performTextEditingShortcut(_ shortcut: TextEditingShortcut) -> Bool {
        switch shortcut {
        case .selectAll: textView.selectAll(nil)
        case .copy: textView.copy(nil)
        case .paste: textView.paste(nil)
        case .cut: textView.cut(nil)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onTextChanged?(self.stringValue)
        }
        return true
    }
}

private final class SuggestionCardClickTarget: NSObject {
    let index: Int
    let onClick: (Int) -> Void

    init(index: Int, onClick: @escaping (Int) -> Void) {
        self.index = index
        self.onClick = onClick
    }

    @objc func clicked(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        onClick(index)
    }
}

final class SuggestionsOverlay: NSObject {
    private enum CustomInputMode: Equatable {
        case followUp
        case write
    }

    private enum Layout {
        static let panelWidth: CGFloat = 560
        static let shadowBleed: CGFloat = 36
        static let summaryMinHeight: CGFloat = 144
        static let loadingMinHeight: CGFloat = 56
        static let loadingDotSize: CGFloat = 8
        static let loadingDotTextGap: CGFloat = 10
        static let sectionGap: CGFloat = 14
        static let suggestionGap: CGFloat = 8
        static let summaryFontSize: CGFloat = 16
        static let suggestionFontSize: CGFloat = 16
        static let tagFontSize: CGFloat = 12
        static let hintFontSize: CGFloat = 12
        static let summaryTopInset: CGFloat = 26
        static let summaryBottomInset: CGFloat = 18
        static let summaryHintHeight: CGFloat = 18
        static let summaryHintGap: CGFloat = 12
        static let refreshPillHeight: CGFloat = 62
        static let thumbStripHeight: CGFloat = 56
        static let thumbStripGap: CGFloat = 6
        static let summaryLineSpacing: CGFloat = 7
        static let summaryHeaderBottomGap: CGFloat = 4
        static let bottomHintHeight: CGFloat = 18
        static let bottomHintTopGap: CGFloat = 14
        static let cardPaddingX: CGFloat = 24
        static let suggestionCollapsedHeight: CGFloat = 98
        static let suggestionCollapsedHeightWithoutTags: CGFloat = 76
        static let suggestionSingleLineHeight: CGFloat = 62
        static let suggestionSingleLineHeightWithTags: CGFloat = 76
        static let suggestionCornerRadius: CGFloat = 22
        static let customInputMinHeight: CGFloat = 62
        static let customInputMaxHeight: CGFloat = 24 * 5 + 38 // ~5 lines + vertical padding
        static let customInputTextHeight: CGFloat = 24
        static let customModeWidth: CGFloat = 148
        static let customModeFollowUpWidth: CGFloat = 88
        static let customModeGap: CGFloat = 14
        static let customModeButtonHeight: CGFloat = 28
        static let suggestionSingleLineTextHeight: CGFloat = 24
        static let suggestionNumberX: CGFloat = 20
        static let suggestionNumberWidth: CGFloat = 28
        static let suggestionNumberHeight: CGFloat = 24
        static let suggestionTextX: CGFloat = 68
        static let suggestionCollapsedTextHeight: CGFloat = 42
        static let suggestionTagHeight: CGFloat = 17
        static let suggestionTagGap: CGFloat = 4
        static let tagIconSize: CGFloat = 12
        static let tagIconGap: CGFloat = 5
        static let suggestionLineSpacing: CGFloat = 5
        static let suggestionBottomPaddingExpanded: CGFloat = 28
        static let attachmentChipHeight: CGFloat = 22
        static let attachmentChipBottomInset: CGFloat = 28
        static let attachmentChipGap: CGFloat = 8
        static let attachmentChipMaxLabelWidth: CGFloat = 180
        static let attachmentChipIconSize: CGFloat = 13
        static let attachmentChipIconLabelGap: CGFloat = 5
        static let attachmentChipPaddingX: CGFloat = 8
        static let attachmentChipSpacing: CGFloat = 6
        static let attachmentChipFontSize: CGFloat = 11

        static func expandedBottomPadding(hasAttachments: Bool) -> CGFloat {
            hasAttachments
                ? suggestionBottomPaddingExpanded + attachmentChipHeight + attachmentChipGap
                : suggestionBottomPaddingExpanded
        }
        static let enterHintWidth: CGFloat = 140
        static let enterHintHeight: CGFloat = 18
        static let enterHintRightInset: CGFloat = 24
        static let enterHintBottomInset: CGFloat = 4
        static let animationDuration: TimeInterval = 0.22
        static let momentDuration: TimeInterval = 0.34
        static let tagAlpha: CGFloat = 0.95
        // Collapsible summary (adaptive-length TL;DR). When the rendered tldr
        // exceeds the preview height we render a chevron toggle so the user
        // can opt into the full content; the expanded view scrolls internally
        // past `summaryExpandedMaxHeightRatio * screenHeight`.
        static let summaryPreviewLineCount: Int = 3
        static let summaryExpandButtonHeight: CGFloat = 22
        static let summaryExpandButtonGap: CGFloat = 4
        static let summaryExpandedMaxHeightRatio: CGFloat = 0.55

        static var suggestionPaddingY: CGFloat {
            (suggestionCollapsedHeight - suggestionCollapsedTextHeight) / 2
        }

        static func optionCornerRadius(for height: CGFloat) -> CGFloat {
            min(suggestionCornerRadius, height / 2)
        }
    }

    static let customInputTextHeight: CGFloat = Layout.customInputTextHeight

    private struct GlassPane {
        let outer: NSView
        let content: NSView
    }

    private struct SuggestionCard {
        let outer: NSView
        let content: NSView
        let tint: NSView
        let number: NSTextField
        let label: NSTextField
        let tagIcon: NSImageView
        let tagLabel: NSTextField
        let enterHint: NSTextField
        var collapsedFrame: NSRect
        let collapsedText: String
        let fullText: String
        let expandedHeight: CGFloat
        let hasTags: Bool
        let collapsedLabelHeight: CGFloat
        let collapsedSingleLine: Bool
        let attachments: [AttachmentRef]
        let attachmentChips: NSStackView?
    }

    private var panel: SuggestionsPanel?
    // Close handle for the active multi-frame submit-prompt pill. Set by
    // `showSubmitPrompt()`; invoked + cleared by `dismissSubmitPrompt()`
    // (or replaced if `showSubmitPrompt()` is called again).
    private var submitPromptClose: (() -> Void)?
    private var contentView: NSView?
    private var basePanelHeight: CGFloat = 0
    private var basePanelTopY: CGFloat = 0
    private var summaryCard: NSView?
    /// Inner content view of the summary glass pane. On macOS 26+,
    /// this is a separate NSView hosted as the NSGlassEffectView's
    /// contentView; on legacy macOS it's the NSVisualEffectView itself.
    /// Stashed so post-show updates (e.g. installing the suggestion
    /// hint after the streaming-loading transition) can add subviews
    /// to the right host.
    private var summaryContent: NSView?
    private var summaryLabel: NSTextField?
    private var refreshStatusPill: NSView?
    private var refreshStatusLabel: NSTextField?
    private var loadingPulseDot: NSView?
    private var isLoadingState: Bool = false
    private var isSuggestionRefreshing: Bool = false
    private var softErrorPanel: NSPanel?
    private var summaryBaseFrame: NSRect = .zero
    private var summaryTextY: CGFloat = 0
    private var suggestionCards: [SuggestionCard] = []
    private var customInputCard: NSView?
    private var customInputBaseFrame: NSRect = .zero
    private var customInputField: CustomReplyField?
    private var customInputNumber: NSTextField?
    private var customInputHintLabel: NSTextField?
    private var customInputTint: NSView?
    private var customInputMode: CustomInputMode = .followUp
    private var customFollowUpButton: NSButton?
    private var customWriteButton: NSButton?
    private var bottomHintLabel: NSTextField?
    private var bottomHintBaseFrame: NSRect = .zero
    private var showsTldrHeader: Bool = false
    private var suggestionClickTargets: [SuggestionCardClickTarget] = []
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var lastOutsideClickAt: TimeInterval = 0
    private var currentHeightDelta: CGFloat = 0
    private var customInputHeightDelta: CGFloat = 0
    private(set) var summaryFullText: String = ""
    private var summaryIsExpandable: Bool = false
    private var summaryIsExpanded: Bool = false
    private var summaryExpandButton: NSButton?
    private var summaryScrollView: NSScrollView?
    private var summaryTextView: NSTextView?
    private var summaryCollapsedHeight: CGFloat = 0
    private var summaryExpandedHeight: CGFloat = 0
    private var summaryHeightDelta: CGFloat = 0
    private(set) var previousFrontmost: NSRunningApplication?
    private var hasPlayedSuggestionArrival = false
    private var isDismissing = false
    private(set) var expandedSuggestionIndex: Int?
    /// When true, picking a suggestion (or custom-reply submit) pastes into
    /// the previous app *without* dismissing the overlay. Esc still dismisses.
    /// Toggled via Cmd+P.
    private(set) var isPinned: Bool = false
    private var summaryHintLabel: NSTextField?
    private var summaryHintBaseText: String?

    var onCustomInputFocusChanged: ((Bool) -> Void)?
    var onCustomInsert: ((String) -> Void)?
    var onCustomFollowUp: ((String) -> Void)?
    var onChoiceKey: ((Int) -> Void)?
    var onArrowKey: ((OverlayArrowDirection) -> Void)?
    var onInsertKey: (() -> Bool)?
    var onCustomInsertKey: (() -> Bool)?
    var onLeaveCustomInputKey: (() -> Void)?
    var onTextEditingKey: ((TextEditingShortcut) -> Bool)?
    var onRerollKey: (() -> Void)?
    var onTogglePinKey: (() -> Void)?
    /// Implicit dismiss path — double-click outside the panel. The
    /// coordinator routes this to `dismissOverlay(implicit: true)`
    /// so the LDS snapshot is tagged as auto-resume eligible. Esc
    /// continues to call `onDismissKey` (explicit).
    var onOutsideClickDismiss: (() -> Void)?
    var onDismissKey: (() -> Void)?
    var onVisibilityChange: ((Bool) -> Void)?
    var onPinnedChanged: ((Bool) -> Void)?
    private var lastEmittedVisible = false

    var isVisible: Bool {
        panel?.isVisible == true
    }

    var customInputSubmitsFollowUp: Bool {
        customInputMode == .followUp
    }

    /// True when the overlay is on screen and has already promoted past the
    /// loading layout (i.e. streaming has produced a real summary). Callers
    /// use this to push final stream values through `updateSummary` /
    /// `updateSuggestions` instead of re-running `show(...)`, which would
    /// destroy and rebuild the panel and produce a visible flicker.
    var isStreamingActive: Bool {
        isVisible && !isLoadingState
    }

    private func collapsedHeight(for detail: SuggestionDetail, width: CGFloat, font: NSFont) -> CGFloat {
        let hasTags = !renderTags(detail.tags).isEmpty
        let isSingleLine = collapsedTextIsSingleLine(for: detail, width: width, font: font)
        if hasTags {
            return isSingleLine ? Layout.suggestionSingleLineHeightWithTags : Layout.suggestionCollapsedHeight
        }
        return isSingleLine ? Layout.suggestionSingleLineHeight : Layout.suggestionCollapsedHeightWithoutTags
    }

    private func collapsedTextHeight(for detail: SuggestionDetail, width: CGFloat, font: NSFont) -> CGFloat {
        collapsedTextIsSingleLine(for: detail, width: width, font: font)
            ? Layout.suggestionSingleLineTextHeight
            : Layout.suggestionCollapsedTextHeight
    }

    private func collapsedTextIsSingleLine(for detail: SuggestionDetail, width: CGFloat, font: NSFont) -> Bool {
        let measuredTextHeight = measureHeight(detail.text, width: width, font: font, lineSpacing: 2)
        let singleLineHeight = ceil(font.ascender - font.descender + font.leading) + 6
        return measuredTextHeight <= singleLineHeight
    }

    private func collapsedTextIsTruncated(for detail: SuggestionDetail, width: CGFloat, font: NSFont) -> Bool {
        let measuredTextHeight = measureHeight(detail.text, width: width, font: font, lineSpacing: 2)
        let collapsedHeight = collapsedTextHeight(for: detail, width: width, font: font)
        return measuredTextHeight > collapsedHeight + 1
    }

    private func collapsedDisplayText(for detail: SuggestionDetail, width: CGFloat, font: NSFont) -> String {
        guard collapsedTextIsTruncated(for: detail, width: width, font: font) else {
            return detail.text
        }

        let collapsedHeight = collapsedTextHeight(for: detail, width: width, font: font)
        let source = detail.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = "..."
        guard source.count > suffix.count else { return source }

        var low = 0
        var high = source.count
        var best = suffix
        while low <= high {
            let mid = (low + high) / 2
            let end = source.index(source.startIndex, offsetBy: mid)
            let candidate = String(source[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + suffix
            let height = measureHeight(candidate, width: width, font: font, lineSpacing: 2)
            if height <= collapsedHeight + 1 {
                best = candidate
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best
    }

    func show(tldr: String, suggestions: [String]) {
        show(tldr: tldr, suggestionDetails: suggestions.map(SuggestionDetail.plain))
    }

    /// Bottom-of-summary hint while suggestions are visible.
    private static let suggestionHintText =
        "Press 1 / 2 / 3 to expand \u{00B7} \u{2318}R reroll \u{00B7} \u{2318}P pin \u{00B7} Esc dismiss"

    func show(tldr: String, suggestionDetails: [SuggestionDetail]) {
        show(
            tldr: tldr,
            suggestionDetails: suggestionDetails,
            showsCustomInput: true,
            hintText: Self.suggestionHintText,
            showsTldrHeader: true
        )
    }

    /// Toggle whether picking a suggestion (or submitting a custom reply)
    /// dismisses the overlay. When pinned, the insert lands in the prior
    /// app but the overlay stays open, ready for the next interaction.
    /// Esc still dismisses unconditionally.
    func setPinned(_ pinned: Bool) {
        guard pinned != isPinned else { return }
        isPinned = pinned
        refreshHintLabel()
        onPinnedChanged?(pinned)
    }

    /// Clear the rendered suggestion stack and reset choice state, but
    /// leave the panel visible. Used by the pinned-insert path: the
    /// previous suggestions are no longer relevant once one was inserted,
    /// but the user wants the overlay to stay alive for the next capture.
    @MainActor
    func resetAfterInsertKeepOpen() {
        expandedSuggestionIndex = nil
        suggestionCards = []
        suggestionClickTargets = []
        hasPlayedSuggestionArrival = false
        show(
            tldr: "Pinned — press the hotkey to add a new capture.",
            suggestionDetails: [],
            showsCustomInput: false,
            hintText: "\u{2318}P unpin \u{00B7} Esc dismiss",
            showsTldrHeader: true
        )
    }

    private func composedHintText(base: String) -> String {
        if isPinned {
            return "\u{1F4CC} pinned \u{00B7} " + base
        }
        return base
    }

    private func refreshHintLabel() {
        guard let label = summaryHintLabel, let base = summaryHintBaseText else {
            return
        }
        label.stringValue = composedHintText(base: base)
    }

    /// Install the bottom-of-summary hint label on demand. Used by the
    /// streaming-loading → suggestions transition (`updateSummary`'s
    /// `wasLoading` branch): `showLoading` set `hintText: nil`, so the
    /// label was never created during the initial show(). Adding it now
    /// without rebuilding the whole panel avoids the flicker the
    /// in-place-update path was designed to prevent.
    private func installSuggestionHintIfNeeded(_ baseText: String) {
        guard summaryHintLabel == nil, let host = summaryContent else { return }
        let hintFont = NSFont.systemFont(ofSize: Layout.hintFontSize)
        let contentWidth = Layout.panelWidth
        self.summaryHintBaseText = baseText
        let hint = label(
            frame: NSRect(
                x: 24,
                y: Layout.summaryBottomInset,
                width: contentWidth - 48,
                height: Layout.summaryHintHeight
            ),
            text: composedHintText(base: baseText),
            font: hintFont,
            color: .tertiaryLabelColor,
            singleLine: true
        )
        hint.alignment = .center
        host.addSubview(hint)
        self.summaryHintLabel = hint
    }

    func showLoading(tldr: String) {
        show(
            tldr: tldr,
            suggestionDetails: [],
            showsCustomInput: false,
            hintText: nil,
            showsTldrHeader: true,
            isLoading: true
        )
    }

    func showCollecting(
        frameCount: Int,
        maxFrames: Int,
        hotkeyDisplay: String,
        thumbnails: [NSImage] = [],
        message: String? = nil,
        flashLastThumbnail: Bool = false
    ) {
        let lead = message ?? "Collecting"
        show(
            tldr: "\(lead). \(frameCount) of \(maxFrames) frames.",
            suggestionDetails: [],
            showsCustomInput: false,
            hintText: "\(hotkeyDisplay) to add, Return to submit, Esc to cancel",
            thumbnails: thumbnails,
            flashLastThumbnail: flashLastThumbnail,
            activates: false
        )
    }

    private func show(
        tldr: String,
        suggestionDetails: [SuggestionDetail],
        showsCustomInput: Bool,
        hintText: String?,
        bottomHintText: String? = nil,
        showsTldrHeader: Bool = false,
        isLoading: Bool = false,
        thumbnails: [NSImage] = [],
        flashLastThumbnail: Bool = false,
        activates: Bool = true
    ) {
        close()

        let visibleSuggestions = Array(suggestionDetails.prefix(3))
        // Loading state keeps the medium weight for visual contrast with the
        // pulsing dot; the actual Blink body is regular weight so the bold
        // "tl;dr" label sits above it as a header.
        let summaryFont = NSFont.systemFont(ofSize: Layout.summaryFontSize, weight: isLoading ? .medium : .regular)
        let suggestionFont = NSFont.systemFont(ofSize: Layout.suggestionFontSize)
        let hintFont = NSFont.systemFont(ofSize: Layout.hintFontSize)
        let contentWidth = Layout.panelWidth
        let summaryLabelWidth = contentWidth - 48
        let hintBlockHeight = hintText == nil ? 0 : Layout.summaryHintHeight + Layout.summaryHintGap
        let thumbBlockHeight = thumbnails.isEmpty ? 0 : Layout.thumbStripHeight + Layout.summaryHintGap
        let summaryTextY = Layout.summaryBottomInset + hintBlockHeight + thumbBlockHeight
        let useHeader = showsTldrHeader && !isLoading
        let bodyBoldPrefix = useHeader ? "tl;dr" : nil
        // Decide whether the rendered tldr is long enough to deserve a
        // collapsible preview. We compare its full measured height to a 3-line
        // budget at the same font and line spacing. If it fits, we use the
        // existing single-shot label render; if it doesn't, we switch the body
        // to an NSScrollView and surface a toggle.
        let fullSummaryTextHeight: CGFloat = isLoading
            ? 0
            : measureHeight(
                tldr,
                width: summaryLabelWidth,
                font: summaryFont,
                lineSpacing: Layout.summaryLineSpacing,
                boldPrefix: bodyBoldPrefix
            )
        let summarySingleLineHeight = ceil(summaryFont.ascender - summaryFont.descender + summaryFont.leading)
        let summaryPreviewTextHeight = CGFloat(Layout.summaryPreviewLineCount) * summarySingleLineHeight
            + CGFloat(max(0, Layout.summaryPreviewLineCount - 1)) * Layout.summaryLineSpacing
        let summaryIsExpandable = !isLoading && fullSummaryTextHeight > summaryPreviewTextHeight + 1
        let screenHeightForCap = (NSScreen.main?.frame.height ?? 900)
        let expandedTextHeightCap = max(
            summaryPreviewTextHeight,
            screenHeightForCap * Layout.summaryExpandedMaxHeightRatio
                - summaryTextY - Layout.summaryTopInset
                - Layout.summaryExpandButtonHeight - Layout.summaryExpandButtonGap
        )
        let expandedSummaryTextHeight = min(fullSummaryTextHeight, expandedTextHeightCap)
        let summaryCollapsedHeight: CGFloat
        let summaryExpandedHeight: CGFloat
        let summaryHeight: CGFloat
        if isLoading {
            summaryHeight = Layout.loadingMinHeight
            summaryCollapsedHeight = summaryHeight
            summaryExpandedHeight = summaryHeight
        } else if summaryIsExpandable {
            let toggleBlock = Layout.summaryExpandButtonHeight + Layout.summaryExpandButtonGap
            summaryCollapsedHeight = max(
                Layout.summaryMinHeight,
                summaryPreviewTextHeight + summaryTextY + Layout.summaryTopInset + toggleBlock
            )
            summaryExpandedHeight = max(
                summaryCollapsedHeight,
                expandedSummaryTextHeight + summaryTextY + Layout.summaryTopInset + toggleBlock
            )
            summaryHeight = summaryIsExpanded ? summaryExpandedHeight : summaryCollapsedHeight
        } else {
            summaryHeight = max(
                Layout.summaryMinHeight,
                fullSummaryTextHeight + summaryTextY + Layout.summaryTopInset
            )
            summaryCollapsedHeight = summaryHeight
            summaryExpandedHeight = summaryHeight
        }
        let suggestionLabelWidth = contentWidth - Layout.suggestionTextX - Layout.cardPaddingX
        let collapsedHeights = visibleSuggestions.map {
            collapsedHeight(for: $0, width: suggestionLabelWidth, font: suggestionFont)
        }
        let expandedHeights = visibleSuggestions.enumerated().map { offset, detail in
            max(
                collapsedHeights[offset],
                measureHeight(detail.text, width: suggestionLabelWidth, font: suggestionFont, lineSpacing: Layout.suggestionLineSpacing)
                    + Layout.suggestionPaddingY
                    + Layout.expandedBottomPadding(hasAttachments: !detail.attachments.isEmpty)
            )
        }
        let suggestionStackHeight = collapsedHeights.reduce(0, +)
            + CGFloat(max(0, visibleSuggestions.count - 1)) * Layout.suggestionGap
        let customStackHeight = showsCustomInput
            ? (visibleSuggestions.isEmpty ? Layout.customInputMinHeight : Layout.suggestionGap + Layout.customInputMinHeight)
            : 0
        let stackHeight = suggestionStackHeight + customStackHeight
        let bottomHintBlockHeight = bottomHintText == nil ? 0 : Layout.bottomHintTopGap + Layout.bottomHintHeight
        let contentHeight = summaryHeight
            + (stackHeight == 0 ? 0 : Layout.sectionGap + stackHeight)
            + bottomHintBlockHeight
        let panelWidth = Layout.panelWidth + Layout.shadowBleed * 2
        let panelHeight = contentHeight + Layout.shadowBleed * 2

        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: screenFrame.midX - panelWidth / 2,
            y: screenFrame.midY - panelHeight / 2
        )
        let frame = NSRect(origin: origin, size: NSSize(width: panelWidth, height: panelHeight))

        let style: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        let panel = SuggestionsPanel(
            contentRect: frame,
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        // Full-screen apps live in their own Space. A normal status-bar-level
        // panel can be ordered successfully but still sit behind the full-screen
        // window, so match the transient capture/celebration panels: join all
        // Spaces as a full-screen auxiliary and use a high transient level.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.worksWhenModal = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // The borderless panel has no titlebar to grab; with the background
        // clear, AppKit treats the transparent shadow-bleed perimeter as a
        // drag region. Combined with `Cmd+P` (toggle pin), it gives the user
        // a way to reposition the overlay without rearranging the chrome.
        panel.isMovableByWindowBackground = true
        if Self.useLegacyGlass {
            // Force dark appearance so `.labelColor` stays white and the
            // `.popover` material renders its dark frosted variant. Without
            // this, a light system appearance + dark backdrop blend produces
            // dark text on dark frost (the card-#4 black-on-black bug).
            panel.appearance = NSAppearance(named: .darkAqua)
        }
        panel.onLocalKeyDown = { [weak self] event in
            self?.handleLocalKeyDown(event) ?? false
        }

        let content = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = content

        let contentX = Layout.shadowBleed
        let contentTop = panelHeight - Layout.shadowBleed
        let summaryY = contentTop - summaryHeight
        let summaryFrame = NSRect(x: contentX, y: summaryY, width: contentWidth, height: summaryHeight)
        let summary = makeGlassPane(frame: summaryFrame, cornerRadius: 24)

        if let hintText {
            self.summaryHintBaseText = hintText
            let hint = label(
                frame: NSRect(
                    x: 24,
                    y: Layout.summaryBottomInset,
                    width: contentWidth - 48,
                    height: Layout.summaryHintHeight
                ),
                text: composedHintText(base: hintText),
                font: hintFont,
                color: .tertiaryLabelColor,
                singleLine: true
            )
            hint.alignment = .center
            summary.content.addSubview(hint)
            self.summaryHintLabel = hint
        } else {
            self.summaryHintBaseText = nil
            self.summaryHintLabel = nil
        }

        if !thumbnails.isEmpty {
            let stripY = Layout.summaryBottomInset + hintBlockHeight
            let stripWidth = contentWidth - 48
            let count = thumbnails.count
            let totalGap = Layout.thumbStripGap * CGFloat(max(0, count - 1))
            let slotWidth = max(0, (stripWidth - totalGap) / CGFloat(count))
            for (offset, image) in thumbnails.enumerated() {
                let x = CGFloat(24) + CGFloat(offset) * (slotWidth + Layout.thumbStripGap)
                let frame = NSRect(x: x, y: stripY, width: slotWidth, height: Layout.thumbStripHeight)
                let imageView = NSImageView(frame: frame)
                imageView.image = image
                imageView.imageScaling = .scaleProportionallyDown
                imageView.imageAlignment = .alignCenter
                imageView.wantsLayer = true
                imageView.layer?.cornerRadius = 6
                imageView.layer?.masksToBounds = true
                imageView.layer?.borderWidth = 1
                let isFlashTarget = flashLastThumbnail && offset == count - 1
                let baseBorder = NSColor.white.withAlphaComponent(0.18).cgColor
                let flashBorder = NSColor.systemYellow.withAlphaComponent(0.9).cgColor
                imageView.layer?.borderColor = isFlashTarget ? flashBorder : baseBorder
                imageView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
                summary.content.addSubview(imageView)
                if isFlashTarget {
                    imageView.alphaValue = 0.35
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.32
                        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        imageView.animator().alphaValue = 1.0
                    }
                }
            }
        }

        let summaryLabel: NSTextField
        if isLoading {
            // Compact loading layout: a centered horizontal group of
            // [pulsing dot] [placeholder text] sitting at vertical center
            // of the (much shorter) summary card. We size and position the
            // group as a unit so it stays visually balanced.
            let textWidth = ceil(measureLoadingTextWidth(tldr, font: summaryFont))
            let textHeight = ceil(summaryFont.ascender - summaryFont.descender)
            let groupWidth = Layout.loadingDotSize + Layout.loadingDotTextGap + textWidth
            let groupX = (summaryFrame.width - groupWidth) / 2
            let centerY = summaryFrame.height / 2
            let dot = installLoadingDot(in: summary.content, at: NSRect(
                x: groupX,
                y: centerY - Layout.loadingDotSize / 2,
                width: Layout.loadingDotSize,
                height: Layout.loadingDotSize
            ))
            loadingPulseDot = dot
            // Generous label width avoids any subpixel-rounding truncation
            // ("Reading this scree…" was the symptom). The label is left
            // aligned, so the visual text origin is still at groupX + dot +
            // gap — extra pixels just live empty to the right.
            let labelWidth = min(textWidth + 24, summaryFrame.width - groupX
                - Layout.loadingDotSize - Layout.loadingDotTextGap - 16)
            summaryLabel = label(
                frame: NSRect(
                    x: groupX + Layout.loadingDotSize + Layout.loadingDotTextGap,
                    y: centerY - textHeight / 2,
                    width: labelWidth,
                    height: textHeight
                ),
                text: tldr,
                font: summaryFont,
                color: .labelColor,
                singleLine: true
            )
        } else if summaryIsExpandable {
            // Long tldr: render in an NSScrollView with the full text so the
            // user can opt into the full content via the toggle below. The
            // visible area starts at the collapsed preview height.
            let toggleBlock = Layout.summaryExpandButtonHeight + Layout.summaryExpandButtonGap
            let textOriginY = summaryTextY + toggleBlock
            let visibleTextHeight = summaryHeight - textOriginY - Layout.summaryTopInset
            let scrollFrame = NSRect(
                x: 24,
                y: textOriginY,
                width: summaryLabelWidth,
                height: visibleTextHeight
            )
            let scrollView = NSScrollView(frame: scrollFrame)
            scrollView.hasHorizontalScroller = false
            scrollView.hasVerticalScroller = summaryIsExpanded
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = false
            scrollView.autohidesScrollers = true
            scrollView.scrollerStyle = .overlay
            let textView = NSTextView(frame: NSRect(
                x: 0,
                y: 0,
                width: scrollFrame.width,
                height: max(fullSummaryTextHeight, visibleTextHeight)
            ))
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.textContainerInset = .zero
            textView.textContainer?.lineFragmentPadding = 0
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = Layout.summaryLineSpacing
            let attributed = NSMutableAttributedString(
                string: tldr,
                attributes: [
                    .font: summaryFont,
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraph,
                ]
            )
            textView.textStorage?.setAttributedString(attributed)
            scrollView.documentView = textView
            summary.content.addSubview(scrollView)
            // Keep summaryLabel non-nil so call sites that mutate it
            // (updateSummary, etc.) don't crash. We park it offscreen and
            // hide it; the visible content lives in the text view.
            summaryLabel = label(
                frame: NSRect(x: -1, y: -1, width: 1, height: 1),
                text: "",
                font: summaryFont,
                color: .clear,
                singleLine: true
            )
            summaryLabel.isHidden = true
            let button = NSButton(
                title: summaryIsExpanded ? "Show less ▴" : "Show more ▾",
                target: self,
                action: #selector(toggleSummaryExpandedAction)
            )
            button.isBordered = false
            button.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            button.contentTintColor = .tertiaryLabelColor
            let buttonWidth: CGFloat = 110
            button.frame = NSRect(
                x: contentWidth - 24 - buttonWidth,
                y: summaryTextY,
                width: buttonWidth,
                height: Layout.summaryExpandButtonHeight
            )
            button.alignment = .right
            summary.content.addSubview(button)
            self.summaryScrollView = scrollView
            self.summaryTextView = textView
            self.summaryExpandButton = button
        } else {
            summaryLabel = label(
                frame: NSRect(
                    x: 24,
                    y: summaryTextY,
                    width: contentWidth - 48,
                    height: summaryHeight - summaryTextY - Layout.summaryTopInset
                ),
                text: tldr,
                font: summaryFont,
                color: .labelColor,
                lineSpacing: Layout.summaryLineSpacing,
                boldPrefix: bodyBoldPrefix
            )
        }
        summary.content.addSubview(summaryLabel)
        content.addSubview(summary.outer)

        var cards: [SuggestionCard] = []
        var y = summaryY - Layout.sectionGap
        for (offset, detail) in visibleSuggestions.enumerated() {
            let collapsedHeight = collapsedHeights[offset]
            y -= collapsedHeight
            let rowFrame = NSRect(
                x: contentX,
                y: y,
                width: contentWidth,
                height: collapsedHeight
            )
            let card = makeSuggestionCard(
                frame: rowFrame,
                index: offset + 1,
                detail: detail,
                font: suggestionFont
            )
            content.addSubview(card.outer)
            cards.append(SuggestionCard(
                outer: card.outer,
                content: card.content,
                tint: card.tint,
                number: card.number,
                label: card.label,
                tagIcon: card.tagIcon,
                tagLabel: card.tagLabel,
                enterHint: card.enterHint,
                collapsedFrame: rowFrame,
                collapsedText: collapsedDisplayText(for: detail, width: suggestionLabelWidth, font: suggestionFont),
                fullText: detail.text,
                expandedHeight: expandedHeights[offset],
                hasTags: !renderTags(detail.tags).isEmpty,
                collapsedLabelHeight: collapsedTextHeight(for: detail, width: suggestionLabelWidth, font: suggestionFont),
                collapsedSingleLine: collapsedTextIsSingleLine(for: detail, width: suggestionLabelWidth, font: suggestionFont),
                attachments: detail.attachments,
                attachmentChips: card.attachmentChips
            ))
            if offset < visibleSuggestions.count - 1 {
                y -= Layout.suggestionGap
            }
        }

        let custom: (
            outer: NSView,
            content: NSView,
            field: CustomReplyField,
            number: NSTextField,
            enterHint: NSTextField,
            tint: NSView,
            followUpButton: NSButton,
            writeButton: NSButton
        )?
        let customFrame: NSRect
        if showsCustomInput {
            if !visibleSuggestions.isEmpty {
                y -= Layout.suggestionGap
            }
            y -= Layout.customInputMinHeight
            customFrame = NSRect(
                x: contentX,
                y: y,
                width: contentWidth,
                height: Layout.customInputMinHeight
            )
            let customCard = makeCustomInputCard(frame: customFrame, font: suggestionFont)
            content.addSubview(customCard.outer)
            custom = customCard
        } else {
            customFrame = .zero
            custom = nil
        }

        let bottomHint: NSTextField?
        let bottomHintFrame: NSRect
        if let bottomHintText {
            y -= Layout.bottomHintTopGap
            y -= Layout.bottomHintHeight
            bottomHintFrame = NSRect(
                x: contentX + 24,
                y: y,
                width: contentWidth - 48,
                height: Layout.bottomHintHeight
            )
            let hint = label(
                frame: bottomHintFrame,
                text: bottomHintText,
                font: hintFont,
                color: .tertiaryLabelColor,
                singleLine: true
            )
            hint.alignment = .center
            content.addSubview(hint)
            bottomHint = hint
        } else {
            bottomHint = nil
            bottomHintFrame = .zero
        }

        self.panel = panel
        self.contentView = content
        self.basePanelHeight = panelHeight
        self.basePanelTopY = frame.maxY
        self.summaryCard = summary.outer
        self.summaryContent = summary.content
        self.summaryLabel = summaryLabel
        self.summaryBaseFrame = summaryFrame
        self.summaryTextY = summaryTextY
        self.suggestionCards = cards
        self.customInputCard = custom?.outer
        self.customInputBaseFrame = customFrame
        self.customInputField = custom?.field
        self.customInputNumber = custom?.number
        self.customInputHintLabel = custom?.enterHint
        self.customInputTint = custom?.tint
        self.customInputMode = .followUp
        self.customFollowUpButton = custom?.followUpButton
        self.customWriteButton = custom?.writeButton
        self.bottomHintLabel = bottomHint
        self.bottomHintBaseFrame = bottomHintFrame
        self.showsTldrHeader = showsTldrHeader
        panel.customReplyField = custom?.field
        applyCustomInputModeVisuals()
        self.currentHeightDelta = 0
        self.customInputHeightDelta = 0
        self.expandedSuggestionIndex = nil
        self.hasPlayedSuggestionArrival = false
        self.isLoadingState = isLoading
        self.summaryFullText = tldr
        self.summaryIsExpandable = summaryIsExpandable
        self.summaryIsExpanded = summaryIsExpandable ? summaryIsExpanded : false
        self.summaryCollapsedHeight = summaryCollapsedHeight
        self.summaryExpandedHeight = summaryExpandedHeight
        self.summaryHeightDelta = self.summaryIsExpanded ? (summaryExpandedHeight - summaryCollapsedHeight) : 0

        if activates {
            // Remember the app the user was working in so we can restore
            // focus when the overlay closes after paste/copy actions. The
            // panel itself stays non-activating so it can sit above full-screen
            // Spaces without pulling the user out of the source app.
            let frontmost = NSWorkspace.shared.frontmostApplication
            let ownPID = NSRunningApplication.current.processIdentifier
            if let frontmost, frontmost.processIdentifier != ownPID {
                previousFrontmost = frontmost
            } else {
                previousFrontmost = nil
            }
            panel.orderFrontRegardless()
            emitVisibilityChange(true)
            // Keep the custom field visually unfocused on open; global hotkey
            // routing handles 1/2/3/Return/Esc while the source app remains
            // frontmost.
            panel.makeFirstResponder(nil)
            applyCustomInputFocusState(focused: false, animated: false)
            customInputField?.onFocusChanged?(false)
            // Take key status only once a real summary is on screen so the
            // panel's local key handler swallows stray keys (otherwise "h"
            // typed during the ready state leaks to the source app). The
            // panel uses `.nonactivatingPanel`, so becoming key does not
            // change the active app — only key routing. While loading, we
            // wait until updateSummary fires so the user can keep typing in
            // the source app during the request round-trip.
            if !isLoading {
                panel.makeKey()
            }
        } else {
            // Collecting state: stay non-activating so the source app
            // remains frontmost and subsequent capture presses still see
            // the right window. No interactive widgets are mounted in this
            // state, so we don't need key status.
            previousFrontmost = nil
            panel.orderFrontRegardless()
            emitVisibilityChange(true)
        }
        installMouseMonitors()
        if !isLoading, !visibleSuggestions.isEmpty {
            hasPlayedSuggestionArrival = true
            playArrivalAnimation(summary: summary.outer, cards: cards.map(\.outer))
        }
    }

    /// Update the placeholder text mid-loading without tearing down the
    /// pulsing dot or growing the card. Used for `.phase` events from the
    /// streaming pipeline ("Reading screen…", "Calling Gemini…", etc.).
    func updateLoadingPhase(_ text: String) {
        guard isLoadingState, let summaryCard, let summaryLabel else {
            return
        }
        let font = NSFont.systemFont(ofSize: Layout.summaryFontSize, weight: .medium)
        let textWidth = ceil(measureLoadingTextWidth(text, font: font))
        let textHeight = ceil(font.ascender - font.descender)
        let groupWidth = Layout.loadingDotSize + Layout.loadingDotTextGap + textWidth
        let groupX = (summaryCard.frame.width - groupWidth) / 2
        let centerY = summaryCard.frame.height / 2
        if let dot = loadingPulseDot {
            dot.frame = NSRect(
                x: groupX,
                y: centerY - Layout.loadingDotSize / 2,
                width: Layout.loadingDotSize,
                height: Layout.loadingDotSize
            )
        }
        let labelWidth = min(textWidth + 24, summaryCard.frame.width - groupX
            - Layout.loadingDotSize - Layout.loadingDotTextGap - 16)
        summaryLabel.frame = NSRect(
            x: groupX + Layout.loadingDotSize + Layout.loadingDotTextGap,
            y: centerY - textHeight / 2,
            width: labelWidth,
            height: textHeight
        )
        setLabelText(
            summaryLabel,
            text: text,
            font: font,
            color: .labelColor,
            lineSpacing: 0,
            singleLine: true
        )
    }

    func beginSuggestionRefresh() {
        guard !isLoadingState else { return }
        isSuggestionRefreshing = true
        expandedSuggestionIndex = nil
        currentHeightDelta = 0
        customInputField?.onFocusChanged?(false)
        panel?.customReplyField = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Layout.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for card in suggestionCards {
                card.outer.animator().alphaValue = 0.44
            }
        }
    }

    func endSuggestionRefresh() {
        isSuggestionRefreshing = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Layout.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for card in suggestionCards {
                card.outer.animator().alphaValue = 1
            }
        }
    }

    private func centeredOriginY(for panel: NSPanel, height: CGFloat) -> CGFloat {
        let screenFrame = panel.screen?.frame
            ?? NSScreen.main?.frame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return screenFrame.midY - height / 2
    }

    func updateSummary(_ text: String) {
        guard let panel,
              let contentView,
              let summaryCard,
              let summaryLabel
        else { return }
        let wasLoading = isLoadingState
        if wasLoading {
            tearDownLoadingState()
            // Streaming-loading path: now that the real summary is on screen,
            // promote the panel to key so its local handler intercepts stray
            // keystrokes. Mirrors the immediate-show path in `show(...)`.
            panel.makeKey()
            // `showLoading` skipped the bottom hint (hintText: nil), so the
            // hint label was never created. Install it now — same string
            // the non-streaming `show(tldr:suggestionDetails:)` uses.
            installSuggestionHintIfNeeded(Self.suggestionHintText)
        }
        let bodyBoldPrefix: String? = showsTldrHeader ? "tl;dr" : nil
        let font = NSFont.systemFont(ofSize: Layout.summaryFontSize, weight: showsTldrHeader ? .regular : .medium)
        let labelWidth = Layout.panelWidth - 48
        // When transitioning out of loading the card was clamped to the
        // compact loadingMinHeight; grow it to at least summaryMinHeight so
        // multi-line content has the normal breathing room.
        let floor = wasLoading ? Layout.summaryMinHeight : summaryBaseFrame.height
        let requiredSummaryHeight = max(
            floor,
            measureHeight(text, width: labelWidth, font: font, lineSpacing: Layout.summaryLineSpacing, boldPrefix: bodyBoldPrefix)
                + summaryTextY
                + Layout.summaryTopInset
        )
        let summaryDelta = requiredSummaryHeight - summaryBaseFrame.height
        if summaryDelta > 0 {
            let newPanelHeight = basePanelHeight + summaryDelta
            let newFrame = NSRect(
                x: panel.frame.origin.x,
                y: centeredOriginY(for: panel, height: newPanelHeight),
                width: panel.frame.width,
                height: newPanelHeight
            )
            panel.setFrame(newFrame, display: true, animate: false)
            // Re-anchor basePanelTopY to the actual post-clamp top edge so any
            // later expand/collapse uses the recentered top.
            basePanelTopY = panel.frame.maxY
            contentView.frame = NSRect(x: 0, y: 0, width: newFrame.width, height: newPanelHeight)
            summaryCard.frame = NSRect(
                x: summaryBaseFrame.origin.x,
                y: summaryBaseFrame.origin.y,
                width: summaryBaseFrame.width,
                height: requiredSummaryHeight
            )
            summaryLabel.frame = NSRect(
                x: 24,
                y: summaryTextY,
                width: labelWidth,
                height: requiredSummaryHeight - summaryTextY - Layout.summaryTopInset
            )
            if wasLoading {
                // Anchor summaryBaseFrame and basePanelHeight to the new
                // post-loading layout so subsequent grows compute from the
                // right baseline.
                summaryBaseFrame = summaryCard.frame
                basePanelHeight = newPanelHeight
            }
        } else if wasLoading {
            // Even when the new text fits in summaryBaseFrame, the loading
            // layout positioned the label as a centered single-line group.
            // Reset to the standard top-anchored multi-line frame.
            summaryLabel.frame = NSRect(
                x: 24,
                y: summaryTextY,
                width: labelWidth,
                height: summaryBaseFrame.height - summaryTextY - Layout.summaryTopInset
            )
        }
        setLabelText(
            summaryLabel,
            text: text,
            font: font,
            color: .labelColor,
            lineSpacing: Layout.summaryLineSpacing,
            singleLine: false,
            boldPrefix: bodyBoldPrefix
        )
    }

    func updateSuggestions(_ suggestions: [String]) {
        updateSuggestionDetails(suggestions.map(SuggestionDetail.plain))
    }

    func updateSuggestionDetails(_ suggestions: [SuggestionDetail]) {
        guard let panel, let contentView, let summaryCard else { return }
        let visibleSuggestions = Array(suggestions.prefix(3))
        if isSuggestionRefreshing && visibleSuggestions.isEmpty {
            return
        }
        let shouldAnimateRefresh = isSuggestionRefreshing && !visibleSuggestions.isEmpty
        if !visibleSuggestions.isEmpty {
            endSuggestionRefresh()
        }

        for card in suggestionCards {
            card.outer.removeFromSuperview()
        }
        suggestionCards = []
        suggestionClickTargets = []
        customInputField?.onFocusChanged?(false)
        customInputCard?.removeFromSuperview()
        customInputCard = nil
        customInputField = nil
        customInputHintLabel = nil
        customInputTint = nil
        customFollowUpButton = nil
        customWriteButton = nil
        bottomHintLabel?.removeFromSuperview()
        bottomHintLabel = nil
        panel.customReplyField = nil
        expandedSuggestionIndex = nil

        let suggestionFont = NSFont.systemFont(ofSize: Layout.suggestionFontSize)
        let hintFont = NSFont.systemFont(ofSize: Layout.hintFontSize)
        let bottomHintText: String? = nil
        let contentWidth = Layout.panelWidth
        let suggestionLabelWidth = contentWidth - Layout.suggestionTextX - Layout.cardPaddingX
        let collapsedHeights = visibleSuggestions.map {
            collapsedHeight(for: $0, width: suggestionLabelWidth, font: suggestionFont)
        }
        let expandedHeights = visibleSuggestions.enumerated().map { offset, detail in
            max(
                collapsedHeights[offset],
                measureHeight(detail.text, width: suggestionLabelWidth, font: suggestionFont, lineSpacing: Layout.suggestionLineSpacing)
                    + Layout.suggestionPaddingY
                    + Layout.expandedBottomPadding(hasAttachments: !detail.attachments.isEmpty)
            )
        }
        let suggestionStackHeight = collapsedHeights.reduce(0, +)
            + CGFloat(max(0, visibleSuggestions.count - 1)) * Layout.suggestionGap
        let customStackHeight = visibleSuggestions.isEmpty
            ? Layout.customInputMinHeight
            : Layout.suggestionGap + Layout.customInputMinHeight
        let stackHeight = suggestionStackHeight + customStackHeight
        let bottomHintBlockHeight = bottomHintText == nil ? 0 : Layout.bottomHintTopGap + Layout.bottomHintHeight

        let summaryHeight = summaryCard.frame.height
        let contentHeight = summaryHeight + Layout.sectionGap + stackHeight + bottomHintBlockHeight
        let newPanelWidth = panel.frame.width
        let newPanelHeight = contentHeight + Layout.shadowBleed * 2

        let newFrame = NSRect(
            x: panel.frame.origin.x,
            y: centeredOriginY(for: panel, height: newPanelHeight),
            width: newPanelWidth,
            height: newPanelHeight
        )
        panel.setFrame(newFrame, display: true, animate: false)
        contentView.frame = NSRect(x: 0, y: 0, width: newPanelWidth, height: newPanelHeight)

        let contentX = Layout.shadowBleed
        let contentTop = newPanelHeight - Layout.shadowBleed
        let summaryY = contentTop - summaryHeight
        summaryCard.frame = NSRect(
            x: contentX,
            y: summaryY,
            width: contentWidth,
            height: summaryHeight
        )
        summaryBaseFrame = summaryCard.frame

        var cards: [SuggestionCard] = []
        var y = summaryY - Layout.sectionGap
        for (offset, detail) in visibleSuggestions.enumerated() {
            let collapsedHeight = collapsedHeights[offset]
            y -= collapsedHeight
            let rowFrame = NSRect(
                x: contentX,
                y: y,
                width: contentWidth,
                height: collapsedHeight
            )
            let card = makeSuggestionCard(
                frame: rowFrame,
                index: offset + 1,
                detail: detail,
                font: suggestionFont
            )
            contentView.addSubview(card.outer)
            cards.append(SuggestionCard(
                outer: card.outer,
                content: card.content,
                tint: card.tint,
                number: card.number,
                label: card.label,
                tagIcon: card.tagIcon,
                tagLabel: card.tagLabel,
                enterHint: card.enterHint,
                collapsedFrame: rowFrame,
                collapsedText: collapsedDisplayText(for: detail, width: suggestionLabelWidth, font: suggestionFont),
                fullText: detail.text,
                expandedHeight: expandedHeights[offset],
                hasTags: !renderTags(detail.tags).isEmpty,
                collapsedLabelHeight: collapsedTextHeight(for: detail, width: suggestionLabelWidth, font: suggestionFont),
                collapsedSingleLine: collapsedTextIsSingleLine(for: detail, width: suggestionLabelWidth, font: suggestionFont),
                attachments: detail.attachments,
                attachmentChips: card.attachmentChips
            ))
            if offset < visibleSuggestions.count - 1 {
                y -= Layout.suggestionGap
            }
        }

        if !visibleSuggestions.isEmpty {
            y -= Layout.suggestionGap
        }
        y -= Layout.customInputMinHeight
        let customFrame = NSRect(
            x: contentX,
            y: y,
            width: contentWidth,
            height: Layout.customInputMinHeight
        )
        let customCard = makeCustomInputCard(frame: customFrame, font: suggestionFont)
        contentView.addSubview(customCard.outer)

        let bottomHint: NSTextField?
        let bottomHintFrame: NSRect
        if let bottomHintText {
            y -= Layout.bottomHintTopGap
            y -= Layout.bottomHintHeight
            bottomHintFrame = NSRect(
                x: contentX + 24,
                y: y,
                width: contentWidth - 48,
                height: Layout.bottomHintHeight
            )
            let hint = label(
                frame: bottomHintFrame,
                text: bottomHintText,
                font: hintFont,
                color: .tertiaryLabelColor,
                singleLine: true
            )
            hint.alignment = .center
            contentView.addSubview(hint)
            bottomHint = hint
        } else {
            bottomHint = nil
            bottomHintFrame = .zero
        }

        self.suggestionCards = cards
        self.customInputCard = customCard.outer
        self.customInputBaseFrame = customFrame
        self.customInputField = customCard.field
        self.customInputNumber = customCard.number
        self.customInputHintLabel = customCard.enterHint
        self.customInputTint = customCard.tint
        self.customInputMode = .followUp
        self.customFollowUpButton = customCard.followUpButton
        self.customWriteButton = customCard.writeButton
        self.bottomHintLabel = bottomHint
        self.bottomHintBaseFrame = bottomHintFrame
        panel.customReplyField = customCard.field
        applyCustomInputModeVisuals()
        self.basePanelHeight = newPanelHeight
        self.basePanelTopY = panel.frame.maxY
        self.currentHeightDelta = 0
        self.customInputHeightDelta = 0
        let refreshArrivalViews = cards.map(\.outer)
        if shouldAnimateRefresh, !cards.isEmpty {
            playArrivalAnimation(summary: nil, cards: refreshArrivalViews)
        } else if !hasPlayedSuggestionArrival, !cards.isEmpty {
            hasPlayedSuggestionArrival = true
            playArrivalAnimation(summary: summaryCard, cards: cards.map(\.outer))
        }
    }

    func focusCustomInput() {
        guard let panel, let field = customInputField else { return }
        collapseSuggestions()
        panel.makeFirstResponder(field.textView)
    }

    @objc private func toggleSummaryExpandedAction() {
        toggleSummaryExpanded()
    }

    /// Flip the collapsible-summary state and animate the panel + suggestion
    /// stack into the new height. Mirrors the panel-resize choreography used
    /// by `expandSuggestion` / `collapseSuggestions`: top edge stays pinned,
    /// the summary card grows downward, and everything below shifts to match.
    func toggleSummaryExpanded() {
        guard
            summaryIsExpandable,
            let panel,
            let contentView,
            let summaryCard,
            let scrollView = summaryScrollView,
            let button = summaryExpandButton
        else { return }

        // Collapse any expanded suggestion first so we don't have to reason
        // about two stacked height deltas simultaneously.
        if expandedSuggestionIndex != nil {
            collapseSuggestions()
        }

        let willExpand = !summaryIsExpanded
        let oldSummaryHeight = summaryCollapsedHeight + summaryHeightDelta
        let newSummaryHeight = willExpand ? summaryExpandedHeight : summaryCollapsedHeight
        let delta = newSummaryHeight - oldSummaryHeight
        guard delta != 0 else { return }

        summaryIsExpanded = willExpand
        summaryHeightDelta = willExpand ? (summaryExpandedHeight - summaryCollapsedHeight) : 0

        // Anchor against the panel's *current* top edge (the user may
        // have dragged it via `isMovableByWindowBackground` since the
        // show-time anchor was captured). Otherwise the resize snaps
        // y back to the original centered position.
        basePanelTopY = panel.frame.maxY
        let newPanelHeight = basePanelHeight + summaryHeightDelta + customInputHeightDelta
        let newPanelFrame = NSRect(
            x: panel.frame.origin.x,
            y: basePanelTopY - newPanelHeight,
            width: panel.frame.width,
            height: newPanelHeight
        )

        // Resize content view and panel synchronously, then synchronously
        // shift children to maintain their screen position across the jump
        // (panel moved down/up by `delta` in screen coords, so children's
        // panel-local y would land their screen y at the wrong spot until
        // the animator below moves them). This mirrors the `panelDrop`
        // compensation used by expandSuggestion.
        contentView.frame = NSRect(x: 0, y: 0, width: newPanelFrame.width, height: newPanelHeight)
        panel.setFrame(newPanelFrame, display: true, animate: false)

        for card in suggestionCards {
            var frame = card.outer.frame
            frame.origin.y += delta
            card.outer.frame = frame
        }
        if let customInputCard {
            var frame = customInputCard.frame
            frame.origin.y += delta
            customInputCard.frame = frame
        }
        if let bottomHintLabel {
            var frame = bottomHintLabel.frame
            frame.origin.y += delta
            bottomHintLabel.frame = frame
        }

        // Summary card panel-local y stays the same; only its height changes.
        // (When the panel grows by delta and the summary grows by delta,
        // the summary's top stays pinned to the top of contentView in
        // panel-local coords, so its origin.y is unchanged.)
        let newSummaryFrame = NSRect(
            x: summaryBaseFrame.origin.x,
            y: summaryBaseFrame.origin.y,
            width: summaryBaseFrame.width,
            height: newSummaryHeight
        )

        // Resize the scroll view to fill the (possibly larger) summary card.
        let toggleBlock = Layout.summaryExpandButtonHeight + Layout.summaryExpandButtonGap
        let textOriginY = summaryTextY + toggleBlock
        let visibleTextHeight = newSummaryHeight - textOriginY - Layout.summaryTopInset
        let newScrollFrame = NSRect(
            x: scrollView.frame.origin.x,
            y: textOriginY,
            width: scrollView.frame.width,
            height: visibleTextHeight
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Layout.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            summaryCard.animator().frame = newSummaryFrame
            scrollView.animator().frame = newScrollFrame
            // Toggle button stays anchored at the same y inside the summary
            // card (summaryTextY); the card itself moves so the screen
            // position updates automatically. No animator call needed.
            // Use the canonical collapsedFrame as the anchor and apply
            // summaryHeightDelta — this stays correct even if a previous
            // animation hasn't finished.
            // Target panel-local y is the canonical collapsedFrame.y —
            // when panel grows in lockstep with summary, the panel-local
            // positions of children below the summary don't change. The
            // animator slides them from their compensated positions (shifted
            // up by `delta` above) back to canonical, producing a smooth
            // screen-coord motion of `delta` in the expand direction.
            for card in suggestionCards {
                card.outer.animator().frame = card.collapsedFrame
            }
            if let customInputCard, customInputBaseFrame != .zero {
                customInputCard.animator().frame = customInputBaseFrame
            }
            if let bottomHintLabel, bottomHintBaseFrame != .zero {
                bottomHintLabel.animator().frame = bottomHintBaseFrame
            }
        }

        scrollView.hasVerticalScroller = summaryIsExpanded
        button.title = summaryIsExpanded ? "Show less ▴" : "Show more ▾"
        // We intentionally do NOT update basePanelHeight / summaryBaseFrame /
        // each card's collapsedFrame here. Those track the canonical
        // "summary-collapsed" layout that expandSuggestion uses as its
        // anchor. Suggestion expansion is gated to that resting state — see
        // the guard in expandSuggestion — so the two resize systems never
        // need to compose.
    }

    func leaveCustomInput() {
        // While the field is being edited, AppKit's actual first responder is
        // the shared field editor (an NSTextView), not the field itself, so
        // `panel.firstResponder === customInputField` is always false mid-edit.
        // Use `isEditing` (which inspects `currentEditor()`) so this method
        // actually drops focus.
        guard let panel else { return }
        let wasEditing = customInputField?.isEditing == true
        if wasEditing {
            panel.makeFirstResponder(nil)
        }
        // Belt-and-suspenders, same pattern as `show()`: AppKit's
        // `resignFirstResponder` doesn't reliably fire on the NSTextField when
        // the field editor was the actual responder, so the field's
        // `onFocusChanged?(false)` may never run — leaving the blue tint and
        // hint stuck visible. Drive the visual cleanup directly.
        applyCustomInputFocusState(focused: false, animated: true)
    }

    func performCustomInputShortcut(_ shortcut: TextEditingShortcut) -> Bool {
        customInputField?.performTextEditingShortcut(shortcut) ?? false
    }

    var customInputText: String {
        customInputField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Restore a custom-input draft from a prior session (resume path).
    /// No-op when the field isn't visible.
    @MainActor
    func restoreCustomInputText(_ text: String) {
        guard let field = customInputField else { return }
        field.stringValue = text
    }

    private var customInputEditorText: String {
        customInputText
    }

    @MainActor
    func customInputCaretScreenPoint() -> CGPoint? {
        guard panel != nil, let field = customInputField, field.isEditing else { return nil }
        let tv = field.textView!
        let caretRect = tv.firstRect(forCharacterRange: tv.selectedRange(), actualRange: nil)
        if caretRect != .zero {
            return CGPoint(x: caretRect.midX, y: caretRect.midY)
        }
        guard let fieldWindow = field.window else { return nil }
        let fieldRectInScreen = fieldWindow.convertToScreen(field.convert(field.bounds, to: nil))
        return CGPoint(x: fieldRectInScreen.midX, y: fieldRectInScreen.midY)
    }

    @discardableResult
    func expandSuggestion(index: Int) -> Bool {
        guard let panel, let contentView, index >= 0, index < suggestionCards.count else {
            return false
        }

        // Suggestion expansion uses card.collapsedFrame as its anchor, which is
        // only valid when the summary is in its collapsed resting state. If
        // the summary is currently expanded, snap it back first so the two
        // resize systems don't fight over panel height.
        if summaryIsExpanded {
            toggleSummaryExpanded()
        }

        let selected = suggestionCards[index]
        let heightDelta = selected.expandedHeight - selected.collapsedFrame.height
        // Going from a state with currentHeightDelta to one with heightDelta
        // shifts panel.origin.y in screen coords by `heightDelta - current`
        // (top edge stays pinned). Each card's local origin would visually
        // jump by the same amount and the animator would pull it back —
        // that's the flicker. Compensate synchronously so screen position is
        // preserved across the resize, then let the animator transition to
        // the final target frames.
        let panelDrop = heightDelta - currentHeightDelta
        // Anchor against the panel's *current* top edge — user may have
        // dragged the panel after show().
        basePanelTopY = panel.frame.maxY
        let newPanelHeight = basePanelHeight + heightDelta + customInputHeightDelta
        let newFrame = NSRect(
            x: panel.frame.origin.x,
            y: basePanelTopY - newPanelHeight,
            width: panel.frame.width,
            height: newPanelHeight
        )

        contentView.frame = NSRect(x: 0, y: 0, width: newFrame.width, height: newPanelHeight)
        expandedSuggestionIndex = index

        let suggestionFont = NSFont.systemFont(ofSize: Layout.suggestionFontSize)
        let textWidth = Layout.panelWidth - Layout.suggestionTextX - Layout.cardPaddingX
        let summaryFrame = summaryBaseFrame.offsetBy(dx: 0, dy: heightDelta)

        panel.setFrame(newFrame, display: true, animate: false)
        summaryCard?.frame = summaryFrame

        if panelDrop != 0 {
            for card in suggestionCards {
                var current = card.outer.frame
                current.origin.y += panelDrop
                card.outer.frame = current
            }
            if let customInputCard {
                var current = customInputCard.frame
                current.origin.y += panelDrop
                customInputCard.frame = current
            }
            if let bottomHintLabel {
                var current = bottomHintLabel.frame
                current.origin.y += panelDrop
                bottomHintLabel.frame = current
            }
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Layout.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            for cardIndex in suggestionCards.indices {
                let card = suggestionCards[cardIndex]
                let isSelected = cardIndex == index
                let collapsedHeight = card.collapsedFrame.height
                let grows = isSelected && card.expandedHeight > collapsedHeight
                let targetHeight = grows ? card.expandedHeight : collapsedHeight
                // Cards above the selection shift up in panel-local coords to
                // compensate for the panel growing downward; the selected
                // card keeps its collapsed origin and just gains height, so
                // its top stays pinned in screen coords while it grows down.
                let targetY = card.collapsedFrame.origin.y
                    + (cardIndex < index ? heightDelta : 0)
                let targetFrame = NSRect(
                    x: card.collapsedFrame.origin.x,
                    y: targetY,
                    width: card.collapsedFrame.width,
                    height: targetHeight
                )
                let labelHeight: CGFloat
                let labelY: CGFloat
                let numberY: CGFloat

                if grows {
                    setLabelText(
                        card.label,
                        text: card.fullText,
                        font: suggestionFont,
                        color: .labelColor,
                        lineSpacing: Layout.suggestionLineSpacing,
                        singleLine: false
                    )
                    card.label.maximumNumberOfLines = 0
                    card.label.cell?.wraps = true
                    labelHeight = measureHeight(
                        card.fullText,
                        width: textWidth,
                        font: suggestionFont,
                        lineSpacing: Layout.suggestionLineSpacing
                    )
                    labelY = Layout.expandedBottomPadding(hasAttachments: !card.attachments.isEmpty)
                    card.tagIcon.alphaValue = 0
                    card.tagLabel.alphaValue = 0
                    let firstLineHeight = ceil(suggestionFont.ascender - suggestionFont.descender + suggestionFont.leading)
                    let firstLineCenterY = labelY + labelHeight - firstLineHeight / 2
                    numberY = firstLineCenterY - Layout.suggestionNumberHeight / 2
                } else {
                    setLabelText(
                        card.label,
                        text: card.collapsedText,
                        font: suggestionFont,
                        color: .labelColor,
                        lineSpacing: card.collapsedSingleLine ? 0 : 2,
                        singleLine: card.collapsedSingleLine
                    )
                    card.label.maximumNumberOfLines = card.collapsedSingleLine ? 1 : 2
                    card.label.cell?.wraps = !card.collapsedSingleLine
                    labelHeight = card.collapsedLabelHeight
                    if card.hasTags {
                        labelY = (collapsedHeight - labelHeight - Layout.suggestionTagHeight - Layout.suggestionTagGap) / 2
                            + Layout.suggestionTagHeight
                            + Layout.suggestionTagGap
                    } else {
                        labelY = (collapsedHeight - labelHeight) / 2
                    }
                    numberY = (collapsedHeight - Layout.suggestionNumberHeight) / 2
                    card.tagIcon.alphaValue = card.hasTags ? Layout.tagAlpha : 0
                    card.tagLabel.alphaValue = card.hasTags ? Layout.tagAlpha : 0
                }

                card.tint.alphaValue = isSelected ? 1 : 0
                card.enterHint.alphaValue = isSelected ? 1 : 0
                let optionCorner = Layout.optionCornerRadius(for: collapsedHeight)
                setCornerRadius(card.outer, optionCorner)
                card.tint.layer?.cornerRadius = optionCorner
                card.outer.animator().frame = targetFrame
                card.number.animator().frame = NSRect(
                    x: Layout.suggestionNumberX,
                    y: numberY,
                    width: Layout.suggestionNumberWidth,
                    height: Layout.suggestionNumberHeight
                )
                card.label.animator().frame = NSRect(
                    x: Layout.suggestionTextX,
                    y: labelY,
                    width: textWidth,
                    height: labelHeight
                )
                let tagY = card.hasTags
                    ? max(0, labelY - Layout.suggestionTagGap - Layout.suggestionTagHeight)
                    : labelY
                card.tagIcon.animator().frame = NSRect(
                    x: Layout.suggestionTextX,
                    y: tagY + (Layout.suggestionTagHeight - Layout.tagIconSize) / 2,
                    width: Layout.tagIconSize,
                    height: Layout.tagIconSize
                )
                card.tagLabel.animator().frame = NSRect(
                    x: Layout.suggestionTextX + Layout.tagIconSize + Layout.tagIconGap,
                    y: tagY,
                    width: textWidth - Layout.tagIconSize - Layout.tagIconGap,
                    height: Layout.suggestionTagHeight
                )
                card.enterHint.animator().frame = NSRect(
                    x: targetFrame.width - Layout.enterHintRightInset - Layout.enterHintWidth,
                    y: Layout.enterHintBottomInset,
                    width: Layout.enterHintWidth,
                    height: Layout.enterHintHeight
                )

                // Attachment chips: visible only on the selected card while
                // expanded. Positioned in card-local coords above the enter
                // hint so they sit between the suggestion text and the bottom
                // metadata row.
                if let chips = card.attachmentChips {
                    let chipFrame = attachmentChipFrame(in: targetFrame, stack: chips)
                    chips.frame = chipFrame
                    chips.animator().alphaValue = (isSelected && grows) ? 1 : 0
                }
            }

            if let customInputCard {
                customInputCard.animator().frame = customInputBaseFrame
            }
            if let bottomHintLabel {
                bottomHintLabel.animator().frame = bottomHintBaseFrame
            }
        }

        currentHeightDelta = heightDelta
        return true
    }

    private func collapseSuggestions() {
        guard let panel, let contentView, currentHeightDelta != 0 else {
            expandedSuggestionIndex = nil
            return
        }

        // Re-anchor against the panel's current top so user drags
        // don't snap the panel back to its show-time origin.
        basePanelTopY = panel.frame.maxY
        let collapseHeight = basePanelHeight + customInputHeightDelta
        let newFrame = NSRect(
            x: panel.frame.origin.x,
            y: basePanelTopY - collapseHeight,
            width: panel.frame.width,
            height: collapseHeight
        )
        contentView.frame = NSRect(x: 0, y: 0, width: newFrame.width, height: collapseHeight)
        panel.setFrame(newFrame, display: true, animate: false)
        summaryCard?.frame = summaryBaseFrame

        let suggestionFont = NSFont.systemFont(ofSize: Layout.suggestionFontSize)
        let textWidth = Layout.panelWidth - Layout.suggestionTextX - Layout.cardPaddingX
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Layout.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            for card in suggestionCards {
                setLabelText(
                    card.label,
                    text: card.collapsedText,
                    font: suggestionFont,
                    color: .labelColor,
                    lineSpacing: card.collapsedSingleLine ? 0 : 2,
                    singleLine: card.collapsedSingleLine
                )
                card.label.maximumNumberOfLines = card.collapsedSingleLine ? 1 : 2
                card.label.cell?.wraps = !card.collapsedSingleLine
                card.tint.alphaValue = 0
                card.tagIcon.alphaValue = card.hasTags ? Layout.tagAlpha : 0
                card.tagLabel.alphaValue = card.hasTags ? Layout.tagAlpha : 0
                card.enterHint.alphaValue = 0
                let collapsedHeight = card.collapsedFrame.height
                let optionCorner = Layout.optionCornerRadius(for: collapsedHeight)
                setCornerRadius(card.outer, optionCorner)
                card.tint.layer?.cornerRadius = optionCorner
                card.outer.animator().frame = card.collapsedFrame
                card.number.animator().frame = NSRect(
                    x: Layout.suggestionNumberX,
                    y: (collapsedHeight - Layout.suggestionNumberHeight) / 2,
                    width: Layout.suggestionNumberWidth,
                    height: Layout.suggestionNumberHeight
                )
                let labelHeight = card.collapsedLabelHeight
                let labelY = card.hasTags
                    ? (collapsedHeight - labelHeight - Layout.suggestionTagHeight - Layout.suggestionTagGap) / 2
                        + Layout.suggestionTagHeight
                        + Layout.suggestionTagGap
                    : (collapsedHeight - labelHeight) / 2
                card.label.animator().frame = NSRect(
                    x: Layout.suggestionTextX,
                    y: labelY,
                    width: textWidth,
                    height: labelHeight
                )
                let tagY = card.hasTags
                    ? (collapsedHeight - labelHeight - Layout.suggestionTagHeight - Layout.suggestionTagGap) / 2
                    : labelY
                card.tagIcon.animator().frame = NSRect(
                    x: Layout.suggestionTextX,
                    y: tagY + (Layout.suggestionTagHeight - Layout.tagIconSize) / 2,
                    width: Layout.tagIconSize,
                    height: Layout.tagIconSize
                )
                card.tagLabel.animator().frame = NSRect(
                    x: Layout.suggestionTextX + Layout.tagIconSize + Layout.tagIconGap,
                    y: tagY,
                    width: textWidth - Layout.tagIconSize - Layout.tagIconGap,
                    height: Layout.suggestionTagHeight
                )
                card.attachmentChips?.animator().alphaValue = 0
            }

            if let customInputCard {
                customInputCard.animator().frame = customInputBaseFrame
            }
            if let bottomHintLabel {
                bottomHintLabel.animator().frame = bottomHintBaseFrame
            }
        }
        currentHeightDelta = 0
        expandedSuggestionIndex = nil
    }

    func close() {
        emitVisibilityChange(false)
        tearDownLoadingState()
        softErrorPanel?.close()
        softErrorPanel = nil
        removeMouseMonitors()
        customInputHintLabel?.alphaValue = 0
        panel?.close()
        panel = nil
        contentView = nil
        summaryCard = nil
        summaryContent = nil
        summaryLabel = nil
        summaryExpandButton = nil
        summaryScrollView = nil
        summaryTextView = nil
        summaryFullText = ""
        summaryIsExpandable = false
        summaryIsExpanded = false
        summaryCollapsedHeight = 0
        summaryExpandedHeight = 0
        summaryHeightDelta = 0
        refreshStatusPill = nil
        refreshStatusLabel = nil
        summaryTextY = 0
        suggestionCards = []
        suggestionClickTargets = []
        customInputField?.onFocusChanged?(false)
        customInputCard = nil
        customInputBaseFrame = .zero
        customInputField = nil
        customInputNumber = nil
        customInputHintLabel = nil
        customInputTint = nil
        customInputMode = .followUp
        customFollowUpButton = nil
        customWriteButton = nil
        bottomHintLabel = nil
        bottomHintBaseFrame = .zero
        showsTldrHeader = false
        expandedSuggestionIndex = nil
        currentHeightDelta = 0
        customInputHeightDelta = 0
        hasPlayedSuggestionArrival = false
        isDismissing = false

        if let prev = previousFrontmost,
           !prev.isTerminated,
           prev.processIdentifier != NSRunningApplication.current.processIdentifier {
            prev.activate()
        }
        previousFrontmost = nil
    }

    private func emitVisibilityChange(_ visible: Bool) {
        guard lastEmittedVisible != visible else { return }
        lastEmittedVisible = visible
        onVisibilityChange?(visible)
    }

    func dismissAnimated(completion: (() -> Void)? = nil) {
        guard let panel, let contentView, !isDismissing else {
            completion?()
            return
        }
        // Pin state belongs to the active panel session. A real dismissal
        // (Esc, or the unpinned insert path) ends that session, so reset.
        // Don't reset inside `close()` — `show()` calls `close()` on every
        // rebuild and that would clobber a user's pin mid-session.
        if isPinned {
            setPinned(false)
        }
        isDismissing = true
        softErrorPanel?.close()
        softErrorPanel = nil
        // Anchor the contentView's layer at center so the scale-down reads as a
        // shrink-into-self rather than a top-left collapse. Adjust position so
        // the layer doesn't visibly jump when we shift the anchor point.
        if let layer = contentView.layer {
            let oldAnchor = layer.anchorPoint
            let newAnchor = CGPoint(x: 0.5, y: 0.5)
            let dx = (newAnchor.x - oldAnchor.x) * layer.bounds.width
            let dy = (newAnchor.y - oldAnchor.y) * layer.bounds.height
            layer.anchorPoint = newAnchor
            layer.position = CGPoint(x: layer.position.x + dx, y: layer.position.y + dy)

            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1.0
            scale.toValue = 0.96
            scale.duration = 0.22
            scale.timingFunction = CAMediaTimingFunction(name: .easeIn)
            scale.fillMode = .forwards
            scale.isRemovedOnCompletion = false
            layer.add(scale, forKey: "dismissScale")
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.close()
            completion?()
        }
    }

    func showSoftError(_ message: String) {
        guard let overlayPanel = panel else { return }
        softErrorPanel?.close()
        softErrorPanel = nil

        let tint = NSColor.systemRed
        let width = Layout.panelWidth
        let height: CGFloat = 44

        let landX = overlayPanel.frame.origin.x + Layout.shadowBleed
        let landY = overlayPanel.frame.maxY - Layout.shadowBleed + 8
        let landFrame = NSRect(x: landX, y: landY, width: width, height: height)
        let startFrame = landFrame.offsetBy(dx: 0, dy: 8)

        let bannerPanel = NSPanel(
            contentRect: startFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        bannerPanel.level = .screenSaver
        bannerPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        bannerPanel.isOpaque = false
        bannerPanel.backgroundColor = .clear
        bannerPanel.hasShadow = false
        bannerPanel.ignoresMouseEvents = true
        bannerPanel.isReleasedWhenClosed = false
        bannerPanel.alphaValue = 0

        let container = NSView(frame: NSRect(origin: .zero, size: startFrame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        bannerPanel.contentView = container

        let pill = NSView(frame: NSRect(origin: .zero, size: startFrame.size))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = tint.withAlphaComponent(0.92).cgColor
        pill.layer?.cornerRadius = height / 2
        pill.layer?.shadowColor = NSColor.black.cgColor
        pill.layer?.shadowOpacity = 0.25
        pill.layer?.shadowRadius = 8
        pill.layer?.shadowOffset = CGSize(width: 0, height: -3)
        container.addSubview(pill)

        let icon = NSImageView(frame: NSRect(x: 18, y: 11, width: 22, height: 22))
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        icon.contentTintColor = .white
        pill.addSubview(icon)

        let messageLabel = label(
            frame: NSRect(x: 50, y: 11, width: width - 72, height: 22),
            text: message,
            font: NSFont.systemFont(ofSize: 13, weight: .medium),
            color: .white,
            singleLine: true
        )
        pill.addSubview(messageLabel)

        bannerPanel.orderFrontRegardless()
        softErrorPanel = bannerPanel

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            bannerPanel.animator().setFrame(landFrame, display: true)
            bannerPanel.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self, weak bannerPanel] in
            guard let self, let bannerPanel, self.softErrorPanel === bannerPanel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                bannerPanel.animator().alphaValue = 0
            } completionHandler: {
                bannerPanel.close()
                if self.softErrorPanel === bannerPanel {
                    self.softErrorPanel = nil
                }
            }
        }
    }

    func confirmCopy(completion: @escaping () -> Void) {
        let screen = panel?.screen ?? NSScreen.main
        if let screen {
            CopyConfirmationPill.show(on: screen)
        }
        completion()
    }

    func activeAttachments(for index: Int) -> [AttachmentRef] {
        guard index >= 0, index < suggestionCards.count else { return [] }
        return suggestionCards[index].attachments
    }

    func confirmInsert(completion: @escaping () -> Void) {
        completion()
    }

    func confirmPasteFallback() {
        let screen = panel?.screen ?? NSScreen.main
        if let screen {
            PasteFallbackPill.show(on: screen)
        }
    }

    /// Drops the "Hit ↩ to send to tl;dr" pill in from the menubar and
    /// keeps it visible until `dismissSubmitPrompt()` (no auto-fade). Safe
    /// to call repeatedly — a previous pill is closed first.
    func showSubmitPrompt() {
        submitPromptClose?()
        submitPromptClose = nil
        let screen = panel?.screen ?? NSScreen.main
        if let screen {
            submitPromptClose = SubmitPromptPill.show(on: screen)
        }
    }

    /// Closes the submit-prompt pill if it's showing. Safe to call when no
    /// pill is up.
    func dismissSubmitPrompt() {
        submitPromptClose?()
        submitPromptClose = nil
    }

    private static let useLegacyGlass: Bool = RuntimeEnvironment.forceLegacyGlass()

    private func makeGlassPane(frame: NSRect, cornerRadius: CGFloat) -> GlassPane {
        if #available(macOS 26.0, *), !Self.useLegacyGlass {
            let glass = NSGlassEffectView(frame: frame)
            glass.cornerRadius = cornerRadius
            glass.style = .regular
            let inner = NSView(frame: NSRect(origin: .zero, size: frame.size))
            inner.autoresizingMask = [.width, .height]
            glass.contentView = inner
            suppressOutline(glass)
            return GlassPane(outer: glass, content: inner)
        }

        // `.popover` is the adaptive (light/dark) frosted material that comes
        // closest to NSGlassEffectView and stays legible over arbitrary app
        // backgrounds; `.hudWindow` is intentionally a dark HUD chrome and
        // rendered as black boxes when stacked card-on-card.
        let visual = NSVisualEffectView(frame: frame)
        visual.material = .popover
        visual.blendingMode = .behindWindow
        visual.state = .active
        // `maskImage` clips the underlying material backing — `layer.cornerRadius`
        // alone leaves the frost backing's outer rect square even though the
        // hosting layer composites rounded.
        visual.maskImage = Self.roundedMaskImage(cornerRadius: cornerRadius)
        suppressOutline(visual)
        return GlassPane(outer: visual, content: visual)
    }

    private static func roundedMaskImage(cornerRadius: CGFloat) -> NSImage {
        let radius = max(cornerRadius, 0.5)
        let edge = max(radius * 2 + 1, 2)
        let size = NSSize(width: edge, height: edge)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    private func suppressOutline(_ view: NSView) {
        view.focusRingType = .none
        let shadow = NSShadow()
        shadow.shadowColor = .clear
        shadow.shadowBlurRadius = 0
        shadow.shadowOffset = .zero
        view.shadow = shadow
        view.wantsLayer = true
        view.layer?.borderWidth = 0
        view.layer?.borderColor = NSColor.clear.cgColor
        // `hideActiveFirstResponderIndication` is a private NSView selector
        // the Python overlay calls to suppress AppKit's focus halo around
        // glass views. It isn't exposed in Swift's NSView API, so route
        // through the Obj-C runtime. Safe no-op if the selector is absent.
        let selector = Selector(("hideActiveFirstResponderIndication"))
        if view.responds(to: selector) {
            view.perform(selector)
        }
    }

    private func setCornerRadius(_ view: NSView, _ radius: CGFloat) {
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
            glass.cornerRadius = radius
            return
        }
        if let visual = view as? NSVisualEffectView {
            visual.maskImage = Self.roundedMaskImage(cornerRadius: radius)
            return
        }
        view.layer?.cornerRadius = radius
    }

    private func installLoadingDot(in host: NSView, at frame: NSRect) -> NSView {
        let dot = NSView(frame: frame)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = frame.height / 2
        dot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        // Composite above the glass material so the accent reads cleanly
        // through the frosted backdrop.
        dot.layer?.zPosition = 1
        host.addSubview(dot)

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.4
        pulse.duration = 0.7
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.layer?.add(pulse, forKey: "loadingPulse")
        return dot
    }

    private func tearDownLoadingState() {
        loadingPulseDot?.layer?.removeAllAnimations()
        loadingPulseDot?.removeFromSuperview()
        loadingPulseDot = nil
        isLoadingState = false
    }

    private func showRefreshStatusPill() {
        guard let contentView else { return }
        let finalFrame = NSRect(
            x: Layout.shadowBleed,
            y: summaryBaseFrame.minY - Layout.sectionGap - Layout.refreshPillHeight,
            width: Layout.panelWidth,
            height: Layout.refreshPillHeight
        )
        if let refreshStatusPill {
            refreshStatusPill.frame = finalFrame
            refreshStatusPill.alphaValue = 1
            return
        }

        let pane = makeGlassPane(
            frame: finalFrame.offsetBy(dx: 0, dy: 10),
            cornerRadius: Layout.optionCornerRadius(for: Layout.refreshPillHeight)
        )
        pane.outer.alphaValue = 0
        let statusLabel = label(
            frame: NSRect(
                x: 24,
                y: (Layout.refreshPillHeight - Layout.enterHintHeight) / 2,
                width: Layout.panelWidth - 48,
                height: Layout.enterHintHeight
            ),
            text: "Regenerating suggestions...",
            font: NSFont.systemFont(ofSize: Layout.hintFontSize, weight: .medium),
            color: .secondaryLabelColor,
            singleLine: true
        )
        statusLabel.alignment = .center
        pane.content.addSubview(statusLabel)
        contentView.addSubview(pane.outer)
        refreshStatusPill = pane.outer
        refreshStatusLabel = statusLabel

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            guard self.refreshStatusPill === pane.outer else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Layout.animationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                pane.outer.animator().alphaValue = 1
                pane.outer.animator().frame = finalFrame
            }
        }
    }

    private func hideRefreshStatusPill() {
        guard let pill = refreshStatusPill else { return }
        refreshStatusPill = nil
        refreshStatusLabel = nil
        let targetFrame = pill.frame.offsetBy(dx: 0, dy: 8)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Layout.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pill.animator().alphaValue = 0
            pill.animator().frame = targetFrame
        } completionHandler: {
            pill.removeFromSuperview()
        }
    }

    private func playArrivalAnimation(summary: NSView?, cards: [NSView]) {
        animateScale(view: summary, from: 0.96, to: 1.0, duration: Layout.momentDuration)
        for (index, card) in cards.enumerated() {
            card.alphaValue = 0
            let finalFrame = card.frame
            card.frame = finalFrame.offsetBy(dx: 0, dy: 14)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.06) {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Layout.momentDuration
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    card.animator().frame = finalFrame
                    card.animator().alphaValue = 1
                }
            }
        }
    }

    private func animateScale(view: NSView?, from: CGFloat, to: CGFloat, duration: TimeInterval) {
        guard let view else { return }
        view.wantsLayer = true
        let animation = CASpringAnimation(keyPath: "transform.scale")
        animation.fromValue = from
        animation.toValue = to
        animation.mass = 0.8
        animation.stiffness = 220
        animation.damping = 17
        animation.initialVelocity = 0
        animation.duration = duration
        view.layer?.add(animation, forKey: "arrivalScale")
        view.layer?.setAffineTransform(CGAffineTransform(scaleX: to, y: to))
    }

    private func makeSuggestionCard(
        frame: NSRect,
        index: Int,
        detail: SuggestionDetail,
        font: NSFont
    ) -> (
        outer: NSView,
        content: NSView,
        tint: NSView,
        number: NSTextField,
        label: NSTextField,
        tagIcon: NSImageView,
        tagLabel: NSTextField,
        enterHint: NSTextField,
        attachmentChips: NSStackView?
    ) {
        let pane = makeGlassPane(frame: frame, cornerRadius: Layout.optionCornerRadius(for: frame.height))
        let clickTarget = SuggestionCardClickTarget(index: index - 1) { [weak self] index in
            self?.onChoiceKey?(index)
        }
        suggestionClickTargets.append(clickTarget)
        let click = NSClickGestureRecognizer(target: clickTarget, action: #selector(SuggestionCardClickTarget.clicked(_:)))
        click.numberOfClicksRequired = 1
        click.buttonMask = 0x1
        click.delaysPrimaryMouseButtonEvents = false
        pane.outer.addGestureRecognizer(click)

        let tint = NSView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height))
        tint.wantsLayer = true
        tint.layer?.cornerRadius = Layout.optionCornerRadius(for: frame.height)
        tint.layer?.masksToBounds = true
        tint.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.22).cgColor
        tint.autoresizingMask = [.width, .height]
        tint.alphaValue = 0
        pane.content.addSubview(tint)

        let number = label(
            frame: NSRect(
                x: Layout.suggestionNumberX,
                y: (frame.height - Layout.suggestionNumberHeight) / 2,
                width: Layout.suggestionNumberWidth,
                height: Layout.suggestionNumberHeight
            ),
            text: "\(index)",
            font: NSFont.systemFont(ofSize: Layout.suggestionFontSize, weight: .medium),
            color: .secondaryLabelColor,
            singleLine: true
        )
        number.alignment = .center
        pane.content.addSubview(number)

        let textWidth = frame.width - Layout.suggestionTextX - Layout.cardPaddingX
        let renderedTags = renderedTags(detail.tags)
        let tagText = renderTags(renderedTags)
        let hasTags = !renderedTags.isEmpty
        let primaryTagColor = tagColor(for: renderedTags.first)
        let collapsedLabelHeight = collapsedTextHeight(for: detail, width: textWidth, font: font)
        let collapsedSingleLine = collapsedTextIsSingleLine(for: detail, width: textWidth, font: font)
        let collapsedText = collapsedDisplayText(for: detail, width: textWidth, font: font)
        let textBlockY = hasTags
            ? (frame.height - collapsedLabelHeight - Layout.suggestionTagHeight - Layout.suggestionTagGap) / 2
            : (frame.height - collapsedLabelHeight) / 2
        let suggestionLabel = SelectableSuggestionTextField(labelWithString: "")
        suggestionLabel.frame = NSRect(
            x: Layout.suggestionTextX,
            y: hasTags ? textBlockY + Layout.suggestionTagHeight + Layout.suggestionTagGap : textBlockY,
            width: textWidth,
            height: collapsedLabelHeight
        )
        suggestionLabel.isEditable = false
        suggestionLabel.isSelectable = true
        suggestionLabel.isBordered = false
        suggestionLabel.drawsBackground = false
        suggestionLabel.allowsEditingTextAttributes = false
        setLabelText(
            suggestionLabel,
            text: collapsedText,
            font: font,
            color: .labelColor,
            lineSpacing: collapsedSingleLine ? 0 : 2,
            singleLine: collapsedSingleLine
        )
        suggestionLabel.maximumNumberOfLines = collapsedSingleLine ? 1 : 2
        suggestionLabel.lineBreakMode = .byTruncatingTail
        suggestionLabel.cell?.wraps = !collapsedSingleLine
        // Click without drag = insert (matches the card's click-to-insert
        // gesture). The gesture recognizer on the parent pane never fires
        // for clicks on this label because mouseDown is consumed here, so
        // we re-route the click directly to the same handler.
        let cardChoiceIndex = index - 1
        suggestionLabel.onClick = { [weak self] in
            self?.onChoiceKey?(cardChoiceIndex)
        }
        pane.content.addSubview(suggestionLabel)

        let tagIcon = makeTagIcon(frame: NSRect(
            x: Layout.suggestionTextX,
            y: textBlockY + (Layout.suggestionTagHeight - Layout.tagIconSize) / 2,
            width: Layout.tagIconSize,
            height: Layout.tagIconSize
        ), color: primaryTagColor)
        tagIcon.alphaValue = hasTags ? Layout.tagAlpha : 0
        tagIcon.isHidden = !hasTags
        pane.content.addSubview(tagIcon)

        let tagLabel = label(
            frame: NSRect(
                x: Layout.suggestionTextX + Layout.tagIconSize + Layout.tagIconGap,
                y: textBlockY,
                width: textWidth - Layout.tagIconSize - Layout.tagIconGap,
                height: Layout.suggestionTagHeight
            ),
            text: tagText,
            font: NSFont.systemFont(ofSize: Layout.tagFontSize, weight: .semibold),
            color: primaryTagColor,
            singleLine: true
        )
        tagLabel.attributedStringValue = makeTagAttributedString(
            tags: renderedTags,
            attachmentCount: detail.attachments.count,
            font: NSFont.systemFont(ofSize: Layout.tagFontSize, weight: .semibold)
        )
        tagLabel.alphaValue = hasTags ? Layout.tagAlpha : 0
        tagLabel.isHidden = !hasTags
        pane.content.addSubview(tagLabel)

        let enterHint = label(
            frame: NSRect(
                x: frame.width - Layout.enterHintRightInset - Layout.enterHintWidth,
                y: Layout.enterHintBottomInset,
                width: Layout.enterHintWidth,
                height: Layout.enterHintHeight
            ),
            text: "\u{23CE} Enter to insert",
            font: NSFont.systemFont(ofSize: Layout.hintFontSize),
            color: .secondaryLabelColor,
            singleLine: true
        )
        enterHint.alignment = .right
        enterHint.alphaValue = 0
        enterHint.autoresizingMask = [.minXMargin]
        pane.content.addSubview(enterHint)

        let attachmentChips: NSStackView?
        if !detail.attachments.isEmpty {
            let stack = makeAttachmentChipStack(for: detail.attachments)
            // Hidden in the collapsed resting state — expandSuggestion fades
            // these in for the selected card so the metadata stays out of the
            // way until the user commits to a choice. The collapsed hint
            // (paperclip + "1 FILE") is baked into the tag label's attributed
            // string instead, so it rides the same baseline + truncation
            // behavior as the tags themselves.
            stack.alphaValue = 0
            stack.autoresizingMask = [.maxXMargin, .maxYMargin]
            stack.frame = attachmentChipFrame(in: frame, stack: stack)
            pane.content.addSubview(stack)
            attachmentChips = stack
        } else {
            attachmentChips = nil
        }

        return (pane.outer, pane.content, tint, number, suggestionLabel, tagIcon, tagLabel, enterHint, attachmentChips)
    }

    // MARK: - Attachment chip helpers

    private func makeAttachmentChipStack(for refs: [AttachmentRef]) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = Layout.attachmentChipSpacing
        stack.alignment = .centerY
        stack.distribution = .fill
        for ref in refs {
            stack.addArrangedSubview(makeAttachmentChip(for: ref))
        }
        return stack
    }

    private func makeAttachmentChip(for ref: AttachmentRef) -> NSView {
        // Called from the suggestions panel-building path which always runs
        // on the main thread; bridge isolation explicitly because
        // SuggestionsOverlay isn't itself @MainActor.
        let entry = MainActor.assumeIsolated {
            AttachmentLibrary.shared.entries.first { $0.id == ref.id }
        }
        let displayName = entry?.displayName ?? ref.id
        let kind = entry?.kind ?? .other

        let chip = NSView()
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 6
        chip.layer?.borderWidth = 1
        chip.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        chip.layer?.backgroundColor = NSColor.clear.cgColor
        chip.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: Self.attachmentSymbol(for: kind), accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Layout.attachmentChipFontSize, weight: .regular)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: displayName)
        label.font = NSFont.systemFont(ofSize: Layout.attachmentChipFontSize)
        label.textColor = .secondaryLabelColor
        // Head-truncate so the extension stays visible (file recognition
        // anchors on the tail, not the middle).
        label.lineBreakMode = .byTruncatingHead
        label.cell?.truncatesLastVisibleLine = true
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        chip.addSubview(icon)
        chip.addSubview(label)
        NSLayoutConstraint.activate([
            chip.heightAnchor.constraint(equalToConstant: Layout.attachmentChipHeight),
            icon.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: Layout.attachmentChipPaddingX),
            icon.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Layout.attachmentChipIconSize),
            icon.heightAnchor.constraint(equalToConstant: Layout.attachmentChipIconSize),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Layout.attachmentChipIconLabelGap),
            label.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -Layout.attachmentChipPaddingX),
            label.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: Layout.attachmentChipMaxLabelWidth),
        ])

        let trimmedReason = ref.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        chip.toolTip = trimmedReason.isEmpty ? displayName : "\(displayName) — \(trimmedReason)"
        return chip
    }

    private static func attachmentSymbol(for kind: AttachmentKind) -> String {
        switch kind {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .text: return "doc.plaintext"
        case .other: return "doc"
        }
    }

    private func attachmentChipFrame(in cardFrame: NSRect, stack: NSStackView) -> NSRect {
        let fittingWidth = max(0, stack.fittingSize.width)
        let availableWidth = max(0, cardFrame.width - Layout.suggestionTextX - Layout.cardPaddingX)
        let width = min(fittingWidth, availableWidth)
        return NSRect(
            x: Layout.suggestionTextX,
            y: Layout.attachmentChipBottomInset,
            width: width,
            height: Layout.attachmentChipHeight
        )
    }

    private func makeTagIcon(frame: NSRect, color: NSColor) -> NSImageView {
        let imageView = NSImageView(frame: frame)
        imageView.image = NSImage(systemSymbolName: "tag.fill", accessibilityDescription: "Tag")
        imageView.contentTintColor = color
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Layout.tagFontSize, weight: .semibold)
        imageView.imageScaling = .scaleProportionallyDown
        return imageView
    }

    private func renderTags(_ tags: [String]) -> String {
        let rendered = renderedTags(tags)
        return rendered.isEmpty ? "" : rendered.joined(separator: "  \u{00B7}  ")
    }

    private func renderedTags(_ tags: [String]) -> [String] {
        let rendered = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(2)
            .map { $0.uppercased() }
        return Array(rendered)
    }

    private func makeTagAttributedString(tags: [String], attachmentCount: Int, font: NSFont) -> NSAttributedString {
        let attributed = NSMutableAttributedString()
        for (index, tag) in tags.enumerated() {
            if index > 0 {
                attributed.append(NSAttributedString(
                    string: "  \u{00B7}  ",
                    attributes: [
                        .font: font,
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]
                ))
            }
            attributed.append(NSAttributedString(
                string: tag,
                attributes: [
                    .font: font,
                    .foregroundColor: tagColor(for: tag),
                ]
            ))
        }
        if attachmentCount > 0 {
            if !tags.isEmpty {
                attributed.append(NSAttributedString(
                    string: "  \u{00B7}  ",
                    attributes: [
                        .font: font,
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]
                ))
            }
            attributed.append(makeAttachmentSuffix(count: attachmentCount, font: font))
        }
        return attributed
    }

    /// `<paperclip> N FILE(S)` rendered inline with the tag row so the
    /// attachment hint shares the tags' baseline + visual weight. The SF
    /// Symbol image is marked template-tinted so it picks up the foreground
    /// color attribute applied to its range.
    private func makeAttachmentSuffix(count: Int, font: NSFont) -> NSAttributedString {
        guard count > 0 else { return NSAttributedString() }
        let result = NSMutableAttributedString()
        let color = NSColor.secondaryLabelColor

        let attachment = NSTextAttachment()
        let config = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .semibold)
        if let raw = NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil),
           let image = raw.withSymbolConfiguration(config) {
            image.isTemplate = true
            attachment.image = image
            attachment.bounds = NSRect(
                x: 0,
                y: font.descender,
                width: image.size.width,
                height: image.size.height
            )
        }
        let glyphString = NSMutableAttributedString(attachment: attachment)
        glyphString.addAttribute(
            .foregroundColor,
            value: color,
            range: NSRange(location: 0, length: glyphString.length)
        )
        result.append(glyphString)

        let label = count == 1 ? " 1 FILE" : " \(count) FILES"
        result.append(NSAttributedString(
            string: label,
            attributes: [.font: font, .foregroundColor: color]
        ))
        return result
    }

    private func tagColor(for tag: String?) -> NSColor {
        guard let tag, !tag.isEmpty else {
            return .systemBlue
        }
        switch normalizedTagKey(tag) {
        case "reply", "respond", "response", "confirm", "ack", "acknowledge":
            return .systemBlue
        case "ask", "question", "request":
            return .systemPurple
        case "pushback", "disagree", "objection", "challenge":
            return .systemRed
        case "nextstep", "next", "action", "todo", "update", "implement", "fix":
            return .systemGreen
        case "clarify", "clarification":
            return .systemTeal
        case "evidence", "proof", "logs", "check", "verify":
            return .systemIndigo
        case "commit", "ship", "done":
            return .systemMint
        case "defer", "later", "wait":
            return .systemOrange
        case "draft", "rewrite", "edit":
            return .systemPink
        default:
            let palette: [NSColor] = [
                .systemBlue,
                .systemPurple,
                .systemTeal,
                .systemGreen,
                .systemOrange,
                .systemPink,
                .systemIndigo,
            ]
            return palette[stableTagIndex(for: tag, count: palette.count)]
        }
    }

    private func normalizedTagKey(_ tag: String) -> String {
        tag
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private func stableTagIndex(for tag: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let value = tag.unicodeScalars.reduce(0) { partial, scalar in
            (partial &* 31 &+ Int(scalar.value)) & 0x7fffffff
        }
        return value % count
    }

    private func makeCustomInputCard(
        frame: NSRect,
        font: NSFont
    ) -> (
        outer: NSView,
        content: NSView,
        field: CustomReplyField,
        number: NSTextField,
        enterHint: NSTextField,
        tint: NSView,
        followUpButton: NSButton,
        writeButton: NSButton
    ) {
        let cornerRadius = min(frame.height / 2, Layout.suggestionCornerRadius)
        let pane = makeGlassPane(frame: frame, cornerRadius: cornerRadius)

        let click = NSClickGestureRecognizer(target: self, action: #selector(customInputCardClicked(_:)))
        click.numberOfClicksRequired = 1
        click.buttonMask = 0x1
        click.delaysPrimaryMouseButtonEvents = false
        pane.outer.addGestureRecognizer(click)

        let tint = NSView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height))
        tint.wantsLayer = true
        tint.layer?.cornerRadius = cornerRadius
        tint.layer?.masksToBounds = true
        tint.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.22).cgColor
        tint.autoresizingMask = [.width, .height]
        tint.alphaValue = 0
        pane.content.addSubview(tint)

        let number = label(
            frame: NSRect(
                x: Layout.suggestionNumberX,
                y: (frame.height - Layout.suggestionNumberHeight) / 2,
                width: Layout.suggestionNumberWidth,
                height: Layout.suggestionNumberHeight
            ),
            text: "4",
            font: NSFont.systemFont(ofSize: Layout.suggestionFontSize, weight: .medium),
            color: .secondaryLabelColor,
            singleLine: true
        )
        number.alignment = .center
        pane.content.addSubview(number)

        let modeX = frame.width - Layout.cardPaddingX - Layout.customModeWidth
        let followUpButton = customInputModeButton(
            title: "Follow up",
            tag: 0,
            frame: NSRect(
                x: modeX,
                y: (frame.height - Layout.customModeButtonHeight) / 2,
                width: Layout.customModeFollowUpWidth,
                height: Layout.customModeButtonHeight
            )
        )
        pane.content.addSubview(followUpButton)

        let writeButton = customInputModeButton(
            title: "Write",
            tag: 1,
            frame: NSRect(
                x: modeX + Layout.customModeFollowUpWidth,
                y: (frame.height - Layout.customModeButtonHeight) / 2,
                width: Layout.customModeWidth - Layout.customModeFollowUpWidth,
                height: Layout.customModeButtonHeight
            )
        )
        pane.content.addSubview(writeButton)

        let textHeight = Layout.customInputTextHeight
        let fieldX = Layout.suggestionTextX
        let field = CustomReplyField(frame: NSRect(
            x: fieldX,
            y: (frame.height - textHeight) / 2,
            width: modeX - Layout.customModeGap - fieldX,
            height: textHeight
        ))
        field.placeholderAttributedString = NSAttributedString(
            string: "Type your own reply...",
            attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: font,
            ]
        )
        field.font = font
        field.textColor = .labelColor
        field.onFocusChanged = { [weak self] active in
            if active {
                self?.collapseSuggestions()
            }
            self?.setCustomInputHintVisible(active)
            self?.onCustomInputFocusChanged?(active)
        }
        field.onLocalKeyDown = { [weak self] event in
            self?.handleLocalKeyDown(event) ?? false
        }
        field.onTextChanged = { [weak self] _ in
            self?.applyCustomInputModeVisuals()
        }
        field.onContentHeightChanged = { [weak self] _ in
            self?.updateCustomInputHeight()
        }
        pane.content.addSubview(field)

        let hintWidth: CGFloat = 104
        let enterHint = label(
            frame: NSRect(
                x: modeX - Layout.customModeGap - hintWidth,
                y: Layout.enterHintBottomInset,
                width: hintWidth,
                height: Layout.enterHintHeight
            ),
            text: "\u{23CE} Enter to insert",
            font: NSFont.systemFont(ofSize: Layout.hintFontSize),
            color: .secondaryLabelColor,
            singleLine: true
        )
        enterHint.alignment = .right
        enterHint.alphaValue = 0
        enterHint.autoresizingMask = [.minXMargin]
        pane.content.addSubview(enterHint)

        return (pane.outer, pane.content, field, number, enterHint, tint, followUpButton, writeButton)
    }

    private func customInputModeButton(title: String, tag: Int, frame: NSRect) -> NSButton {
        let button = NSButton(frame: frame)
        button.title = title
        button.tag = tag
        button.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        button.alignment = .center
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.setButtonType(.momentaryPushIn)
        button.target = self
        button.action = #selector(customInputModeButtonClicked(_:))
        button.wantsLayer = true
        button.layer?.cornerRadius = 10
        button.layer?.masksToBounds = true
        return button
    }

    @objc private func customInputModeButtonClicked(_ sender: NSButton) {
        setCustomInputMode(sender.tag == 1 ? .write : .followUp, focusField: true)
    }

    private func setCustomInputMode(_ mode: CustomInputMode, focusField: Bool) {
        customInputMode = mode
        applyCustomInputModeVisuals()
        if focusField {
            focusCustomInput()
        }
    }

    private func updateCustomInputHeight() {
        guard let panel, let contentView, let card = customInputCard,
              let field = customInputField else { return }

        let textHeight = field.contentTextHeight()
        let verticalPadding = Layout.customInputMinHeight - Layout.customInputTextHeight
        let newCardHeight = min(
            max(Layout.customInputMinHeight, textHeight + verticalPadding),
            Layout.customInputMaxHeight
        )
        let newDelta = newCardHeight - Layout.customInputMinHeight
        guard abs(newDelta - customInputHeightDelta) > 0.5 else { return }

        let panelDelta = newDelta - customInputHeightDelta
        customInputHeightDelta = newDelta

        field.scrollView.hasVerticalScroller = newCardHeight >= Layout.customInputMaxHeight

        // Re-anchor against the panel's current top so user drags
        // don't snap the panel back to its show-time origin.
        basePanelTopY = panel.frame.maxY
        let totalHeight = basePanelHeight + summaryHeightDelta + currentHeightDelta + customInputHeightDelta
        let newPanelFrame = NSRect(
            x: panel.frame.origin.x,
            y: basePanelTopY - totalHeight,
            width: panel.frame.width,
            height: totalHeight
        )

        contentView.frame = NSRect(x: 0, y: 0, width: newPanelFrame.width, height: totalHeight)
        panel.setFrame(newPanelFrame, display: true, animate: false)

        let cardTargetY = card.frame.origin.y

        if panelDelta != 0 {
            if let sc = summaryCard {
                sc.frame = sc.frame.offsetBy(dx: 0, dy: panelDelta)
            }
            summaryBaseFrame = summaryBaseFrame.offsetBy(dx: 0, dy: panelDelta)
            for i in suggestionCards.indices {
                suggestionCards[i].outer.frame = suggestionCards[i].outer.frame.offsetBy(dx: 0, dy: panelDelta)
                suggestionCards[i].collapsedFrame = suggestionCards[i].collapsedFrame.offsetBy(dx: 0, dy: panelDelta)
            }
            if let bl = bottomHintLabel {
                bl.frame = bl.frame.offsetBy(dx: 0, dy: panelDelta)
            }
            bottomHintBaseFrame = bottomHintBaseFrame.offsetBy(dx: 0, dy: panelDelta)
            card.frame = card.frame.offsetBy(dx: 0, dy: panelDelta)
        }

        customInputBaseFrame = NSRect(
            x: customInputBaseFrame.origin.x,
            y: cardTargetY,
            width: customInputBaseFrame.width,
            height: newCardHeight
        )

        let cornerRadius = min(newCardHeight / 2, Layout.suggestionCornerRadius)
        let halfPad = verticalPadding / 2
        let fieldHeight = newCardHeight - verticalPadding

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Layout.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            card.animator().frame = customInputBaseFrame

            var ff = field.frame
            ff.origin.y = halfPad
            ff.size.height = fieldHeight
            field.animator().frame = ff

            if let num = customInputNumber {
                var nf = num.frame
                nf.origin.y = (newCardHeight - Layout.suggestionNumberHeight) / 2
                num.animator().frame = nf
            }

            if let fb = customFollowUpButton {
                var bf = fb.frame
                bf.origin.y = (newCardHeight - Layout.customModeButtonHeight) / 2
                fb.animator().frame = bf
            }
            if let wb = customWriteButton {
                var bf = wb.frame
                bf.origin.y = (newCardHeight - Layout.customModeButtonHeight) / 2
                wb.animator().frame = bf
            }
        }
        setCornerRadius(card, cornerRadius)
        customInputTint?.layer?.cornerRadius = cornerRadius

        applyCustomInputModeVisuals()
    }

    private func applyCustomInputModeVisuals() {
        let activeColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        let inactiveColor = NSColor.clear.cgColor
        let buttonFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let hasTypedText = customInputEditorText.isEmpty == false
        let cardWidth = customInputBaseFrame.width
        let modeX = cardWidth - Layout.cardPaddingX - Layout.customModeWidth
        let modeRight = modeX + Layout.customModeWidth
        let buttons: [(NSButton?, CustomInputMode, CGFloat)] = [
            (customFollowUpButton, .followUp, modeX),
            (customWriteButton, .write, modeX + Layout.customModeFollowUpWidth),
        ]
        for (button, mode, _) in buttons {
            guard let button else { continue }
            let isActive = customInputMode == mode
            button.layer?.backgroundColor = isActive ? activeColor : inactiveColor
            button.attributedTitle = NSAttributedString(
                string: button.title,
                attributes: [
                    .foregroundColor: isActive ? NSColor.labelColor : NSColor.secondaryLabelColor,
                    .font: buttonFont,
                ]
            )
        }
        // Slide both pills' alpha + x through a single animation block so the
        // active pill drifts to the right edge while the inactive one fades
        // at the same anchor. Without this the inactive pill snaps to alpha 0
        // synchronously while only the active one slides — visible flicker.
        let fieldX = Layout.suggestionTextX
        let activeButtonWidth = customInputMode == .followUp
            ? Layout.customModeFollowUpWidth
            : (Layout.customModeWidth - Layout.customModeFollowUpWidth)
        let effectiveRightEdge: CGFloat = hasTypedText
            ? (modeRight - activeButtonWidth - Layout.customModeGap)
            : (modeX - Layout.customModeGap)
        let targetFieldWidth = effectiveRightEdge - fieldX
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Layout.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for (button, mode, defaultX) in buttons {
                guard let button else { continue }
                let isActive = customInputMode == mode
                let targetAlpha: CGFloat = (isActive || !hasTypedText) ? 1 : 0
                let targetX = hasTypedText ? (modeRight - button.frame.width) : defaultX
                var targetFrame = button.frame
                targetFrame.origin.x = targetX
                button.animator().alphaValue = targetAlpha
                button.animator().frame = targetFrame
            }
            if let field = customInputField {
                var ff = field.frame
                ff.size.width = targetFieldWidth
                field.animator().frame = ff
            }
        }
        guard let field = customInputField, let hint = customInputHintLabel else { return }
        let placeholder = customInputMode == .followUp
            ? "Tell Blink what to change..."
            : "Type your own reply..."
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: field.font ?? NSFont.systemFont(ofSize: Layout.suggestionFontSize),
            ]
        )
        setLabelText(
            hint,
            text: "",
            font: NSFont.systemFont(ofSize: Layout.hintFontSize),
            color: .clear,
            lineSpacing: 0,
            singleLine: true
        )
        hint.alignment = .right
    }

    private func setCustomInputHintVisible(_ visible: Bool) {
        applyCustomInputFocusState(focused: visible, animated: true)
    }

    private func applyCustomInputFocusState(focused: Bool, animated: Bool) {
        guard let hint = customInputHintLabel,
              let tint = customInputTint else { return }
        let tintAlpha: CGFloat = focused ? 1 : 0
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Layout.animationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                hint.animator().alphaValue = 0
                tint.animator().alphaValue = tintAlpha
            }
        } else {
            hint.layer?.removeAllAnimations()
            tint.layer?.removeAllAnimations()
            hint.alphaValue = 0
            tint.alphaValue = tintAlpha
        }
        applyCustomInputModeVisuals()
    }

    private func installMouseMonitors() {
        removeMouseMonitors()
        lastOutsideClickAt = 0
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            DispatchQueue.main.async {
                self?.handleMouseDownForDismiss(event)
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handleMouseDownForDismiss(event)
            return event
        }
    }

    private func removeMouseMonitors() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
        }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        lastOutsideClickAt = 0
    }

    private func handleMouseDownForDismiss(_ event: NSEvent) {
        guard let panel else { return }
        let location = NSEvent.mouseLocation
        guard !panel.frame.contains(location) else {
            lastOutsideClickAt = 0
            return
        }

        let now = event.timestamp
        if lastOutsideClickAt > 0, now - lastOutsideClickAt <= NSEvent.doubleClickInterval {
            lastOutsideClickAt = 0
            // Outside-click is the "accidental" dismiss path — falls
            // through to Esc semantics only if no outside-click handler
            // is wired (defensive). Esc proper goes through `onDismissKey`
            // directly from the key router.
            if let onOutsideClickDismiss {
                onOutsideClickDismiss()
            } else {
                onDismissKey?()
            }
            return
        }
        lastOutsideClickAt = now
    }

    @objc private func customInputCardClicked(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        onChoiceKey?(3)
    }

    private func handleLocalKeyDown(_ event: NSEvent) -> Bool {
        let customInputActive = customInputField?.isEditing == true
        if customInputActive, isTabKey(event) {
            toggleCustomInputMode()
            return true
        }
        guard let command = OverlayKeyRouter.command(for: event, customInputActive: customInputActive) else {
            return false
        }

        switch command {
        case .choice(let index):
            onChoiceKey?(index)
            return true
        case .dismiss:
            onDismissKey?()
            return true
        case .insert:
            return onInsertKey?() ?? false
        case .insertCustomInput:
            return onCustomInsertKey?() ?? true
        case .leaveCustomInput:
            onLeaveCustomInputKey?()
            return true
        case .reroll:
            onRerollKey?()
            return true
        case .moveSelectionUp:
            onArrowKey?(.up)
            return true
        case .moveSelectionDown:
            onArrowKey?(.down)
            return true
        case .togglePin:
            onTogglePinKey?()
            return true
        case .textEditing(let shortcut):
            return onTextEditingKey?(shortcut) ?? false
        }
    }

    private func isTabKey(_ event: NSEvent) -> Bool {
        guard event.keyCode == 48 else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags.isEmpty || flags == .shift
    }

    private func toggleCustomInputMode() {
        setCustomInputMode(customInputMode == .followUp ? .write : .followUp, focusField: false)
    }

    private func label(
        frame: NSRect,
        text: String,
        font: NSFont,
        color: NSColor,
        lineSpacing: CGFloat = 0,
        singleLine: Bool = false,
        boldPrefix: String? = nil
    ) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.frame = frame
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        setLabelText(
            label,
            text: text,
            font: font,
            color: color,
            lineSpacing: lineSpacing,
            singleLine: singleLine,
            boldPrefix: boldPrefix
        )
        return label
    }

    private func setLabelText(
        _ label: NSTextField,
        text: String,
        font: NSFont,
        color: NSColor,
        lineSpacing: CGFloat,
        singleLine: Bool,
        boldPrefix: String? = nil
    ) {
        label.font = font
        label.textColor = color
        label.lineBreakMode = singleLine ? .byTruncatingTail : .byWordWrapping
        label.usesSingleLineMode = singleLine
        if boldPrefix != nil {
            label.attributedStringValue = makeBodyAttributedString(
                text: text,
                font: font,
                color: color,
                lineSpacing: lineSpacing,
                singleLine: singleLine,
                boldPrefix: boldPrefix
            )
            return
        }
        guard lineSpacing > 0 else {
            label.stringValue = text
            return
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = singleLine ? .byTruncatingTail : .byWordWrapping
        paragraph.lineSpacing = lineSpacing
        label.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        )
    }

    private func measureHeight(
        _ text: String,
        width: CGFloat,
        font: NSFont,
        lineSpacing: CGFloat = 0,
        boldPrefix: String? = nil
    ) -> CGFloat {
        let attributed: NSAttributedString
        if boldPrefix != nil {
            attributed = makeBodyAttributedString(
                text: text,
                font: font,
                color: .labelColor,
                lineSpacing: lineSpacing,
                singleLine: false,
                boldPrefix: boldPrefix
            )
        } else {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.lineSpacing = lineSpacing
            attributed = NSAttributedString(
                string: text,
                attributes: [
                    .font: font,
                    .paragraphStyle: paragraph,
                ]
            )
        }
        let cell = NSTextFieldCell()
        cell.isBezeled = false
        cell.isEditable = false
        cell.isSelectable = false
        cell.drawsBackground = false
        cell.wraps = true
        cell.usesSingleLineMode = false
        cell.lineBreakMode = .byWordWrapping
        cell.attributedStringValue = attributed
        let size = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 1_000_000))
        return ceil(size.height)
    }

    private func makeBodyAttributedString(
        text: String,
        font: NSFont,
        color: NSColor,
        lineSpacing: CGFloat,
        singleLine: Bool,
        boldPrefix: String?
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if let boldPrefix {
            let headerFont = NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)
            let headerPara = NSMutableParagraphStyle()
            headerPara.lineBreakMode = .byWordWrapping
            headerPara.lineSpacing = lineSpacing
            headerPara.paragraphSpacing = Layout.summaryHeaderBottomGap
            result.append(NSAttributedString(
                string: boldPrefix + "\n",
                attributes: [
                    .font: headerFont,
                    .foregroundColor: color,
                    .paragraphStyle: headerPara,
                ]
            ))
        }
        let bodyPara = NSMutableParagraphStyle()
        bodyPara.lineBreakMode = singleLine ? .byTruncatingTail : .byWordWrapping
        bodyPara.lineSpacing = lineSpacing
        result.append(NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: bodyPara,
            ]
        ))
        return result
    }

    private func collapsedSingleLineText(_ text: String, width: CGFloat, font: NSFont) -> String {
        let fullWidth = measureWidth(text, font: font)
        guard fullWidth > width else { return text }
        let suffix = "..."
        let suffixWidth = measureWidth(suffix, font: font)
        let available = max(0, width - suffixWidth)
        var low = 0
        var high = text.count
        var best = ""
        while low <= high {
            let mid = (low + high) / 2
            let candidate = String(text.prefix(mid)).trimmingCharacters(in: .whitespacesAndNewlines)
            if measureWidth(candidate, font: font) <= available {
                best = candidate
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best.isEmpty ? suffix : best + suffix
    }

    private func measureWidth(_ text: String, font: NSFont) -> CGFloat {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        return ceil(attributed.size().width)
    }

    /// Width measurement that matches NSTextField's actual single-line
    /// rendering. `attributedString.size()` rounds short of the on-screen
    /// glyph run by a few subpixel units, which makes a single-line label
    /// frame sized to that value truncate the trailing characters
    /// ("Reading this scree…" instead of "Reading this screen…").
    private func measureLoadingTextWidth(_ text: String, font: NSFont) -> CGFloat {
        let cell = NSTextFieldCell()
        cell.isBezeled = false
        cell.isEditable = false
        cell.isSelectable = false
        cell.drawsBackground = false
        cell.usesSingleLineMode = true
        cell.lineBreakMode = .byClipping
        cell.attributedStringValue = NSAttributedString(
            string: text, attributes: [.font: font]
        )
        let size = cell.cellSize(forBounds: NSRect(
            x: 0, y: 0, width: 100_000, height: 100_000
        ))
        return ceil(size.width)
    }
}

private enum CopyConfirmationPill {
    static func show(on screen: NSScreen) {
        let pillWidth: CGFloat = 280
        let pillHeight: CGFloat = 44

        let x = screen.frame.midX - pillWidth / 2
        // Start fully off-screen above the top edge; land just below the menubar.
        let startFrame = NSRect(x: x, y: screen.frame.maxY, width: pillWidth, height: pillHeight)
        let landFrame = NSRect(
            x: x,
            y: screen.visibleFrame.maxY - 12 - pillHeight,
            width: pillWidth,
            height: pillHeight
        )

        let panel = NSPanel(
            contentRect: startFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0

        let container = NSView(frame: NSRect(origin: .zero, size: startFrame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = container

        let pill = NSView(frame: NSRect(origin: .zero, size: startFrame.size))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.92).cgColor
        pill.layer?.cornerRadius = pillHeight / 2
        pill.layer?.shadowColor = NSColor.black.cgColor
        pill.layer?.shadowOpacity = 0.25
        pill.layer?.shadowRadius = 8
        pill.layer?.shadowOffset = CGSize(width: 0, height: -3)
        container.addSubview(pill)

        let iconSize: CGFloat = 20
        let iconY = (pillHeight - iconSize) / 2
        let icon = NSImageView(frame: NSRect(x: 18, y: iconY, width: iconSize, height: iconSize))
        icon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        icon.contentTintColor = .white
        pill.addSubview(icon)

        let labelX: CGFloat = 18 + iconSize + 10
        let labelH: CGFloat = 20
        let labelField = NSTextField(labelWithString: "Copied")
        labelField.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        labelField.textColor = .white
        labelField.frame = NSRect(x: labelX, y: (pillHeight - labelH) / 2, width: pillWidth - labelX - 18, height: labelH)
        labelField.isEditable = false
        labelField.isSelectable = false
        labelField.isBordered = false
        labelField.drawsBackground = false
        pill.addSubview(labelField)

        panel.orderFrontRegardless()

        // Spring drop-in: overshoot cubic bezier gives a subtle bounce on landing.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0)
            panel.animator().setFrame(landFrame, display: true)
            panel.animator().alphaValue = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28 + 1.4) {
            let exitFrame = NSRect(x: x, y: screen.frame.maxY, width: pillWidth, height: pillHeight)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().setFrame(exitFrame, display: true)
                panel.animator().alphaValue = 0
            } completionHandler: {
                panel.close()
            }
        }
    }
}

private final class ClickDismissPillPanel: NSPanel {
    var onClick: (() -> Void)?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

private enum PasteFallbackPill {
    static func show(on screen: NSScreen) {
        let pillWidth: CGFloat = 360
        let pillHeight: CGFloat = 48

        let x = screen.frame.midX - pillWidth / 2
        let startFrame = NSRect(x: x, y: screen.frame.maxY, width: pillWidth, height: pillHeight)
        let landFrame = NSRect(
            x: x,
            y: screen.visibleFrame.maxY - 12 - pillHeight,
            width: pillWidth,
            height: pillHeight
        )

        let panel = ClickDismissPillPanel(
            contentRect: startFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0

        let container = NSView(frame: NSRect(origin: .zero, size: startFrame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = container

        let pill = NSView(frame: NSRect(origin: .zero, size: startFrame.size))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.94).cgColor
        pill.layer?.cornerRadius = pillHeight / 2
        pill.layer?.shadowColor = NSColor.black.cgColor
        pill.layer?.shadowOpacity = 0.25
        pill.layer?.shadowRadius = 8
        pill.layer?.shadowOffset = CGSize(width: 0, height: -3)
        container.addSubview(pill)

        let iconSize: CGFloat = 20
        let iconY = (pillHeight - iconSize) / 2
        let icon = NSImageView(frame: NSRect(x: 18, y: iconY, width: iconSize, height: iconSize))
        icon.image = NSImage(systemSymbolName: "clipboard.fill", accessibilityDescription: nil)
        icon.contentTintColor = .white
        pill.addSubview(icon)

        let labelX: CGFloat = 18 + iconSize + 10
        let labelH: CGFloat = 22
        let labelField = NSTextField(labelWithString: "Still on your clipboard — ⌘V to paste")
        labelField.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        labelField.textColor = .white
        labelField.frame = NSRect(
            x: labelX,
            y: (pillHeight - labelH) / 2,
            width: pillWidth - labelX - 18,
            height: labelH
        )
        labelField.lineBreakMode = .byTruncatingTail
        labelField.maximumNumberOfLines = 1
        labelField.isEditable = false
        labelField.isSelectable = false
        labelField.isBordered = false
        labelField.drawsBackground = false
        pill.addSubview(labelField)

        var didClose = false
        let close: () -> Void = {
            guard !didClose else { return }
            didClose = true
            let exitFrame = NSRect(x: x, y: screen.frame.maxY, width: pillWidth, height: pillHeight)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().setFrame(exitFrame, display: true)
                panel.animator().alphaValue = 0
            } completionHandler: {
                panel.close()
            }
        }
        panel.onClick = close

        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0)
            panel.animator().setFrame(landFrame, display: true)
            panel.animator().alphaValue = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28 + 3.5) {
            close()
        }
    }
}

/// Drop-from-menubar pill prompting the user to hit Return to submit the
/// multi-frame capture. Visually matches `PasteFallbackPill` (same anchor,
/// same spring animation) but persists indefinitely — the caller must invoke
/// the returned close handle on submit / cancel / re-arm. Clicking the pill
/// dismisses it without affecting the session.
private enum SubmitPromptPill {
    static func show(on screen: NSScreen) -> () -> Void {
        let pillWidth: CGFloat = 320
        let pillHeight: CGFloat = 48

        let x = screen.frame.midX - pillWidth / 2
        let startFrame = NSRect(x: x, y: screen.frame.maxY, width: pillWidth, height: pillHeight)
        let landFrame = NSRect(
            x: x,
            y: screen.visibleFrame.maxY - 12 - pillHeight,
            width: pillWidth,
            height: pillHeight
        )

        let panel = ClickDismissPillPanel(
            contentRect: startFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0

        let container = NSView(frame: NSRect(origin: .zero, size: startFrame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = container

        let pill = NSView(frame: NSRect(origin: .zero, size: startFrame.size))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.94).cgColor
        pill.layer?.cornerRadius = pillHeight / 2
        pill.layer?.shadowColor = NSColor.black.cgColor
        pill.layer?.shadowOpacity = 0.25
        pill.layer?.shadowRadius = 8
        pill.layer?.shadowOffset = CGSize(width: 0, height: -3)
        container.addSubview(pill)

        let iconSize: CGFloat = 20
        let iconY = (pillHeight - iconSize) / 2
        let icon = NSImageView(frame: NSRect(x: 18, y: iconY, width: iconSize, height: iconSize))
        icon.image = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: nil)
        icon.contentTintColor = .white
        pill.addSubview(icon)

        let labelX: CGFloat = 18 + iconSize + 10
        let labelH: CGFloat = 22
        let labelField = NSTextField(labelWithString: "Hit ↩ to send to Blink")
        labelField.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        labelField.textColor = .white
        labelField.frame = NSRect(
            x: labelX,
            y: (pillHeight - labelH) / 2,
            width: pillWidth - labelX - 18,
            height: labelH
        )
        labelField.lineBreakMode = .byTruncatingTail
        labelField.maximumNumberOfLines = 1
        labelField.isEditable = false
        labelField.isSelectable = false
        labelField.isBordered = false
        labelField.drawsBackground = false
        pill.addSubview(labelField)

        var didClose = false
        let close: () -> Void = { [weak panel] in
            guard !didClose else { return }
            didClose = true
            guard let panel else { return }
            let exitFrame = NSRect(x: x, y: screen.frame.maxY, width: pillWidth, height: pillHeight)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().setFrame(exitFrame, display: true)
                panel.animator().alphaValue = 0
            } completionHandler: {
                panel.close()
            }
        }
        panel.onClick = close

        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0)
            panel.animator().setFrame(landFrame, display: true)
            panel.animator().alphaValue = 1
        }

        return close
    }
}

enum ConfettiPanel {
    private static let panelSize = NSSize(width: 360, height: 240)
    private static let palette: [NSColor] = [
        .systemPink, .systemYellow, .systemTeal, .systemPurple, .systemGreen,
    ]

    /// Fire a confetti burst centered on a screen-coordinate caret point.
    /// The burst lives on its own floating panel so the suggestions overlay
    /// can tear down in parallel without taking the celebration with it.
    static func fire(at caret: CGPoint) {
        let frame = NSRect(
            x: caret.x - panelSize.width / 2,
            y: caret.y - panelSize.height / 2,
            width: panelSize.width,
            height: panelSize.height
        )
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false

        let container = NSView(frame: NSRect(origin: .zero, size: panelSize))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = container

        let emitter = CAEmitterLayer()
        emitter.frame = container.bounds
        // Emit from the panel's local center — the panel itself is centered
        // on the caret in screen coords, so the burst origin is the caret.
        emitter.emitterPosition = CGPoint(x: panelSize.width / 2, y: panelSize.height / 2)
        emitter.emitterShape = .point
        emitter.emitterMode = .points
        emitter.renderMode = .unordered
        emitter.zPosition = 1000
        emitter.emitterCells = palette.compactMap { color in
            guard let image = confettiImage(color: color) else { return nil }
            let cell = CAEmitterCell()
            cell.contents = image
            // ~4 pieces per color × 5 colors ≈ 20 pieces total.
            cell.birthRate = 4
            cell.lifetime = 0.7
            cell.lifetimeRange = 0.25
            cell.velocity = 260
            cell.velocityRange = 70
            cell.emissionLongitude = .pi / 2
            // Tightened upward cone (~50° spread) since the origin is precise.
            cell.emissionRange = .pi / 3.5
            cell.spin = 4
            cell.spinRange = 6
            cell.scale = 0.6
            cell.scaleRange = 0.35
            cell.yAcceleration = -340
            cell.alphaSpeed = -0.9
            return cell
        }
        container.layer?.addSublayer(emitter)
        panel.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            emitter.birthRate = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            panel.close()
        }
    }

    private static func confettiImage(color: NSColor) -> CGImage? {
        let size = NSSize(width: 8, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
            return true
        }
        var rect = NSRect(origin: .zero, size: size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
