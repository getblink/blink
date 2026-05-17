import AppKit
import Combine

@MainActor
protocol LibraryStripDelegate: AnyObject {
    func libraryStripDidDrop(urls: [URL])
    func libraryStripDragEntered()
    func libraryStripDidRequestRemove(id: String)
    func libraryStripDidRequestShowInFinder(id: String)
    func libraryStripDidRequestRetry(id: String)
}

/// Horizontally-scrolling strip that lives below the keycap row in ControlWindow.
/// Accepts file drops and renders staged attachment pills.
final class LibraryStripView: NSView {
    weak var delegate: LibraryStripDelegate?

    /// Timestamp of the most recent `draggingEntered` call, used by ControlWindow.show()
    /// to skip NSApp.activate when a drag is in flight.
    private(set) var lastDragEnteredAt: Date = .distantPast

    private let emptyHintLabel = NSTextField(labelWithString: "Drag files here to stage attachments")
    private let scrollView = NSScrollView()
    private let pillStack = NSStackView()
    private var entries: [AttachmentEntry] = []
    private var unavailableIDs: Set<String> = []

    private static let stripHeight: CGFloat = 56
    private static let pillHeight: CGFloat = 40
    private static let pillCornerRadius: CGFloat = 10
    private static let pillPaddingX: CGFloat = 10
    private static let pillSpacing: CGFloat = 8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.borderWidth = 1.5
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        layer?.cornerRadius = 12
        layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.3).cgColor

        // Dashed border for the empty state
        applyDashedBorder(active: false)

        // Empty hint
        emptyHintLabel.font = NSFont.systemFont(ofSize: 12)
        emptyHintLabel.textColor = .tertiaryLabelColor
        emptyHintLabel.alignment = .center
        emptyHintLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyHintLabel)

        // Scroll view + pill stack (hidden when empty)
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        pillStack.orientation = .horizontal
        pillStack.spacing = Self.pillSpacing
        pillStack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        pillStack.alignment = .centerY
        pillStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = pillStack

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.stripHeight),

            emptyHintLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyHintLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            pillStack.heightAnchor.constraint(equalToConstant: Self.pillHeight),
            pillStack.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])

        scrollView.isHidden = true

        registerForDraggedTypes([.fileURL])
    }

    // MARK: - Content update

    func update(entries: [AttachmentEntry], unavailableIDs: Set<String>) {
        self.entries = entries
        self.unavailableIDs = unavailableIDs
        rebuildPills()
    }

    private func rebuildPills() {
        // Remove old pills
        for sub in pillStack.arrangedSubviews {
            pillStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }

        if entries.isEmpty {
            scrollView.isHidden = true
            emptyHintLabel.isHidden = false
            applyDashedBorder(active: false)
            return
        }

        scrollView.isHidden = false
        emptyHintLabel.isHidden = true
        applyDashedBorder(active: false)

        for entry in entries {
            let pill = makePill(for: entry)
            pillStack.addArrangedSubview(pill)
        }

        // Let the stack know its intrinsic size so the scroll view works correctly
        pillStack.frame = CGRect(
            x: 0,
            y: (Self.stripHeight - Self.pillHeight) / 2,
            width: pillStack.fittingSize.width,
            height: Self.pillHeight
        )
    }

    private func makePill(for entry: AttachmentEntry) -> NSView {
        let outer = NSView()
        outer.wantsLayer = true
        outer.layer?.cornerRadius = Self.pillCornerRadius
        outer.layer?.masksToBounds = true
        outer.translatesAutoresizingMaskIntoConstraints = false

        let isUnavailable = unavailableIDs.contains(entry.id)
        outer.layer?.backgroundColor = (isUnavailable
            ? NSColor.secondaryLabelColor.withAlphaComponent(0.12)
            : NSColor.controlBackgroundColor.withAlphaComponent(0.8)).cgColor
        outer.layer?.borderWidth = 0.5
        outer.layer?.borderColor = NSColor.separatorColor.cgColor

        // Thumbnail (if available)
        var thumbnailView: NSView?
        let thumbSize: CGFloat = 28
        if entry.kind == .image, let thumb = AttachmentLibrary.shared.thumbnail(for: entry.id) {
            let iv = NSImageView(image: thumb)
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.imageAlignment = .alignCenter
            iv.wantsLayer = true
            iv.layer?.cornerRadius = 4
            iv.layer?.masksToBounds = true
            iv.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                iv.widthAnchor.constraint(equalToConstant: thumbSize),
                iv.heightAnchor.constraint(equalToConstant: thumbSize),
            ])
            thumbnailView = iv
        } else {
            // File-type icon
            let icon = NSImageView()
            icon.image = NSWorkspace.shared.icon(forFileType: URL(fileURLWithPath: entry.displayName).pathExtension)
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: thumbSize),
                icon.heightAnchor.constraint(equalToConstant: thumbSize),
            ])
            thumbnailView = icon
        }

        let nameLabel = NSTextField(labelWithString: entry.displayName)
        nameLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        nameLabel.textColor = isUnavailable ? .secondaryLabelColor : .labelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 100)])

        // Status dot
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        let dotColor: NSColor
        switch entry.descriptionStatus {
        case .ready: dotColor = isUnavailable ? .secondaryLabelColor : .systemGreen
        case .pending: dotColor = .systemYellow
        case .failed: dotColor = .systemOrange
        }
        dot.layer?.backgroundColor = dotColor.cgColor
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
        ])
        dot.toolTip = isUnavailable ? "File unavailable (volume not mounted?)" :
            entry.descriptionStatus == .ready ? "Description ready" :
            entry.descriptionStatus == .pending ? "Generating description…" : "Description failed — right-click to retry or remove"

        let hStack = NSStackView()
        hStack.orientation = .horizontal
        hStack.alignment = .centerY
        hStack.spacing = 6
        hStack.edgeInsets = NSEdgeInsets(top: 0, left: Self.pillPaddingX, bottom: 0, right: Self.pillPaddingX)
        if let tv = thumbnailView { hStack.addArrangedSubview(tv) }
        hStack.addArrangedSubview(nameLabel)
        hStack.addArrangedSubview(dot)
        hStack.translatesAutoresizingMaskIntoConstraints = false

        outer.addSubview(hStack)
        NSLayoutConstraint.activate([
            hStack.leadingAnchor.constraint(equalTo: outer.leadingAnchor),
            hStack.trailingAnchor.constraint(equalTo: outer.trailingAnchor),
            hStack.centerYAnchor.constraint(equalTo: outer.centerYAnchor),
            outer.heightAnchor.constraint(equalToConstant: Self.pillHeight),
        ])

        outer.toolTip = isUnavailable ? "File unavailable" : entry.description.isEmpty ? entry.displayName : entry.description
        outer.menu = makeContextMenu(for: entry)
        return outer
    }

    // MARK: - Context menu

    private func makeContextMenu(for entry: AttachmentEntry) -> NSMenu {
        let menu = NSMenu()
        if entry.descriptionStatus == .failed {
            let retry = NSMenuItem(title: "Retry description", action: #selector(handleRetry(_:)), keyEquivalent: "")
            retry.target = self
            retry.representedObject = entry.id
            menu.addItem(retry)
            menu.addItem(.separator())
        }
        let show = NSMenuItem(title: "Show in Finder", action: #selector(handleShowInFinder(_:)), keyEquivalent: "")
        show.target = self
        show.representedObject = entry.id
        menu.addItem(show)

        let remove = NSMenuItem(title: "Remove", action: #selector(handleRemove(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = entry.id
        menu.addItem(remove)
        return menu
    }

    @objc private func handleRemove(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        delegate?.libraryStripDidRequestRemove(id: id)
    }

    @objc private func handleShowInFinder(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        delegate?.libraryStripDidRequestShowInFinder(id: id)
    }

    @objc private func handleRetry(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        delegate?.libraryStripDidRequestRetry(id: id)
    }

    private func applyDashedBorder(active: Bool) {
        guard let layer else { return }
        // Remove existing dash layer
        layer.sublayers?.filter { $0.name == "dashBorder" }.forEach { $0.removeFromSuperlayer() }
        guard entries.isEmpty else { return }

        let dashLayer = CAShapeLayer()
        dashLayer.name = "dashBorder"
        dashLayer.strokeColor = NSColor.systemBlue.withAlphaComponent(active ? 0.7 : 0.3).cgColor
        dashLayer.fillColor = NSColor.clear.cgColor
        dashLayer.lineWidth = 1.5
        dashLayer.lineDashPattern = [6, 4]
        dashLayer.path = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: 12, cornerHeight: 12, transform: nil)
        layer.addSublayer(dashLayer)
    }

    override func layout() {
        super.layout()
        // Refresh dash border path when bounds change
        if entries.isEmpty { applyDashedBorder(active: false) }
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        lastDragEnteredAt = Date()
        delegate?.libraryStripDragEntered()
        guard containsFileURLs(sender) else { return [] }
        applyDashedBorder(active: true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard containsFileURLs(sender) else { return [] }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        applyDashedBorder(active: false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        applyDashedBorder(active: false)
        delegate?.libraryStripDidDrop(urls: urls)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        applyDashedBorder(active: false)
    }

    // MARK: - Drag helpers

    private func containsFileURLs(_ info: NSDraggingInfo) -> Bool {
        info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    private func fileURLs(from info: NSDraggingInfo) -> [URL] {
        let pb = info.draggingPasteboard
        return (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}
