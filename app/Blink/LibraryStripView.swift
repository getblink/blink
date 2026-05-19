import AppKit
import Combine
import Quartz

@MainActor
protocol LibraryStripDelegate: AnyObject {
    func libraryStripDidDrop(urls: [URL])
    func libraryStripDragEntered()
    func libraryStripDidRequestRemove(id: String)
    func libraryStripDidRequestShowInFinder(id: String)
    func libraryStripDidRequestRetry(id: String)
    func libraryStripDidRequestPickFiles()
}

/// Horizontally-scrolling strip that lives below the keycap row in ControlWindow.
/// Accepts file drops and renders staged attachment pills. Clicking a pill opens
/// a QuickLook preview; hovering reveals an inline remove button.
final class LibraryStripView: NSView {
    weak var delegate: LibraryStripDelegate?

    /// Timestamp of the most recent `draggingEntered` call, used by ControlWindow.show()
    /// to skip NSApp.activate when a drag is in flight.
    private(set) var lastDragEnteredAt: Date = .distantPast

    // Empty state
    private let emptyContainer = NSStackView()
    private let emptyIcon = NSImageView()
    private let emptyTitle = NSTextField(labelWithString: "Click or drop files to stage attachments")
    private let emptySubtitle = NSTextField(labelWithString: "PDFs, images, text — Blink attaches them when relevant")

    // Populated state
    private let scrollView = NSScrollView()
    private let pillStack = NSStackView()
    private var entries: [AttachmentEntry] = []
    private var unavailableIDs: Set<String> = []

    // QuickLook
    private var previewURLs: [URL] = []
    private var previewIndex: Int = 0

