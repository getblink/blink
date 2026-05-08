import AppKit

enum FeedbackSound {
    case none
    case trigger
    case success
    case failure

    @MainActor
    func play() {
        switch self {
        case .none:
            return
        case .trigger:
            playNamed("Ping")
        case .success:
            playNamed("Glass")
        case .failure:
            playNamed("Funk")
        }
    }

    @MainActor
    private func playNamed(_ name: String) {
        if let sound = NSSound(named: NSSound.Name(name)) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }
}

struct StopwatchHandle: Equatable {
    let id: UUID
}

@MainActor
final class FeedbackCenter {
    static let shared = FeedbackCenter()

    private var panel: NSPanel?
    private var titleLabel: NSTextField?
    private var detailLabel: NSTextField?
    private var elapsedLabel: NSTextField?
    private var dismissWorkItem: DispatchWorkItem?
    private var activeStopwatch: ActiveStopwatch?

    private struct ActiveStopwatch {
        let id: UUID
        let start: DispatchTime
        let timer: Timer
    }

    private init() {}

    func post(
        title: String,
        detail: String? = nil,
        sound: FeedbackSound = .none,
        duration: TimeInterval = 1.8
    ) {
        cancelStopwatch()
        sound.play()
        ensurePanel()
        update(title: title, detail: detail, elapsed: nil)
        show(duration: duration)
    }

    @discardableResult
    func startStopwatch(
        title: String,
        detail: String?,
        sound: FeedbackSound = .none
    ) -> StopwatchHandle {
        cancelStopwatch()
        sound.play()
        ensurePanel()

        let id = UUID()
        let start = DispatchTime.now()
        update(title: title, detail: detail, elapsed: 0)
        showWithoutAutoDismiss()

        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self,
                      let active = self.activeStopwatch,
                      active.id == id else { return }
                let elapsed = self.elapsedSeconds(start: active.start)
                self.elapsedLabel?.stringValue = self.formatElapsed(elapsed)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        activeStopwatch = ActiveStopwatch(id: id, start: start, timer: timer)
        return StopwatchHandle(id: id)
    }

    func updateStopwatch(
        _ handle: StopwatchHandle,
        title: String? = nil,
        detail: String? = nil
    ) {
        guard activeStopwatch?.id == handle.id else { return }
        if let title = title {
            titleLabel?.stringValue = title
        }
        if let detail = detail {
            detailLabel?.stringValue = detail
            detailLabel?.isHidden = detail.isEmpty
        }
        relayout()
    }

    func stopStopwatch(
        _ handle: StopwatchHandle,
        title: String,
        detail: String?,
        sound: FeedbackSound = .none,
        dismissAfter: TimeInterval = 1.2
    ) {
        guard let active = activeStopwatch, active.id == handle.id else { return }
        let final = elapsedSeconds(start: active.start)
        active.timer.invalidate()
        activeStopwatch = nil

        sound.play()
        update(title: title, detail: detail, elapsed: final)
        relayout()
        scheduleDismiss(after: dismissAfter)
    }

    private func cancelStopwatch() {
        if let active = activeStopwatch {
            active.timer.invalidate()
            activeStopwatch = nil
        }
    }

    private func elapsedSeconds(start: DispatchTime) -> TimeInterval {
        let now = DispatchTime.now()
        let deltaNs = now.uptimeNanoseconds &- start.uptimeNanoseconds
        return TimeInterval(deltaNs) / 1_000_000_000.0
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        String(format: "%.2f s", seconds)
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byWordWrapping
        title.maximumNumberOfLines = 2

        let detail = NSTextField(labelWithString: "")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byWordWrapping
        detail.maximumNumberOfLines = 3

        let elapsed = NSTextField(labelWithString: "")
        elapsed.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        elapsed.textColor = .tertiaryLabelColor
        elapsed.lineBreakMode = .byClipping
        elapsed.maximumNumberOfLines = 1
        elapsed.isHidden = true

        let stack = NSStackView(views: [title, detail, elapsed])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let cornerRadius: CGFloat = 14
        let background = Self.makeBackgroundView(cornerRadius: cornerRadius, content: stack)
        background.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            background.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
        ])

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 88),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = background
        panel.alphaValue = 0

        self.panel = panel
        self.titleLabel = title
        self.detailLabel = detail
        self.elapsedLabel = elapsed
    }

    private func update(title: String, detail: String?, elapsed: TimeInterval?) {
        titleLabel?.stringValue = title
        if let detail, !detail.isEmpty {
            detailLabel?.stringValue = detail
            detailLabel?.isHidden = false
        } else {
            detailLabel?.stringValue = ""
            detailLabel?.isHidden = true
        }
        if let elapsed {
            elapsedLabel?.stringValue = formatElapsed(elapsed)
            elapsedLabel?.isHidden = false
        } else {
            elapsedLabel?.stringValue = ""
            elapsedLabel?.isHidden = true
        }
        relayout()
    }

    private func relayout() {
        guard let panel, let contentView = panel.contentView else { return }
        let fitting = contentView.fittingSize
        let width = min(max(fitting.width, 220), 320)
        let height = max(fitting.height, 62)
        let frame = frameForPanel(width: width, height: height)
        panel.setFrame(frame, display: true)
    }

    private func showWithoutAutoDismiss() {
        guard let panel else { return }
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        relayout()
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    private func show(duration: TimeInterval) {
        showWithoutAutoDismiss()
        scheduleDismiss(after: duration)
    }

    private func scheduleDismiss(after duration: TimeInterval) {
        guard panel != nil else { return }
        dismissWorkItem?.cancel()
        let dismiss = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
            })
        }
        dismissWorkItem = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: dismiss)
    }

    private static func makeBackgroundView(cornerRadius: CGFloat, content: NSView) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            return glass
        }

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = roundedMaskImage(cornerRadius: cornerRadius)
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        return effect
    }

    private static func roundedMaskImage(cornerRadius: CGFloat) -> NSImage {
        let edge = cornerRadius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(
            top: cornerRadius,
            left: cornerRadius,
            bottom: cornerRadius,
            right: cornerRadius
        )
        image.resizingMode = .stretch
        return image
    }

    private func frameForPanel(width: CGFloat, height: CGFloat) -> NSRect {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(
            x: screenFrame.maxX - width - 24,
            y: screenFrame.maxY - height - 24,
            width: width,
            height: height
        )
    }
}
