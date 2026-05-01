import AppKit
import Foundation

final class BatchClipboardHistoryDogfood {
    private enum DogfoodError: LocalizedError {
        case noCapturedItems
        case noAllowedHandles
        case modelSelectedNoItems
        case missingRuntimePayload(handle: String)
        case missingPayloadFile(handle: String, path: String)
        case byteSizeMismatch(handle: String, path: String, expected: Int, actual: Int)
        case emptyPasteboardRepresentations(handle: String)

        var errorDescription: String? {
            switch self {
            case .noCapturedItems:
                return "no clipboard history captured yet"
            case .noAllowedHandles:
                return "clipboard history did not produce any selectable handles"
            case .modelSelectedNoItems:
                return "model selected no clipboard items"
            case .missingRuntimePayload(let handle):
                return "missing runtime payload for \(handle)"
            case .missingPayloadFile(let handle, let path):
                return "\(handle) payload file is missing: \(path)"
            case .byteSizeMismatch(let handle, let path, let expected, let actual):
                return "\(handle) payload byte size mismatch for \(path): expected \(expected), got \(actual)"
            case .emptyPasteboardRepresentations(let handle):
                return "\(handle) had no pasteable representations"
            }
        }
    }

    private struct SelectionOutput: Encodable {
        var selectedHandles: [String]
        var pasteHandles: [String]

        enum CodingKeys: String, CodingKey {
            case selectedHandles = "selected_handles"
            case pasteHandles = "paste_handles"
        }
    }

    private struct TargetFiles {
        var targetPNG: URL
        var modelTargetPNG: URL?
        var targetMetadataJSON: URL
        var caretJSON: URL
        var geometryJSON: URL
        var targetPacketText: URL
        var targetPacketBuildJSON: URL
        var targetProbeJSON: URL
        var annotatedTargetPNG: URL?
        var targetMode: String
        var targetMetadata: TargetMetadata
    }

    private struct TargetProbeSummary: Encodable {
        var status: String
        var changeCountChanged: Bool
        var itemCount: Int
        var types: [String]
        var htmlBytes: Int
        var plainTextBytes: Int
        var stringPreview: String?

        enum CodingKeys: String, CodingKey {
            case status
            case changeCountChanged = "change_count_changed"
            case itemCount = "item_count"
            case types
            case htmlBytes = "html_bytes"
            case plainTextBytes = "plain_text_bytes"
            case stringPreview = "string_preview"
        }
    }

    private struct SavedPasteboardItem {
        let types: [NSPasteboard.PasteboardType]
        let data: [NSPasteboard.PasteboardType: Data]
    }

