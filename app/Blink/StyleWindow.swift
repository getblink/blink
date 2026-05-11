import AppKit
import Combine

/// Lets the user nudge Blink's general writing style — initiative, tone,
/// length, directness, voice mirroring — and add a freeform "About me"
/// note. Persisted via RuntimeConfigStore; surfaced to Python through the
/// runtime config and (on the proxy path) the request envelope.
@MainActor
final class StyleWindowController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    private let runtimeStore: RuntimeConfigStore

    private var window: NSWindow?
    private var initiativeControl: NSSegmentedControl?
    private var toneControl: NSSegmentedControl?
    private var lengthControl: NSSegmentedControl?
    private var directnessControl: NSSegmentedControl?
    private var voiceMirrorControl: NSSegmentedControl?
    private var aboutMeView: NSTextView?
    private var aboutMeCounter: NSTextField?

    private var styleSubscription: AnyCancellable?

    private struct KnobSpec {
        let label: String
        let leftTitle: String
        let leftValue: String
        let rightTitle: String
        let rightValue: String
        let hint: String
    }

    private static let knobs: [KnobSpec] = [
        KnobSpec(
            label: "Initiative",
            leftTitle: "Incremental",
            leftValue: "incremental",
            rightTitle: "Agentic",
            rightValue: "agentic",
            hint: "Small nudges vs full drafts."
        ),
        KnobSpec(
            label: "Tone",
            leftTitle: "Casual",
            leftValue: "casual",
            rightTitle: "Formal",
            rightValue: "formal",
            hint: "Contractions vs polished register."
        ),
        KnobSpec(
            label: "Length",
            leftTitle: "Terse",
            leftValue: "terse",
            rightTitle: "Thorough",
            rightValue: "thorough",
            hint: "One-liners vs a few sentences."
        ),
        KnobSpec(
            label: "Directness",
            leftTitle: "Diplomatic",
            leftValue: "diplomatic",
            rightTitle: "Direct",
            rightValue: "direct",
            hint: "Hedge vs name the real issue."
        ),
        KnobSpec(
            label: "Voice mirror",
            leftTitle: "Neutral",
            leftValue: "neutral",
            rightTitle: "Mirror me",
            rightValue: "mirror",
            hint: "Clean register vs imitate my voice samples."
        ),
    ]

    init(runtimeStore: RuntimeConfigStore) {
        self.runtimeStore = runtimeStore
    }

    func show() {
        if window == nil { buildWindow() }
        applyCurrentStyle()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startSubscription()
    }

    private func buildWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 540),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Blink Style"
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let intro = NSTextField(wrappingLabelWithString:
            "Tweak how Blink writes for you. Defaults are balanced; "
            + "changes apply to the next summary."
        )
        intro.font = NSFont.systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor
        intro.maximumNumberOfLines = 0
        intro.preferredMaxLayoutWidth = 460 - 48
        stack.addArrangedSubview(intro)

        // Knob rows.
        for (index, spec) in Self.knobs.enumerated() {
            let segmented = NSSegmentedControl(
                labels: [spec.leftTitle, "Balanced", spec.rightTitle],
                trackingMode: .selectOne,
                target: self,
                action: #selector(knobChanged(_:))
            )
            segmented.tag = index
            segmented.segmentDistribution = .fillEqually
            segmented.setContentHuggingPriority(.defaultLow, for: .horizontal)
            switch spec.leftValue {
            case "incremental": initiativeControl = segmented
            case "casual": toneControl = segmented
            case "terse": lengthControl = segmented
            case "diplomatic": directnessControl = segmented
            case "neutral": voiceMirrorControl = segmented
            default: break
            }

            let label = NSTextField(labelWithString: spec.label)
            label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            label.textColor = .secondaryLabelColor

            let hint = NSTextField(labelWithString: spec.hint)
            hint.font = NSFont.systemFont(ofSize: 11)
            hint.textColor = .tertiaryLabelColor

            let labelStack = NSStackView(views: [label, hint])
            labelStack.orientation = .horizontal
            labelStack.spacing = 8
            labelStack.alignment = .firstBaseline

            let rowStack = NSStackView(views: [labelStack, segmented])
            rowStack.orientation = .vertical
            rowStack.alignment = .leading
            rowStack.spacing = 4
            rowStack.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(rowStack)
            NSLayoutConstraint.activate([
                segmented.widthAnchor.constraint(equalToConstant: 460 - 48),
            ])
        }

        // About me freeform text.
        let aboutLabel = NSTextField(labelWithString: "About me")
        aboutLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        aboutLabel.textColor = .secondaryLabelColor
        let aboutHint = NSTextField(labelWithString:
            "Anything Blink should always know: pronouns, role, recurring context."
        )
        aboutHint.font = NSFont.systemFont(ofSize: 11)
        aboutHint.textColor = .tertiaryLabelColor

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        let textView = NSTextView()
        textView.isRichText = false
        textView.font = NSFont.systemFont(ofSize: 12)
        textView.delegate = self
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        scroll.documentView = textView
        aboutMeView = textView

        let counter = NSTextField(labelWithString: "0 / \(StylePrefs.aboutMeMaxChars)")
        counter.font = NSFont.systemFont(ofSize: 10)
        counter.textColor = .tertiaryLabelColor
        aboutMeCounter = counter

        let aboutStack = NSStackView(views: [aboutLabel, aboutHint, scroll, counter])
        aboutStack.orientation = .vertical
        aboutStack.alignment = .leading
        aboutStack.spacing = 4
        aboutStack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(aboutStack)

        // Preset + reset buttons.
        let defaultsBtn = NSButton(title: "Default", target: self, action: #selector(applyDefaultPreset))
        let proBtn = NSButton(title: "Professional", target: self, action: #selector(applyProfessionalPreset))
        let boldBtn = NSButton(title: "Bold", target: self, action: #selector(applyBoldPreset))
        let resetBtn = NSButton(title: "Reset", target: self, action: #selector(reset))
        for btn in [defaultsBtn, proBtn, boldBtn, resetBtn] {
            btn.bezelStyle = .rounded
            btn.controlSize = .small
        }
        let buttonRow = NSStackView(views: [defaultsBtn, proBtn, boldBtn, NSView(), resetBtn])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .firstBaseline
        stack.addArrangedSubview(buttonRow)

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalToConstant: 460 - 48),
            scroll.heightAnchor.constraint(equalToConstant: 90),
            buttonRow.widthAnchor.constraint(equalToConstant: 460 - 48),
        ])
        win.contentView = content
        content.layoutSubtreeIfNeeded()
        window = win
    }

    private func startSubscription() {
        styleSubscription = runtimeStore.$style
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.applyCurrentStyle()
                }
            }
    }

    private func stopSubscription() {
        styleSubscription = nil
    }

    private func applyCurrentStyle() {
        let s = runtimeStore.style
        setSegment(initiativeControl, value: s.initiative, leftValue: "incremental", rightValue: "agentic")
        setSegment(toneControl, value: s.tone, leftValue: "casual", rightValue: "formal")
        setSegment(lengthControl, value: s.length, leftValue: "terse", rightValue: "thorough")
        setSegment(directnessControl, value: s.directness, leftValue: "diplomatic", rightValue: "direct")
        setSegment(voiceMirrorControl, value: s.voiceMirror, leftValue: "neutral", rightValue: "mirror")
        if let view = aboutMeView, view.string != s.aboutMe {
            view.string = s.aboutMe
        }
        updateAboutMeCounter()
    }

    private func setSegment(_ control: NSSegmentedControl?, value: String, leftValue: String, rightValue: String) {
        guard let control else { return }
        let target: Int
        switch value {
        case leftValue: target = 0
        case rightValue: target = 2
        default: target = 1
        }
        if control.selectedSegment != target {
            control.selectedSegment = target
        }
    }

    private func updateAboutMeCounter() {
        let count = aboutMeView?.string.unicodeScalars.count ?? 0
        aboutMeCounter?.stringValue = "\(count) / \(StylePrefs.aboutMeMaxChars)"
        aboutMeCounter?.textColor = count > StylePrefs.aboutMeMaxChars
            ? .systemOrange
            : .tertiaryLabelColor
    }

    @objc private func knobChanged(_ sender: NSSegmentedControl) {
        let spec = Self.knobs[sender.tag]
        let value: String
        switch sender.selectedSegment {
        case 0: value = spec.leftValue
        case 2: value = spec.rightValue
        default: value = "balanced"
        }
        var style = runtimeStore.style
        switch spec.label {
        case "Initiative": style.initiative = value
        case "Tone": style.tone = value
        case "Length": style.length = value
        case "Directness": style.directness = value
        case "Voice mirror": style.voiceMirror = value
        default: return
        }
        runtimeStore.style = style
    }

    func textDidChange(_ notification: Notification) {
        guard let view = aboutMeView else { return }
        var text = view.string
        // Match Python's str[:N] (Unicode codepoints) so client- and
        // server-side truncation stay in lockstep. Counting graphemes would
        // diverge on multi-scalar emoji and produce mismatched cache keys.
        if text.unicodeScalars.count > StylePrefs.aboutMeMaxChars {
            let truncated = text.unicodeScalars.prefix(StylePrefs.aboutMeMaxChars)
            text = String(String.UnicodeScalarView(truncated))
            view.string = text
        }
        updateAboutMeCounter()
        var style = runtimeStore.style
        if style.aboutMe != text {
            style.aboutMe = text
            runtimeStore.style = style
        }
    }

    @objc private func applyDefaultPreset() { runtimeStore.style = .default }

    @objc private func applyProfessionalPreset() {
        var style = runtimeStore.style
        style.initiative = "balanced"
        style.tone = "formal"
        style.length = "balanced"
        style.directness = "balanced"
        style.voiceMirror = "balanced"
        runtimeStore.style = style
    }

    @objc private func applyBoldPreset() {
        var style = runtimeStore.style
        style.initiative = "agentic"
        style.tone = "casual"
        style.length = "terse"
        style.directness = "direct"
        style.voiceMirror = "mirror"
        runtimeStore.style = style
    }

    @objc private func reset() {
        var style = StylePrefs.default
        // Preserve about_me on reset — it's typed prose, not a knob.
        style.aboutMe = runtimeStore.style.aboutMe
        runtimeStore.style = style
    }

    func windowWillClose(_ notification: Notification) {
        stopSubscription()
    }
}