    static let preferredHeight: CGFloat = 84
    private static let pillHeight: CGFloat = 60
    private static let pillCornerRadius: CGFloat = 12

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.35).cgColor

        applyDashedBorder(active: false)

        setupEmptyState()
        setupPillStack()

        addSubview(emptyContainer)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.preferredHeight),

            emptyContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            emptyContainer.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            emptyContainer.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),

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

    private func setupEmptyState() {
        emptyContainer.orientation = .vertical
        emptyContainer.alignment = .centerX
        emptyContainer.spacing = 6
        emptyContainer.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: "Drop files")
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        emptyIcon.image = icon?.withSymbolConfiguration(config)
        emptyIcon.contentTintColor = NSColor.tertiaryLabelColor
        emptyIcon.translatesAutoresizingMaskIntoConstraints = false

        emptyTitle.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        emptyTitle.textColor = .secondaryLabelColor
        emptyTitle.alignment = .center

        emptySubtitle.font = NSFont.systemFont(ofSize: 11)
        emptySubtitle.textColor = .tertiaryLabelColor
        emptySubtitle.alignment = .center

        emptyContainer.addArrangedSubview(emptyIcon)
        emptyContainer.addArrangedSubview(emptyTitle)
        emptyContainer.addArrangedSubview(emptySubtitle)
        emptyContainer.setCustomSpacing(4, after: emptyIcon)
        emptyContainer.setCustomSpacing(2, after: emptyTitle)
    }

    private func setupPillStack() {
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        pillStack.orientation = .horizontal
        pillStack.spacing = 8
        // No internal horizontal inset — the strip sits inside ControlWindow's
        // 24pt content gutter, and any extra padding here makes the pills
        // visibly indent past the "Attachments" header and status label above.
        pillStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        pillStack.alignment = .centerY
        // NSScrollView wants its documentView sized by frame, not auto-layout —
        // otherwise the horizontally-overflowing stack collapses to the
        // clip-view width and scrolling no-ops.
        pillStack.translatesAutoresizingMaskIntoConstraints = true
        scrollView.documentView = pillStack
    }

    // MARK: - Content update

    func update(entries: [AttachmentEntry], unavailableIDs: Set<String>) {
        self.entries = entries
        self.unavailableIDs = unavailableIDs
        rebuildPills()
    }

    private func rebuildPills() {
        for sub in pillStack.arrangedSubviews {
            pillStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }

        if entries.isEmpty {
            scrollView.isHidden = true
            emptyContainer.isHidden = false
            applyDashedBorder(active: false)
            return
        }

        scrollView.isHidden = false
        emptyContainer.isHidden = true
        // Hide the dashed border when content fills the strip — it competes
        // with the pill borders and clutters the eye.
        clearDashedBorder()

        for entry in entries {
            let pill = PillView(
                entry: entry,
                isUnavailable: unavailableIDs.contains(entry.id),
                thumbnail: AttachmentLibrary.shared.thumbnail(for: entry.id),
                onClick: { [weak self] id in self?.previewEntry(id: id) },
                onRemove: { [weak self] id in self?.delegate?.libraryStripDidRequestRemove(id: id) }
            )
            pill.menu = makeContextMenu(for: entry)
            pillStack.addArrangedSubview(pill)
        }

        let addPill = AddFilesPillView { [weak self] in
            self?.delegate?.libraryStripDidRequestPickFiles()
        }
        pillStack.addArrangedSubview(addPill)

        pillStack.frame = CGRect(
            x: 0,
            y: 0,
            width: pillStack.fittingSize.width,
            height: Self.pillHeight
        )
    }

    // MARK: - Context menu

    private func makeContextMenu(for entry: AttachmentEntry) -> NSMenu {
        let menu = NSMenu()
        let preview = NSMenuItem(title: "Quick Look", action: #selector(handlePreview(_:)), keyEquivalent: " ")
        preview.target = self
        preview.representedObject = entry.id
        menu.addItem(preview)
        menu.addItem(.separator())

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

    @objc private func handlePreview(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        previewEntry(id: id)
    }

    // MARK: - QuickLook preview

    fileprivate func previewEntry(id: String) {
        // Resolve every entry's URL up-front so the panel can navigate
        // between pills with the arrow keys without us hopping back through
        // the bookmark resolver on each step.
        var urls: [URL] = []
        var targetIndex = 0
        for entry in entries {
            guard let url = AttachmentLibrary.shared.resolveURLSync(for: entry) else { continue }
            if entry.id == id { targetIndex = urls.count }
            urls.append(url)
        }
        guard !urls.isEmpty else { return }
        previewURLs = urls
        previewIndex = targetIndex
        guard let panel = QLPreviewPanel.shared() else { return }
        // QuickLook drives the controller through the responder chain, so the
        // window has to make us first responder for panel callbacks to land.
        window?.makeFirstResponder(self)
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - QLPreviewPanel controller hooks

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = previewIndex
        panel.reloadData()
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        previewURLs.removeAll()
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Dashed border

    private func applyDashedBorder(active: Bool) {
        guard let layer else { return }
        layer.sublayers?.filter { $0.name == "dashBorder" }.forEach { $0.removeFromSuperlayer() }
        guard entries.isEmpty else { return }

        let dashLayer = CAShapeLayer()
        dashLayer.name = "dashBorder"
        dashLayer.strokeColor = (active
            ? NSColor.controlAccentColor.withAlphaComponent(0.7)
            : NSColor.separatorColor.withAlphaComponent(0.35)
        ).cgColor
        dashLayer.fillColor = NSColor.clear.cgColor
        dashLayer.lineWidth = 1.0
        dashLayer.lineDashPattern = [4, 5]
        dashLayer.path = CGPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            cornerWidth: 14, cornerHeight: 14, transform: nil
        )
        layer.addSublayer(dashLayer)
    }

    private func clearDashedBorder() {
        layer?.sublayers?.filter { $0.name == "dashBorder" }.forEach { $0.removeFromSuperlayer() }
    }

    override func layout() {
        super.layout()
        if entries.isEmpty { applyDashedBorder(active: false) }
    }

    override func mouseDown(with event: NSEvent) {
        // Click anywhere in the empty state opens a file picker.
        // When populated, clicks land on the AddFilesPillView at the end
        // of the strip — let those events flow through to the pill.
        if entries.isEmpty {
            delegate?.libraryStripDidRequestPickFiles()
            return
        }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if entries.isEmpty {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        lastDragEnteredAt = Date()
        delegate?.libraryStripDragEntered()
        guard containsFileURLs(sender) else { return [] }
        // Highlight even when populated — falls back to a glowing background
        // since dashed border is hidden once pills are present.
        applyDragHighlight(active: true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard containsFileURLs(sender) else { return [] }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        applyDragHighlight(active: false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        applyDragHighlight(active: false)
        delegate?.libraryStripDidDrop(urls: urls)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        applyDragHighlight(active: false)
    }

    private func applyDragHighlight(active: Bool) {
        if entries.isEmpty {
            applyDashedBorder(active: active)
        } else {
            // Subtle accent background wash when a drag is over the populated strip
            layer?.backgroundColor = (active
                ? NSColor.controlAccentColor.withAlphaComponent(0.12)
                : NSColor.controlBackgroundColor.withAlphaComponent(0.35)
            ).cgColor
        }
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

// MARK: - QLPreviewPanelDataSource / Delegate

extension LibraryStripView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURLs[index] as NSURL
    }
}

// MARK: - Pill view

/// A single attachment pill: thumbnail/icon, name, status line, and an
/// inline remove button that fades in on hover. Click to QuickLook.
private final class PillView: NSView {
    private let entryID: String
    private let onClick: (String) -> Void
    private let onRemove: (String) -> Void
    private let isUnavailable: Bool

    private let thumbView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let statusDot = NSView()
    private let removeButton = NSButton()
    private var trackingArea: NSTrackingArea?
    private var hovered: Bool = false

    private static let height: CGFloat = 60
    private static let radius: CGFloat = 12
    private static let thumbSize: CGFloat = 40
    private static let paddingX: CGFloat = 10
    private static let nameMaxWidth: CGFloat = 168

    init(
        entry: AttachmentEntry,
        isUnavailable: Bool,
        thumbnail: NSImage?,
        onClick: @escaping (String) -> Void,
        onRemove: @escaping (String) -> Void
    ) {
        self.entryID = entry.id
        self.onClick = onClick
        self.onRemove = onRemove
        self.isUnavailable = isUnavailable
        super.init(frame: .zero)
        configure(entry: entry, thumbnail: thumbnail)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func configure(entry: AttachmentEntry, thumbnail: NSImage?) {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Self.radius
        layer?.masksToBounds = false
        // AX: announce the pill as a clickable button so VO users can preview
        // / activate it the same way sighted users do via click.
        setAccessibilityRole(.button)
        setAccessibilityLabel(entry.displayName)
        setAccessibilityHelp("Click to preview, or press Delete to remove")
        applyBackground(hovered: false)

        // Thumbnail
        thumbView.translatesAutoresizingMaskIntoConstraints = false
        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.imageAlignment = .alignCenter
        thumbView.wantsLayer = true
        thumbView.layer?.cornerRadius = 6
        thumbView.layer?.masksToBounds = true
        thumbView.layer?.borderWidth = 0.5
        thumbView.layer?.borderColor = NSColor.separatorColor.cgColor
        if let thumb = thumbnail, entry.kind == .image || entry.kind == .pdf {
            thumbView.image = thumb
        } else {
            let icon = NSWorkspace.shared.icon(forFileType: URL(fileURLWithPath: entry.displayName).pathExtension)
            icon.size = NSSize(width: Self.thumbSize, height: Self.thumbSize)
            thumbView.image = icon
            // Don't outline the system file-type icons — they already render
            // their own card / drop-shadow.
            thumbView.layer?.borderWidth = 0
        }
        thumbView.alphaValue = isUnavailable ? 0.5 : 1.0

        // Name
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.stringValue = entry.displayName
        nameLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = isUnavailable ? .secondaryLabelColor : .labelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.cell?.truncatesLastVisibleLine = true
        nameLabel.maximumNumberOfLines = 1

        // Subtitle (status + size)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        let (statusText, statusColor) = statusInfo(for: entry, isUnavailable: isUnavailable)
        subtitleLabel.stringValue = subtitleText(for: entry, statusText: statusText, isUnavailable: isUnavailable)
        subtitleLabel.font = NSFont.systemFont(ofSize: 10.5)
        subtitleLabel.textColor = .tertiaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 1

        // Status dot (only when not ready — ready entries don't need the noise)
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3
        statusDot.layer?.backgroundColor = statusColor.cgColor
        statusDot.isHidden = (entry.descriptionStatus == .ready && !isUnavailable)

        // Remove button (hover-only)
        configureRemoveButton()

        // Layout
        let textStack = NSStackView(views: [nameLabel, subtitleRow()])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(thumbView)
        addSubview(textStack)
        addSubview(removeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            // Floor on the pill width — without this, when the name+subtitle
            // both fit in well under nameMaxWidth, the trailing `≤` lets the
            // pill collapse to a thumbnail-only stub.
            widthAnchor.constraint(greaterThanOrEqualToConstant: 140),

            thumbView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.paddingX),
            thumbView.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbView.widthAnchor.constraint(equalToConstant: Self.thumbSize),
            thumbView.heightAnchor.constraint(equalToConstant: Self.thumbSize),

            textStack.leadingAnchor.constraint(equalTo: thumbView.trailingAnchor, constant: 10),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.paddingX),

            nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Self.nameMaxWidth),

            removeButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            removeButton.widthAnchor.constraint(equalToConstant: 18),
            removeButton.heightAnchor.constraint(equalToConstant: 18),
        ])

        toolTip = isUnavailable
            ? "File unavailable — volume may not be mounted"
            : (entry.description.isEmpty ? entry.displayName : entry.description)
    }

    private func subtitleRow() -> NSView {
        let row = NSStackView(views: [statusDot, subtitleLabel])
        row.orientation = .horizontal
        row.spacing = 5
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 6),
            statusDot.heightAnchor.constraint(equalToConstant: 6),
        ])
        return row
    }

    private func subtitleText(for entry: AttachmentEntry, statusText: String, isUnavailable: Bool) -> String {
        if isUnavailable { return "File unavailable" }
        let size = byteSizeString(entry.byteSize)
        if let statusText = statusText.nonEmpty {
            return "\(statusText) · \(size)"
        }
        return size
    }

    private func statusInfo(for entry: AttachmentEntry, isUnavailable: Bool) -> (String, NSColor) {
        if isUnavailable { return ("", .secondaryLabelColor) }
        switch entry.descriptionStatus {
        case .ready: return ("", .systemGreen)
        case .pending: return ("Describing…", .systemYellow)
        case .failed: return ("Description failed", .systemOrange)
        }
    }

    private func byteSizeString(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    private func configureRemoveButton() {
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.bezelStyle = .circular
        removeButton.isBordered = false
        removeButton.title = ""
        let symbol = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove")
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        removeButton.image = symbol?.withSymbolConfiguration(cfg)
        removeButton.imageScaling = .scaleProportionallyUpOrDown
        removeButton.contentTintColor = NSColor.labelColor.withAlphaComponent(0.7)
        removeButton.target = self
        removeButton.action = #selector(handleRemoveTap)
        removeButton.toolTip = "Remove"
        // Hidden (not just alpha=0) so the button doesn't swallow clicks in
        // its 18×18 corner footprint while invisible.
        removeButton.isHidden = true
    }

    private func applyBackground(hovered: Bool) {
        let baseColor: NSColor = isUnavailable
            ? NSColor.secondaryLabelColor.withAlphaComponent(0.10)
            : NSColor.controlBackgroundColor.withAlphaComponent(hovered ? 0.95 : 0.75)
        layer?.backgroundColor = baseColor.cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = (hovered
            ? NSColor.controlAccentColor.withAlphaComponent(0.55)
            : NSColor.separatorColor
        ).cgColor
        if hovered {
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.18
            layer?.shadowRadius = 4
            layer?.shadowOffset = CGSize(width: 0, height: -1)
        } else {
            layer?.shadowOpacity = 0
        }
    }

    @objc private func handleRemoveTap() {
        onRemove(entryID)
    }

    override func mouseDown(with event: NSEvent) {
        // NSButton hit-tests first when visible, so this only fires for clicks
        // outside the (hover-revealed) remove button.
        onClick(entryID)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        removeButton.isHidden = false
        removeButton.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.allowsImplicitAnimation = true
            applyBackground(hovered: true)
            removeButton.animator().alphaValue = 1
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.allowsImplicitAnimation = true
            applyBackground(hovered: false)
            removeButton.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // Re-hide only if we didn't get a fresh mouseEntered in the meantime.
            guard let self, !self.hovered else { return }
            self.removeButton.isHidden = true
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Add files pill

/// Trailing pill in the populated strip — a "+" affordance that opens a file
/// picker. Mirrors PillView's height/corner radius for visual consistency.
private final class AddFilesPillView: NSView {
    private let onClick: () -> Void
    private let iconView = NSImageView()
    private var trackingArea: NSTrackingArea?

    private static let height: CGFloat = 60
    private static let width: CGFloat = 60
    private static let radius: CGFloat = 12

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Self.radius
        setAccessibilityRole(.button)
        setAccessibilityLabel("Add files")
        toolTip = "Add files…"
        applyBackground(hovered: false)

        let symbol = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add files")
        let cfg = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        iconView.image = symbol?.withSymbolConfiguration(cfg)
        iconView.contentTintColor = NSColor.secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            widthAnchor.constraint(equalToConstant: Self.width),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func applyBackground(hovered: Bool) {
        layer?.backgroundColor = NSColor.controlBackgroundColor
            .withAlphaComponent(hovered ? 0.6 : 0.4).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = (hovered
            ? NSColor.controlAccentColor.withAlphaComponent(0.55)
            : NSColor.separatorColor.withAlphaComponent(0.6)
        ).cgColor
        iconView.contentTintColor = hovered ? .labelColor : .secondaryLabelColor
    }

    override func mouseDown(with event: NSEvent) {
        onClick()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.allowsImplicitAnimation = true
            applyBackground(hovered: true)
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.allowsImplicitAnimation = true
            applyBackground(hovered: false)
        }
    }
}