    private let config: Config
    private let pasteboard = NSPasteboard.general
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "blink.batch-clipboard-history", qos: .userInitiated)
    private let historyLimit: Int
    private let workDir: URL
    private let htmlPreviewDir: URL
    private let runsDir: URL
    private let snapshotWriter: PasteboardSnapshotWriter

    private var timer: DispatchSourceTimer?
    private var snapshots: [SnapshotSummary] = []
    private var lastChangeCount: Int
    private var captureSuppressed = false
    private var resetOnNextUserCapture = false

    var onStatusChange: ((String) -> Void)?
    var onFailureNotice: ((String, String) -> Void)?

    init(
        config: Config,
        historyLimit: Int = 20,
        workDir: URL = Paths.appSupportDir.appendingPathComponent("batch-clipboard-history", isDirectory: true)
    ) {
        self.config = config
        self.historyLimit = historyLimit
        self.workDir = workDir
        self.htmlPreviewDir = workDir.appendingPathComponent("html-preview", isDirectory: true)
        self.runsDir = workDir.appendingPathComponent("runs", isDirectory: true)
        self.snapshotWriter = PasteboardSnapshotWriter(outDir: htmlPreviewDir)
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            do {
                try fileManager.createDirectory(at: htmlPreviewDir, withIntermediateDirectories: true)
                try fileManager.createDirectory(at: runsDir, withIntermediateDirectories: true)
                lastChangeCount = pasteboard.changeCount
            } catch {
                reportFailure(title: "Batch History Failed", error: error)
            }

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
            timer.setEventHandler { [weak self] in
                self?.captureIfChanged()
            }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    func runPasteAll() {
        queue.async { [self] in
            do {
                status("batch paste: preparing history")
                try captureCurrentPasteboard(force: false)

                guard snapshots.contains(where: { !$0.isConcealed }) else {
                    throw DogfoodError.noCapturedItems
                }

                let runDir = runsDir.appendingPathComponent(Self.timestamp(), isDirectory: true)
                let replayDir = runDir.appendingPathComponent("replay", isDirectory: true)
                try fileManager.createDirectory(at: runDir, withIntermediateDirectories: true)
                let targetFiles = try captureTargetFiles(in: runDir)

                let assembler = BatchClipboardHistoryAssembler(
                    inputDirectory: htmlPreviewDir,
                    replayOutputDirectory: replayDir
                )
                let pair = try assembler.build(
                    goal: "paste all",
                    snapshots: snapshots,
                    historyLimit: historyLimit
                )
                guard !pair.model.allowedHandles.isEmpty else {
                    throw DogfoodError.noAllowedHandles
                }

                let fullURL = runDir.appendingPathComponent("batch-request.full.json")
                let modelURL = runDir.appendingPathComponent("batch-request.model.json")
                let rawURL = runDir.appendingPathComponent("model-output.raw.txt")
                let parsedURL = runDir.appendingPathComponent("model-output.json")
                let resolvedURL = runDir.appendingPathComponent("resolved-selection.json")

                try writeJSON(pair.full, to: fullURL)
                try writeJSON(pair.model, to: modelURL)

                status("batch paste: selecting \(pair.model.items.count) item(s)")
                let raw = try PythonRunner.runBatchModelSelectSync(
                    config: config,
                    requestJSON: modelURL,
                    settingsJSON: Paths.settingsPath,
                    rawOutput: rawURL,
                    targetPNG: targetFiles.targetPNG,
                    modelTargetPNG: targetFiles.modelTargetPNG,
                    targetMetadataJSON: targetFiles.targetMetadataJSON,
                    geometryJSON: targetFiles.geometryJSON,
                    targetPacketOutput: targetFiles.targetPacketText,
                    targetBuildOutput: targetFiles.targetPacketBuildJSON,
                    requestOutput: modelURL
                )
                let selectedHandles = try parseAndValidateSelection(raw, allowedHandles: pair.model.allowedHandles)
                let pasteHandles = pasteHandlesForSelectedHandles(
                    selectedHandles,
                    fullRequest: pair.full,
                    preferRichHTMLParents: shouldPreferRichHTMLSourcePayloads(
                        targetMetadata: targetFiles.targetMetadata,
                        targetMode: targetFiles.targetMode
                    )
                )
                try writeJSON(
                    SelectionOutput(selectedHandles: selectedHandles, pasteHandles: pasteHandles),
                    to: parsedURL
                )
                if pasteHandles != selectedHandles {
                    NSLog(
                        "[blink] batch paste remapped selected handles %@ to paste handles %@",
                        selectedHandles.joined(separator: ","),
                        pasteHandles.joined(separator: ",")
                    )
                }

                let resolved = resolveSelection(selectedHandles: pasteHandles, fullRequest: pair.full)
                try writeJSON(resolved, to: resolvedURL)

                guard !pasteHandles.isEmpty else {
                    throw DogfoodError.modelSelectedNoItems
                }

                let payloadItems = try materializePayloadItems(
                    selectedHandles: pasteHandles,
                    fullRequest: pair.full
                )

                status("batch paste: inserting \(payloadItems.count) item(s)")
                captureSuppressed = true
                Inserter.insert(payloadItems: payloadItems) { [weak self] result in
                    guard let self else { return }
                    self.queue.async {
                        self.captureSuppressed = false
                        self.lastChangeCount = self.pasteboard.changeCount
                        switch result {
                        case .success:
                            self.resetOnNextUserCapture = true
                            self.status("batch paste complete: \(pasteHandles.joined(separator: ", "))")
                            self.notify(
                                title: "Batch paste complete",
                                detail: pasteHandles == selectedHandles
                                    ? "Selected \(selectedHandles.joined(separator: ", "))"
                                    : "Selected \(selectedHandles.joined(separator: ", ")); pasted \(pasteHandles.joined(separator: ", "))",
                                sound: .success
                            )
                        case .failure(let error):
                            self.reportFailure(title: "Batch Paste Failed", error: error)
                        }
                    }
                }
            } catch {
                reportFailure(title: "Batch Paste Failed", error: error)
            }
        }
    }

    private func captureIfChanged() {
        do {
            try captureCurrentPasteboard(force: false)
        } catch {
            NSLog("[blink] batch clipboard capture failed: %@", error.localizedDescription)
        }
    }

    private func captureCurrentPasteboard(force: Bool) throws {
        let changeCount = pasteboard.changeCount
        if captureSuppressed {
            lastChangeCount = changeCount
            return
        }
        guard force || changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        if resetOnNextUserCapture {
            snapshots.removeAll()
            resetOnNextUserCapture = false
        }

        let snapshot = try snapshotWriter.writeSnapshot(from: pasteboard)
        snapshots.append(snapshot)
        if snapshots.count > historyLimit * 2 {
            snapshots.removeFirst(snapshots.count - historyLimit * 2)
        }
        NSLog("[blink] batch clipboard captured cc=%d kind=%@ preview=%@", snapshot.changeCount, snapshot.renderedKind, snapshot.preview)
    }

    private func materializePayloadItems(
        selectedHandles: [String],
        fullRequest: BatchFullRequest
    ) throws -> [Inserter.PayloadItem] {
        let htmlPreviewBase = URL(fileURLWithPath: fullRequest.pathBases.htmlPreview, isDirectory: true)
        let replayOutputBase = URL(fileURLWithPath: fullRequest.pathBases.replayOutput, isDirectory: true)

        return try selectedHandles.map { handle in
            guard let payloads = fullRequest.runtimePayloads[handle], !payloads.isEmpty else {
                throw DogfoodError.missingRuntimePayload(handle: handle)
            }

            let representations: [Inserter.PayloadRepresentation] = try payloads.map { payload in
                let base = payload.rawPath.hasPrefix("derived-payloads/") ? replayOutputBase : htmlPreviewBase
                let rawURL = base.appendingPathComponent(payload.rawPath)
                guard fileManager.fileExists(atPath: rawURL.path) else {
                    throw DogfoodError.missingPayloadFile(handle: handle, path: rawURL.path)
                }
                let data = try Data(contentsOf: rawURL)
                guard data.count == payload.byteSize else {
                    throw DogfoodError.byteSizeMismatch(
                        handle: handle,
                        path: rawURL.path,
                        expected: payload.byteSize,
                        actual: data.count
                    )
                }
                return Inserter.PayloadRepresentation(
                    type: NSPasteboard.PasteboardType(rawValue: payload.uti),
                    data: data
                )
            }

            guard !representations.isEmpty else {
                throw DogfoodError.emptyPasteboardRepresentations(handle: handle)
            }
            return Inserter.PayloadItem(handle: handle, representations: representations)
        }
    }

    private func captureTargetFiles(in runDir: URL) throws -> TargetFiles {
        status("batch paste: parsing target")
        let metadata = TargetMetadataCapture.capture()
        let caret = TargetMetadataCapture.captureCaret()
        let targetCapture = try ScreenCapture.captureFrontmostWindowSync(
            preferredGlobalRect: metadata.focusedBounds
        )
        let geometry = geometryPayload(for: targetCapture, metadata: metadata)
        let targetMode = targetMode(metadata: metadata, geometry: geometry)

        let targetPNG = runDir.appendingPathComponent("target.png")
        let annotatedTargetPNG = runDir.appendingPathComponent("target_annotated.png")
        let targetMetadataJSON = runDir.appendingPathComponent("target_metadata.json")
        let caretJSON = runDir.appendingPathComponent("caret.json")
        let geometryJSON = runDir.appendingPathComponent("geometry.json")
        let targetPacketText = runDir.appendingPathComponent("target_ocr_packet.txt")
        let targetPacketBuildJSON = runDir.appendingPathComponent("target_ocr_packet.build.json")
        let targetProbeJSON = runDir.appendingPathComponent("target_copy_probe.json")

        try targetCapture.pngData.write(to: targetPNG, options: .atomic)
        let probe = targetMode == "document_canvas" ? suppressedTargetCopyProbe() : nil
        let annotation = targetMode == "document_canvas"
            ? try annotateTargetCapture(targetCapture, metadata: metadata, geometry: geometry, output: annotatedTargetPNG)
            : nil
        var metadataDict = metadata.asDictionary()
        metadataDict["target_mode"] = targetMode
        if let probe {
            metadataDict["target_copy_probe"] = encodeDictionary(probe)
            try writeJSON(probe, to: targetProbeJSON)
        } else {
            try writeJSON(["status": "not_run"], to: targetProbeJSON)
        }
        if let annotation {
            metadataDict["annotation_metadata"] = annotation
        }
        try ArtifactWriter.writeJSON(metadataDict, to: targetMetadataJSON)
        try ArtifactWriter.writeJSON(caret, to: caretJSON)
        var geometryWithAnnotation = geometry
        if let annotation {
            geometryWithAnnotation["annotation_metadata"] = annotation
        }
        try ArtifactWriter.writeJSON(geometryWithAnnotation, to: geometryJSON)

        return TargetFiles(
            targetPNG: targetPNG,
            modelTargetPNG: annotation == nil ? nil : annotatedTargetPNG,
            targetMetadataJSON: targetMetadataJSON,
            caretJSON: caretJSON,
            geometryJSON: geometryJSON,
            targetPacketText: targetPacketText,
            targetPacketBuildJSON: targetPacketBuildJSON,
            targetProbeJSON: targetProbeJSON,
            annotatedTargetPNG: annotation == nil ? nil : annotatedTargetPNG,
            targetMode: targetMode,
            targetMetadata: metadata
        )
    }

    private func pasteHandlesForSelectedHandles(
        _ selectedHandles: [String],
        fullRequest: BatchFullRequest,
        preferRichHTMLParents: Bool
    ) -> [String] {
        guard preferRichHTMLParents else {
            return selectedHandles
        }

        var itemsByHandle: [String: BatchModelItem] = [:]
        for item in fullRequest.items {
            itemsByHandle[item.handle] = item
        }

        var pasteHandles: [String] = []
        var seen = Set<String>()
        for handle in selectedHandles {
            let pasteHandle = richHTMLParentHandle(for: handle, itemsByHandle: itemsByHandle, fullRequest: fullRequest) ?? handle
            guard !seen.contains(pasteHandle) else { continue }
            seen.insert(pasteHandle)
            pasteHandles.append(pasteHandle)
        }
        return pasteHandles
    }

    private func richHTMLParentHandle(
        for handle: String,
        itemsByHandle: [String: BatchModelItem],
        fullRequest: BatchFullRequest
    ) -> String? {
        guard let item = itemsByHandle[handle],
              item.derivedKind == "embedded_html_image",
              let parentHandle = item.derivedFrom,
              let parentPayloads = fullRequest.runtimePayloads[parentHandle],
              parentPayloads.contains(where: { $0.uti == "public.html" })
        else {
            return nil
        }
        return parentHandle
    }

    private func shouldPreferRichHTMLSourcePayloads(targetMetadata: TargetMetadata, targetMode: String) -> Bool {
        if targetMode == "document_canvas" {
            return true
        }
        let fields = [
            targetMetadata.frontmostApp,
            targetMetadata.frontmostWindowTitle,
            targetMetadata.focusedApp,
            targetMetadata.focusedAppBundleId,
            targetMetadata.focusedRole,
            targetMetadata.focusedTitle,
            targetMetadata.focusedDescription,
            targetMetadata.focusedLabel,
        ]
        let joined = fields.compactMap { $0?.lowercased() }.joined(separator: " ")

        return joined.contains("google slides")
            || joined.contains("document content")
    }

    private func targetMode(metadata: TargetMetadata, geometry: [String: Any]) -> String {
        let label = normalized(metadata.focusedLabel)
        let description = normalized(metadata.focusedDescription)
        guard label == "document content" || description == "document content" else {
            return "strict_field"
        }
        guard let focused = geometry["focused_bounds_points"] as? [String: Any] else {
            return "strict_field"
        }
        let width = doubleValue(focused["width"]) ?? 0
        let height = doubleValue(focused["height"]) ?? 0
        return width <= 2 || height <= 2 ? "document_canvas" : "strict_field"
    }

    private func suppressedTargetCopyProbe() -> TargetProbeSummary {
        let savedItems = snapshotPasteboard()
        let originalChangeCount = pasteboard.changeCount
        captureSuppressed = true
        defer {
            restorePasteboard(savedItems)
            lastChangeCount = pasteboard.changeCount
            captureSuppressed = false
        }

        do {
            try synthesizeCmdC()
        } catch {
            return TargetProbeSummary(
                status: "copy_failed:\(error.localizedDescription)",
                changeCountChanged: false,
                itemCount: 0,
                types: [],
                htmlBytes: 0,
                plainTextBytes: 0,
                stringPreview: nil
            )
        }

        let deadline = Date().addingTimeInterval(0.6)
        while pasteboard.changeCount == originalChangeCount && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let changed = pasteboard.changeCount != originalChangeCount
        guard changed else {
            return TargetProbeSummary(
                status: "empty",
                changeCountChanged: false,
                itemCount: 0,
                types: [],
                htmlBytes: 0,
                plainTextBytes: 0,
                stringPreview: nil
            )
        }

        let types = pasteboard.types?.map(\.rawValue) ?? []
        let htmlBytes = pasteboard.data(forType: NSPasteboard.PasteboardType(rawValue: "public.html"))?.count ?? 0
        let plainText = pasteboard.string(forType: .string)
        return TargetProbeSummary(
            status: "ok",
            changeCountChanged: true,
            itemCount: pasteboard.pasteboardItems?.count ?? 0,
            types: types,
            htmlBytes: htmlBytes,
            plainTextBytes: plainText?.utf8.count ?? 0,
            stringPreview: plainText.map { String($0.prefix(180)) }
        )
    }

    private func annotateTargetCapture(
        _ capture: ScreenCapture.Capture,
        metadata: TargetMetadata,
        geometry: [String: Any],
        output: URL
    ) throws -> [String: Any]? {
        guard let baseImage = NSImage(data: capture.pngData),
              let focusedRect = localFocusedRectPixels(
            metadata: metadata,
            geometry: geometry,
            imageSize: baseImage.size
        ) else {
            return nil
        }
        let image = NSImage(size: baseImage.size)
        image.lockFocus()
        baseImage.draw(in: NSRect(origin: .zero, size: baseImage.size))
        NSColor.systemRed.setStroke()
        let focusPath = NSBezierPath(rect: focusedRect)
        focusPath.lineWidth = 6
        focusPath.stroke()

        let canvasRect = focusedRect.insetBy(dx: -180, dy: -140).intersection(
            NSRect(origin: .zero, size: baseImage.size)
        )
        NSColor.systemBlue.withAlphaComponent(0.9).setStroke()
        let canvasPath = NSBezierPath(rect: canvasRect)
        canvasPath.lineWidth = 4
        canvasPath.stroke()
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        try data.write(to: output, options: .atomic)
        return [
            "source": "swift_focus_line_canvas_region",
            "annotated_target": output.lastPathComponent,
            "focus_rect_pixels": rectDictionary(focusedRect),
            "canvas_region_pixels": rectDictionary(canvasRect),
        ]
    }

    private func geometryPayload(
        for capture: ScreenCapture.Capture,
        metadata: TargetMetadata
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "status": "ok",
            "window_bounds_points": [
                "x": capture.windowFramePoints.origin.x,
                "y": capture.windowFramePoints.origin.y,
                "width": capture.windowFramePoints.size.width,
                "height": capture.windowFramePoints.size.height,
            ],
        ]
        if let focusedBounds = metadata.focusedBounds {
            payload["focused_bounds_points"] = [
                "x": focusedBounds.origin.x,
                "y": focusedBounds.origin.y,
                "width": focusedBounds.size.width,
                "height": focusedBounds.size.height,
            ]
        }
        return payload
    }

    private func localFocusedRectPixels(
        metadata: TargetMetadata,
        geometry: [String: Any],
        imageSize: NSSize
    ) -> NSRect? {
        guard let window = geometry["window_bounds_points"] as? [String: Any],
              let focused = geometry["focused_bounds_points"] as? [String: Any],
              let wx = doubleValue(window["x"]),
              let wy = doubleValue(window["y"]),
              let ww = doubleValue(window["width"]),
              let wh = doubleValue(window["height"]),
              let fx = doubleValue(focused["x"]),
              let fy = doubleValue(focused["y"]),
              let fw = doubleValue(focused["width"]),
              let fh = doubleValue(focused["height"]),
              ww > 0,
              wh > 0,
              fw > 0
        else {
            return nil
        }
        let imageWidth = max(1.0, Double(imageSize.width))
        let imageHeight = max(1.0, Double(imageSize.height))
        let x = ((fx - wx) / ww) * imageWidth
        let y = ((fy - wy) / wh) * imageHeight
        let width = max((fw / ww) * imageWidth, 3)
        let height = max((max(fh, 1) / wh) * imageHeight, 24)
        return NSRect(
            x: max(0, min(imageWidth - 1, x)),
            y: max(0, min(imageHeight - 1, y)),
            width: min(width, imageWidth),
            height: min(height, imageHeight)
        )
    }

    private func snapshotPasteboard() -> [SavedPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var data: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                data[type] = item.data(forType: type)
            }
            return SavedPasteboardItem(types: item.types, data: data)
        }
    }

    private func restorePasteboard(_ items: [SavedPasteboardItem]) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { saved in
            let item = NSPasteboardItem()
            for type in saved.types {
                if let data = saved.data[type] {
                    item.setData(data, forType: type)
                }
            }
            return item
        }
        pasteboard.writeObjects(restored)
    }

    private func synthesizeCmdC() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false) else {
            throw DogfoodError.noCapturedItems
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

    private func normalized(_ value: String?) -> String {
        (value ?? "")
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? CGFloat { return Double(value) }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private func rectDictionary(_ rect: NSRect) -> [String: Double] {
        [
            "x": rect.origin.x,
            "y": rect.origin.y,
            "width": rect.size.width,
            "height": rect.size.height,
        ]
    }

    private func encodeDictionary<T: Encodable>(_ value: T) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func status(_ text: String) {
        onStatusChange?(text)
        NSLog("[blink] %@", text)
    }

    private func reportFailure(title: String, error: Error) {
        let detail = detailedErrorMessage(error)
        status("\(title.lowercased()): \(shortErrorSummary(error))")
        notify(title: title, detail: shortErrorSummary(error), sound: .failure, duration: 2.6)
        DispatchQueue.main.async {
            self.onFailureNotice?(title, detail)
        }
    }

    private func notify(
        title: String,
        detail: String? = nil,
        sound: FeedbackSound = .none,
        duration: TimeInterval = 1.8
    ) {
        DispatchQueue.main.async {
            FeedbackCenter.shared.post(
                title: title,
                detail: detail,
                sound: sound,
                duration: duration
            )
        }
    }

    private func shortErrorSummary(_ error: Error) -> String {
        if let runError = error as? PythonRunner.RunError {
            switch runError {
            case .nonZeroExit(let status, let stderr):
                let summary = summarizedMultiline(stderr)
                return summary.isEmpty ? "python exited \(status)" : "python exited \(status): \(summary)"
            default:
                return runError.localizedDescription
            }
        }
        return error.localizedDescription
    }

    private func detailedErrorMessage(_ error: Error) -> String {
        if let runError = error as? PythonRunner.RunError {
            switch runError {
            case .nonZeroExit(let status, let stderr):
                let detail = summarizedMultiline(stderr, maxLines: 16, maxChars: 1600)
                return detail.isEmpty
                    ? "Python exited with status \(status)."
                    : "Python exited with status \(status).\n\n\(detail)"
            default:
                return runError.localizedDescription
            }
        }
        return error.localizedDescription
    }

    private func summarizedMultiline(
        _ text: String,
        maxLines: Int = 8,
        maxChars: Int = 480
    ) -> String {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return "" }
        let tail = lines.suffix(maxLines).joined(separator: "\n")
        if tail.count <= maxChars {
            return tail
        }
        let endIndex = tail.index(tail.startIndex, offsetBy: maxChars)
        return String(tail[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date())
    }
}
