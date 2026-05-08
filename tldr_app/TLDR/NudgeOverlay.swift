import AppKit

@MainActor
final class NudgeOverlay {
    private final class TipPanel: NSPanel {
        var onClick: (() -> Void)?
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }

        override func mouseDown(with event: NSEvent) {
            onClick?()
        }
    }

    private enum Layout {
        static let width: CGFloat = 320
        static let height: CGFloat = 48
        static let margin: CGFloat = 8
        static let cornerRadius: CGFloat = 12
        static let fadeIn: TimeInterval = 0.18
        static let fadeOut: TimeInterval = 0.25
        static let iconSize: CGFloat = 24
        static let iconLeading: CGFloat = 12
        static let labelLeading: CGFloat = 44  // iconLeading + iconSize + 8 gap
        static let labelTrailing: CGFloat = 12
        static let scaleStart: CGFloat = 0.92
    }

    private var panel: TipPanel?
    private var dismissTimer: Timer?
    private var didDismiss: Bool = false
    private var dismissCallback: ((Bool) -> Void)?

    var isVisible: Bool { panel?.isVisible == true }

    /// Show a one-line tip anchored just below the given screen-space frame
    /// (typically the menubar status item's button frame on screen).
    /// `onDismiss(userClicked)` fires once when the tip closes — `true` if the
    /// user clicked it, `false` on auto-fade or programmatic close.
    func show(
        text: String,
        anchor: NSRect,
        autoDismissAfter: TimeInterval = 4.0,
        onDismiss: @escaping (Bool) -> Void
    ) {
        close(userClicked: false, animated: false)

        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main
        let originX: CGFloat
        if let screen {
            let preferred = anchor.midX - Layout.width / 2
            let minX = screen.visibleFrame.minX + 4
            let maxX = screen.visibleFrame.maxX - Layout.width - 4
            originX = max(minX, min(preferred, maxX))
        } else {
            originX = anchor.midX - Layout.width / 2
        }
        let originY = anchor.minY - Layout.height - Layout.margin
        let frame = NSRect(x: originX, y: originY, width: Layout.width, height: Layout.height)

        let panel = TipPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.alphaValue = 0
        panel.appearance = NSAppearance(named: .darkAqua)

        let content = NSView(frame: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.height))
        content.wantsLayer = true
        content.layer?.cornerRadius = Layout.cornerRadius
        content.layer?.masksToBounds = true

        let backdrop = NSVisualEffectView(frame: content.bounds)
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.autoresizingMask = [.width, .height]
        content.addSubview(backdrop)

        let tint = NSView(frame: content.bounds)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        tint.autoresizingMask = [.width, .height]
        content.addSubview(tint)

        let iconView = NSImageView(frame: NSRect(
            x: Layout.iconLeading,
            y: (Layout.height - Layout.iconSize) / 2,
            width: Layout.iconSize,
            height: Layout.iconSize
        ))
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.imageAlignment = .alignCenter
        content.addSubview(iconView)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.frame = NSRect(
            x: Layout.labelLeading,
            y: 0,
            width: Layout.width - Layout.labelLeading - Layout.labelTrailing,
            height: Layout.height
        )
        label.isBordered = false
        label.drawsBackground = false
        label.isSelectable = false
        content.addSubview(label)

        panel.contentView = content
        panel.onClick = { [weak self] in
            self?.close(userClicked: true, animated: true)
        }

        self.panel = panel
        self.didDismiss = false
        self.dismissCallback = onDismiss

        panel.orderFrontRegardless()

        // Set anchor point, position, and initial scale atomically so there's no
        // single-frame visual offset between the anchorPoint and position writes.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        content.layer?.position = CGPoint(x: Layout.width / 2, y: Layout.height / 2)
        content.layer?.transform = CATransform3DMakeScale(Layout.scaleStart, Layout.scaleStart, 1)
        CATransaction.commit()

        let scaleAnim = CABasicAnimation(keyPath: "transform")
        scaleAnim.fromValue = CATransform3DMakeScale(Layout.scaleStart, Layout.scaleStart, 1)
        scaleAnim.toValue = CATransform3DIdentity
        scaleAnim.duration = Layout.fadeIn
        scaleAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        content.layer?.add(scaleAnim, forKey: "scaleIn")
        content.layer?.transform = CATransform3DIdentity

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Layout.fadeIn
            panel.animator().alphaValue = 1.0
        }

        dismissTimer?.invalidate()
        let timer = Timer(timeInterval: autoDismissAfter, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.close(userClicked: false, animated: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dismissTimer = timer
    }

    func close(userClicked: Bool, animated: Bool) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        guard let panel else {
            fireDismissCallback(userClicked: userClicked)
            return
        }
        let finish: () -> Void = { [weak self] in
            panel.orderOut(nil)
            self?.panel = nil
            self?.fireDismissCallback(userClicked: userClicked)
        }
        if animated && panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Layout.fadeOut
                panel.animator().alphaValue = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Layout.fadeOut) {
                finish()
            }
        } else {
            finish()
        }
    }

    private func fireDismissCallback(userClicked: Bool) {
        guard !didDismiss else { return }
        didDismiss = true
        let callback = dismissCallback
        dismissCallback = nil
        callback?(userClicked)
    }
}
