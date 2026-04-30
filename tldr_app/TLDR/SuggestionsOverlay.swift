import AppKit

final class SuggestionsPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class SuggestionsOverlay {
    private var panel: SuggestionsPanel?

    var isVisible: Bool {
        panel?.isVisible == true
    }

    func show(tldr: String, suggestions: [String], autoPaste: Bool) {
        close()

        let panelWidth: CGFloat = 620
        let cardPaddingX: CGFloat = 20
        let cardPaddingY: CGFloat = 16
        let cardGap: CGFloat = 10
        let footerHeight: CGFloat = 24
        let font = NSFont.systemFont(ofSize: 16)
        let labelWidth = panelWidth - cardPaddingX * 2
        let visibleSuggestions = Array(suggestions.prefix(3))

        let tldrHeight = measureHeight(tldr, width: labelWidth, font: font) + cardPaddingY * 2
        let rowHeights = visibleSuggestions.enumerated().map { index, text in
            max(66, measureHeight("\(index + 1).  \(text)", width: labelWidth, font: font) + cardPaddingY * 2)
        }
        let panelHeight = tldrHeight
            + cardGap
            + rowHeights.reduce(0, +)
            + cardGap * CGFloat(max(0, rowHeights.count - 1))
            + cardGap
            + footerHeight

        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: screenFrame.midX - panelWidth / 2,
            y: screenFrame.midY - panelHeight / 2
        )
        let frame = NSRect(origin: origin, size: NSSize(width: panelWidth, height: panelHeight))

        let style: NSWindow.StyleMask = [.nonactivatingPanel, .borderless, .fullSizeContentView]
        let panel = SuggestionsPanel(
            contentRect: frame,
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.worksWhenModal = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear

        let content = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = content

        var y = panelHeight - tldrHeight
        content.addSubview(card(
            frame: NSRect(x: 0, y: y, width: panelWidth, height: tldrHeight),
            text: tldr,
            font: font,
            textColor: NSColor(calibratedWhite: 0.94, alpha: 0.98),
            material: .hudWindow
        ))
        y -= cardGap

        for (idx, text) in visibleSuggestions.enumerated() {
            let height = rowHeights[idx]
            y -= height
            content.addSubview(card(
                frame: NSRect(x: 0, y: y, width: panelWidth, height: height),
                text: "\(idx + 1).  \(text)",
                font: font,
                textColor: .white,
                material: .popover
            ))
            y -= cardGap
        }

        let footer = label(
            frame: NSRect(x: 0, y: 0, width: panelWidth, height: footerHeight),
            text: autoPaste ? "1 / 2 / 3 to paste   /   esc to dismiss" : "1 / 2 / 3 to copy   /   esc to dismiss",
            font: font,
            color: NSColor(calibratedWhite: 0.82, alpha: 0.86)
        )
        footer.alignment = .center
        content.addSubview(footer)

        self.panel = panel
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.close()
        panel = nil
    }

    private func card(
        frame: NSRect,
        text: String,
        font: NSFont,
        textColor: NSColor,
        material: NSVisualEffectView.Material
    ) -> NSView {
        let view = NSVisualEffectView(frame: frame)
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 14
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.18).cgColor
        view.addSubview(label(
            frame: NSRect(
                x: 20,
                y: 16,
                width: frame.width - 40,
                height: frame.height - 32
            ),
            text: text,
            font: font,
            color: textColor
        ))
        return view
    }

    private func label(frame: NSRect, text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.frame = frame
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byWordWrapping
        label.usesSingleLineMode = false
        return label
    }

    private func measureHeight(_ text: String, width: CGFloat, font: NSFont) -> CGFloat {
        let attr = NSAttributedString(string: text, attributes: [.font: font])
        let rect = attr.boundingRect(
            with: NSSize(width: width, height: 1000),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return max(24, ceil(rect.height) + 8)
    }
}
