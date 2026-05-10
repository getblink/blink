import AppKit

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

final class CustomReplyField: NSTextField {
    var onFocusChanged: ((Bool) -> Void)?
    var onLocalKeyDown: ((NSEvent) -> Bool)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            onFocusChanged?(true)
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onFocusChanged?(false)
        }
        return resigned
    }

    override func keyDown(with event: NSEvent) {
        if onLocalKeyDown?(event) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if performTextFieldKeyEquivalent(with: event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func performTextFieldKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              flags.intersection([.control, .option]).isEmpty,
              let characters = event.charactersIgnoringModifiers?.lowercased(),
              ["a", "c", "v", "x"].contains(characters),
              let editor = currentEditor()
        else {
            return false
        }
        return editor.performKeyEquivalent(with: event)
    }

    func performTextEditingShortcut(_ shortcut: TextEditingShortcut) -> Bool {
        guard let editor = currentEditor() else { return false }
        switch shortcut {
        case .selectAll:
            editor.selectAll(nil)
        case .copy:
            editor.copy(nil)
        case .paste:
            editor.paste(nil)
        case .cut:
            editor.cut(nil)
        }
        return true
    }

    var isEditing: Bool {
        currentEditor() != nil || window?.firstResponder === self
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
        static let customInputHeight: CGFloat = 62
        static let customInputTextHeight: CGFloat = 24
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
        static let enterHintWidth: CGFloat = 140
        static let enterHintHeight: CGFloat = 18
        static let enterHintRightInset: CGFloat = 24
        static let enterHintBottomInset: CGFloat = 4
        static let animationDuration: TimeInterval = 0.22
        static let momentDuration: TimeInterval = 0.34
        static let tagAlpha: CGFloat = 0.95

        static var suggestionPaddingY: CGFloat {
            (suggestionCollapsedHeight - suggestionCollapsedTextHeight) / 2
        }

        static func optionCornerRadius(for height: CGFloat) -> CGFloat {
            min(suggestionCornerRadius, height / 2)
        }
    }

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
        let collapsedFrame: NSRect
        let collapsedText: String
        let fullText: String
        let expandedHeight: CGFloat
        let hasTags: Bool
        let collapsedLabelHeight: CGFloat
        let collapsedSingleLine: Bool
    }

    private var panel: SuggestionsPanel?
    private var contentView: NSView?
    private var basePanelHeight: CGFloat = 0
    private var basePanelTopY: CGFloat = 0
    private var summaryCard: NSView?
    private var summaryLabel: NSTextField?
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
    private var customInputHintLabel: NSTextField?
    private var customInputTint: NSView?
    private var bottomHintLabel: NSTextField?
    private var bottomHintBaseFrame: NSRect = .zero
    private var showsTldrHeader: Bool = false
    private var suggestionClickTargets: [SuggestionCardClickTarget] = []
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var lastOutsideClickAt: TimeInterval = 0
    private var currentHeightDelta: CGFloat = 0
    private var previousFrontmost: NSRunningApplication?
    private var hasPlayedSuggestionArrival = false
    private var isDismissing = false
    private(set) var expandedSuggestionIndex: Int?

    var onCustomInputFocusChanged: ((Bool) -> Void)?
    var onCustomInsert: ((String) -> Void)?
    var onChoiceKey: ((Int) -> Void)?
    var onInsertKey: (() -> Bool)?
    var onCustomInsertKey: (() -> Bool)?
    var onLeaveCustomInputKey: (() -> Void)?
    var onTextEditingKey: ((TextEditingShortcut) -> Bool)?
    var onRerollKey: (() -> Void)?
    var onDismissKey: (() -> Void)?

    var isVisible: Bool {
        panel?.isVisible == true
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

    func show(tldr: String, suggestions: [String]) {
        show(tldr: tldr, suggestionDetails: suggestions.map(SuggestionDetail.plain))
    }

    func show(tldr: String, suggestionDetails: [SuggestionDetail]) {
        show(
            tldr: tldr,
            suggestionDetails: suggestionDetails,
            showsCustomInput: true,
            hintText: nil,
            bottomHintText: "Press 1 / 2 / 3 to expand \u{00B7} R to reroll \u{00B7} Esc to dismiss",
            showsTldrHeader: true
        )
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
        let summaryHeight = isLoading
            ? Layout.loadingMinHeight
            : max(
                Layout.summaryMinHeight,
                measureHeight(tldr, width: summaryLabelWidth, font: summaryFont, lineSpacing: Layout.summaryLineSpacing, boldPrefix: bodyBoldPrefix)
                    + summaryTextY
                    + Layout.summaryTopInset
            )
        let suggestionLabelWidth = contentWidth - Layout.suggestionTextX - Layout.cardPaddingX
        let collapsedHeights = visibleSuggestions.map {
            collapsedHeight(for: $0, width: suggestionLabelWidth, font: suggestionFont)
        }
        let expandedHeights = visibleSuggestions.enumerated().map { offset, detail in
            max(
                collapsedHeights[offset],
                measureHeight(detail.text, width: suggestionLabelWidth, font: suggestionFont, lineSpacing: Layout.suggestionLineSpacing)
                    + Layout.suggestionPaddingY
                    + Layout.suggestionBottomPaddingExpanded
            )
        }
        let suggestionStackHeight = collapsedHeights.reduce(0, +)
            + CGFloat(max(0, visibleSuggestions.count - 1)) * Layout.suggestionGap
        let customStackHeight = showsCustomInput
            ? (visibleSuggestions.isEmpty ? Layout.customInputHeight : Layout.suggestionGap + Layout.customInputHeight)
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
            let hint = label(
                frame: NSRect(
                    x: 24,
                    y: Layout.summaryBottomInset,
                    width: contentWidth - 48,
                    height: Layout.summaryHintHeight
                ),
                text: hintText,
                font: hintFont,
                color: .tertiaryLabelColor,
                singleLine: true
            )
            hint.alignment = .center
            summary.content.addSubview(hint)
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
                collapsedText: detail.text,
                fullText: detail.text,
                expandedHeight: expandedHeights[offset],
                hasTags: !renderTags(detail.tags).isEmpty,
                collapsedLabelHeight: collapsedTextHeight(for: detail, width: suggestionLabelWidth, font: suggestionFont),
                collapsedSingleLine: collapsedTextIsSingleLine(for: detail, width: suggestionLabelWidth, font: suggestionFont)
            ))
            if offset < visibleSuggestions.count - 1 {
                y -= Layout.suggestionGap
            }
        }

        let custom: (outer: NSView, content: NSView, field: CustomReplyField, enterHint: NSTextField, tint: NSView)?
        let customFrame: NSRect
        if showsCustomInput {
            if !visibleSuggestions.isEmpty {
                y -= Layout.suggestionGap
            }
            y -= Layout.customInputHeight
            customFrame = NSRect(
                x: contentX,
                y: y,
                width: contentWidth,
                height: Layout.customInputHeight
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
        self.summaryLabel = summaryLabel
        self.summaryBaseFrame = summaryFrame
        self.summaryTextY = summaryTextY
        self.suggestionCards = cards
        self.customInputCard = custom?.outer
        self.customInputBaseFrame = customFrame
        self.customInputField = custom?.field
        self.customInputHintLabel = custom?.enterHint
        self.customInputTint = custom?.tint
        self.bottomHintLabel = bottomHint
        self.bottomHintBaseFrame = bottomHintFrame
        self.showsTldrHeader = showsTldrHeader
        panel.customReplyField = custom?.field
        self.currentHeightDelta = 0
        self.expandedSuggestionIndex = nil
        self.hasPlayedSuggestionArrival = false
        self.isLoadingState = isLoading

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

        let views = suggestionCards.map(\.outer)
            + [customInputCard, bottomHintLabel].compactMap { $0 }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Layout.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for (index, view) in views.enumerated() {
                view.animator().alphaValue = 0
                view.animator().frame = view.frame.offsetBy(dx: 0, dy: -6 - CGFloat(index) * 1.5)
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
        let shouldAnimateRefresh = isSuggestionRefreshing
        isSuggestionRefreshing = false
        let visibleSuggestions = Array(suggestions.prefix(3))

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
        bottomHintLabel?.removeFromSuperview()
        bottomHintLabel = nil
        panel.customReplyField = nil
        expandedSuggestionIndex = nil

        let suggestionFont = NSFont.systemFont(ofSize: Layout.suggestionFontSize)
        let hintFont = NSFont.systemFont(ofSize: Layout.hintFontSize)
        let bottomHintText = showsTldrHeader
            ? "Press 1 / 2 / 3 to expand \u{00B7} R to reroll \u{00B7} Esc to dismiss"
            : nil
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
                    + Layout.suggestionBottomPaddingExpanded
            )
        }
        let suggestionStackHeight = collapsedHeights.reduce(0, +)
            + CGFloat(max(0, visibleSuggestions.count - 1)) * Layout.suggestionGap
        let customStackHeight = visibleSuggestions.isEmpty
            ? Layout.customInputHeight
            : Layout.suggestionGap + Layout.customInputHeight
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
                collapsedText: detail.text,
                fullText: detail.text,
                expandedHeight: expandedHeights[offset],
                hasTags: !renderTags(detail.tags).isEmpty,
                collapsedLabelHeight: collapsedTextHeight(for: detail, width: suggestionLabelWidth, font: suggestionFont),
                collapsedSingleLine: collapsedTextIsSingleLine(for: detail, width: suggestionLabelWidth, font: suggestionFont)
            ))
            if offset < visibleSuggestions.count - 1 {
                y -= Layout.suggestionGap
            }
        }

        if !visibleSuggestions.isEmpty {
            y -= Layout.suggestionGap
        }
        y -= Layout.customInputHeight
        let customFrame = NSRect(
            x: contentX,
            y: y,
            width: contentWidth,
            height: Layout.customInputHeight
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
        self.customInputHintLabel = customCard.enterHint
        self.customInputTint = customCard.tint
        self.bottomHintLabel = bottomHint
        self.bottomHintBaseFrame = bottomHintFrame
        panel.customReplyField = customCard.field
        self.basePanelHeight = newPanelHeight
        self.basePanelTopY = panel.frame.maxY
        self.currentHeightDelta = 0
        if shouldAnimateRefresh, !cards.isEmpty {
            playArrivalAnimation(summary: nil, cards: cards.map(\.outer) + [customCard.outer])
        } else if !hasPlayedSuggestionArrival, !cards.isEmpty {
            hasPlayedSuggestionArrival = true
            playArrivalAnimation(summary: summaryCard, cards: cards.map(\.outer))
        }
    }

    func focusCustomInput() {
        guard let panel, let field = customInputField else { return }
        collapseSuggestions()
        field.onFocusChanged?(true)
        panel.makeFirstResponder(field)
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

    @MainActor
    func customInputCaretScreenPoint() -> CGPoint? {
        guard panel != nil, let field = customInputField, field.isEditing else { return nil }
        if let textView = field.currentEditor() as? NSTextView {
            let caretRect = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
            return CGPoint(x: caretRect.midX, y: caretRect.midY)
        }
        // Last-ditch fallback: center of the field in screen coordinates.
        guard let fieldWindow = field.window else { return nil }
        let fieldRectInScreen = fieldWindow.convertToScreen(field.convert(field.bounds, to: nil))
        return CGPoint(x: fieldRectInScreen.midX, y: fieldRectInScreen.midY)
    }

    @discardableResult
    func expandSuggestion(index: Int) -> Bool {
        guard let panel, let contentView, index >= 0, index < suggestionCards.count else {
            return false
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
        let newPanelHeight = basePanelHeight + heightDelta
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
                    labelY = Layout.suggestionBottomPaddingExpanded
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

        let newFrame = NSRect(
            x: panel.frame.origin.x,
            y: basePanelTopY - basePanelHeight,
            width: panel.frame.width,
            height: basePanelHeight
        )
        contentView.frame = NSRect(x: 0, y: 0, width: newFrame.width, height: basePanelHeight)
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
        tearDownLoadingState()
        softErrorPanel?.close()
        softErrorPanel = nil
        removeMouseMonitors()
        customInputHintLabel?.alphaValue = 0
        panel?.close()
        panel = nil
        contentView = nil
        summaryCard = nil
        summaryLabel = nil
        summaryTextY = 0
        suggestionCards = []
        suggestionClickTargets = []
        customInputField?.onFocusChanged?(false)
        customInputCard = nil
        customInputBaseFrame = .zero
        customInputField = nil
        customInputHintLabel = nil
        customInputTint = nil
        bottomHintLabel = nil
        bottomHintBaseFrame = .zero
        showsTldrHeader = false
        expandedSuggestionIndex = nil
        currentHeightDelta = 0
        hasPlayedSuggestionArrival = false
        isDismissing = false

        if let prev = previousFrontmost,
           !prev.isTerminated,
           prev.processIdentifier != NSRunningApplication.current.processIdentifier {
            prev.activate()
        }
        previousFrontmost = nil
    }

    func dismissAnimated(completion: (() -> Void)? = nil) {
        guard let panel, let contentView, !isDismissing else {
            completion?()
            return
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

    func confirmInsert(completion: @escaping () -> Void) {
        completion()
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

    private func playArrivalAnimation(summary: NSView?, cards: [NSView]) {
        animateScale(view: summary, from: 0.96, to: 1.0, duration: Layout.momentDuration)
        for (index, card) in cards.enumerated() {
            card.alphaValue = 0
            let finalFrame = card.frame
            card.frame = finalFrame.offsetBy(dx: 0, dy: -12)
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
        enterHint: NSTextField
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
        let textBlockY = hasTags
            ? (frame.height - collapsedLabelHeight - Layout.suggestionTagHeight - Layout.suggestionTagGap) / 2
            : (frame.height - collapsedLabelHeight) / 2
        let suggestionLabel = label(
            frame: NSRect(
                x: Layout.suggestionTextX,
                y: hasTags ? textBlockY + Layout.suggestionTagHeight + Layout.suggestionTagGap : textBlockY,
                width: textWidth,
                height: collapsedLabelHeight
            ),
            text: detail.text,
            font: font,
            color: .labelColor,
            lineSpacing: collapsedSingleLine ? 0 : 2,
            singleLine: collapsedSingleLine
        )
        suggestionLabel.maximumNumberOfLines = collapsedSingleLine ? 1 : 2
        suggestionLabel.lineBreakMode = .byTruncatingTail
        suggestionLabel.cell?.wraps = !collapsedSingleLine
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

        return (pane.outer, pane.content, tint, number, suggestionLabel, tagIcon, tagLabel, enterHint)
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

    private func makeTagAttributedString(tags: [String], font: NSFont) -> NSAttributedString {
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
        return attributed
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
        enterHint: NSTextField,
        tint: NSView
    ) {
        let pane = makeGlassPane(frame: frame, cornerRadius: frame.height / 2)

        // Make the entire card focus the field on click — without this only
        // the narrow text-field hit area focuses #4. Routes through
        // `onChoiceKey?(3)` so the choice-state machine fires the same path
        // as a `4` key press (collapse expanded card, focus field, status).
        let click = NSClickGestureRecognizer(target: self, action: #selector(customInputCardClicked(_:)))
        click.numberOfClicksRequired = 1
        click.buttonMask = 0x1
        click.delaysPrimaryMouseButtonEvents = false
        pane.outer.addGestureRecognizer(click)

        // Match the suggestion-card "selected" affordance: a translucent
        // blue pill that fades in when the field is focused.
        let tint = NSView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height))
        tint.wantsLayer = true
        tint.layer?.cornerRadius = frame.height / 2
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

        let textHeight = Layout.customInputTextHeight
        let field = CustomReplyField(frame: NSRect(
            x: Layout.suggestionTextX,
            y: (frame.height - textHeight) / 2,
            width: frame.width - Layout.suggestionTextX - Layout.cardPaddingX,
            height: textHeight
        ))
        // Default `placeholderTextColor` is too dim against the dark popover
        // frost — bump to `secondaryLabelColor` so the prompt stays visible.
        field.placeholderAttributedString = NSAttributedString(
            string: "Type your own reply...",
            attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: font,
            ]
        )
        field.font = font
        field.textColor = .labelColor
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.target = self
        field.action = #selector(customInputReturnPressed(_:))
        field.onFocusChanged = { [weak self] active in
            // Collapse any expanded suggestion when #4 takes focus — covers
            // the path where the user clicks the field directly (which
            // bypasses `focusCustomInput()` and would otherwise leave the
            // previously expanded card 1/2/3 expanded and tinted).
            if active {
                self?.collapseSuggestions()
            }
            self?.setCustomInputHintVisible(active)
            self?.onCustomInputFocusChanged?(active)
        }
        field.onLocalKeyDown = { [weak self] event in
            self?.handleLocalKeyDown(event) ?? false
        }
        pane.content.addSubview(field)

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

        return (pane.outer, pane.content, field, enterHint, tint)
    }

    private func setCustomInputHintVisible(_ visible: Bool) {
        applyCustomInputFocusState(focused: visible, animated: true)
    }

    private func applyCustomInputFocusState(focused: Bool, animated: Bool) {
        guard let hint = customInputHintLabel,
              let field = customInputField,
              let tint = customInputTint else { return }
        // Field stays full-width regardless of focus state. The hint sits at
        // the bottom edge (y ∈ [4, 22]) while the field text sits near
        // vertical center (~y ∈ [22, 40]) within the 62pt card, so they
        // occupy different vertical bands — text can extend horizontally
        // past the hint glyph without visually colliding.
        let cardWidth = customInputBaseFrame.width
        let fullFieldWidth = cardWidth - Layout.suggestionTextX - Layout.cardPaddingX
        var fieldFrame = field.frame
        fieldFrame.size.width = fullFieldWidth
        let targetAlpha: CGFloat = focused ? 1 : 0
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Layout.animationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                hint.animator().alphaValue = targetAlpha
                tint.animator().alphaValue = targetAlpha
                field.animator().frame = fieldFrame
            }
        } else {
            // Cancel any in-flight animation from the AppKit auto-promote
            // dance and snap to the explicit target.
            hint.layer?.removeAllAnimations()
            tint.layer?.removeAllAnimations()
            field.layer?.removeAllAnimations()
            hint.alphaValue = targetAlpha
            tint.alphaValue = targetAlpha
            field.frame = fieldFrame
        }
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
            onDismissKey?()
            return
        }
        lastOutsideClickAt = now
    }

    @objc private func customInputCardClicked(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        onChoiceKey?(3)
    }

    @objc private func customInputReturnPressed(_ sender: CustomReplyField) {
        let text = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onCustomInsert?(text)
    }

    private func handleLocalKeyDown(_ event: NSEvent) -> Bool {
        let customInputActive = customInputField?.isEditing == true
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
        case .textEditing(let shortcut):
            return onTextEditingKey?(shortcut) ?? false
        }
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
