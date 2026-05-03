import AppKit
import Foundation

final class BatchClipboardHistoryDogfood {
    private enum DogfoodError: LocalizedError {
        case noCapturedItems
        case noAllowedHandles
        case modelSelectedNoItems
        case missingRuntimePayload(handle: String)
        case missingPayloadFile(handle: String, path: String)
        case missingSyntheticHandle(itemIndex: Int)
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
            case .missingSyntheticHandle(let itemIndex):
                return "missing synthetic handle for generated text item at index \(itemIndex)"
            case .byteSizeMismatch(let handle, let path, let expected, let actual):
                return "\(handle) payload byte size mismatch for \(path): expected \(expected), got \(actual)"
            case .emptyPasteboardRepresentations(let handle):
                return "\(handle) had no pasteable representations"
            }
        }
    }

    private struct SelectionOutput: Encodable {
        var selectedHandles: [String]
        var pasteItems: [BatchPastePlanItem]
        var generatedTextCharCountByHandle: [String: Int]
        var totalGeneratedTextChars: Int
        var pasteHandles: [String]

        enum CodingKeys: String, CodingKey {
            case selectedHandles = "selected_handles"
            case pasteItems = "paste_items"
            case generatedTextCharCountByHandle = "generated_text_char_count_by_handle"
            case totalGeneratedTextChars = "total_generated_text_chars"
            case pasteHandles = "paste_handles"
        }
    }

    private struct TargetFiles {
        var targetPNG: URL
        var modelTargetImage: URL?
        var targetMetadataJSON: URL
        var caretJSON: URL
        var geometryJSON: URL
        var targetPacketText: URL
        var targetPacketBuildJSON: URL
        var targetProbeJSON: URL
        var annotatedTargetImage: URL?
        var targetMode: String
        var targetMetadata: TargetMetadata
    }

    private struct ModelImageSettings {
        var maxDimension: Int
        var jpegQuality: CGFloat
    }

    private struct TargetProbeSummary: Encodable {
        var status: String
        var changeCountChanged: Bool
        var itemCount: Int
        var types: [String]
        var htmlBytes: Int
        var plainTextBytes: Int
        var stringPreview: String?
        var elapsedMS: Double
        var timeoutMS: Double
        var pollCount: Int
        var timedOut: Bool

        enum CodingKeys: String, CodingKey {
            case status
            case changeCountChanged = "change_count_changed"
            case itemCount = "item_count"
            case types
            case htmlBytes = "html_bytes"
            case plainTextBytes = "plain_text_bytes"
            case stringPreview = "string_preview"
            case elapsedMS = "elapsed_ms"
            case timeoutMS = "timeout_ms"
            case pollCount = "poll_count"
            case timedOut = "timed_out"
        }
    }

    private struct PreparedBatchCacheEntry {
        var key: String
        var pair: BatchRequestPair
        var replayDir: URL
        var buildDurationMS: Double
        var snapshotIDs: [String]
    }

    private struct SavedPasteboardItem {
        let types: [NSPasteboard.PasteboardType]
        let data: [NSPasteboard.PasteboardType: Data]
    }

    private struct TimingReport: Encodable {
        var schemaVersion: Int
        var status: String
        var startedAt: String
        var completedAt: String?
        var totalElapsedMS: Double?
        var timeToCmdVMS: Double?
        var timeToFirstCmdVMS: Double?
        var timeToFinalCmdVMS: Double?
        var cmdVElapsedMS: Double?
        var events: [TimingEvent]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case status
            case startedAt = "started_at"
            case completedAt = "completed_at"
            case totalElapsedMS = "total_elapsed_ms"
            case timeToCmdVMS = "time_to_cmd_v_ms"
            case timeToFirstCmdVMS = "time_to_first_cmd_v_ms"
            case timeToFinalCmdVMS = "time_to_final_cmd_v_ms"
            case cmdVElapsedMS = "cmd_v_elapsed_ms"
            case events
        }
    }

    private struct TimingEvent: Encodable {
        var name: String
        var elapsedMS: Double
        var deltaMS: Double
        var details: [String: String]

        enum CodingKeys: String, CodingKey {
            case name
            case elapsedMS = "elapsed_ms"
            case deltaMS = "delta_ms"
            case details
        }
    }

    private final class TimingRecorder {
        private let lock = NSLock()
        private let startedAtDate = Date()
        private let startedAtUptime = ProcessInfo.processInfo.systemUptime
        private var lastEventUptime: TimeInterval
        private var status = "running"
        private var completedAtDate: Date?
        private var events: [TimingEvent] = []

        init() {
            self.lastEventUptime = startedAtUptime
            mark("run_started")
        }

        func mark(_ name: String, details: [String: Any] = [:]) {
            let now = ProcessInfo.processInfo.systemUptime
            let event = TimingEvent(
                name: name,
                elapsedMS: roundedMS(now - startedAtUptime),
                deltaMS: roundedMS(now - lastEventUptime),
                details: details.mapValues { String(describing: $0) }
            )
            lock.lock()
            events.append(event)
            lastEventUptime = now
            lock.unlock()
        }

        func finish(status: String, details: [String: Any] = [:]) {
            mark("run_finished", details: ["status": status].merging(details.mapValues { String(describing: $0) }) { _, new in new })
            lock.lock()
            self.status = status
            self.completedAtDate = Date()
            lock.unlock()
        }

        func report() -> TimingReport {
            lock.lock()
            let snapshotStatus = status
            let snapshotCompletedAt = completedAtDate
            let snapshotEvents = events
            lock.unlock()

            return TimingReport(
                schemaVersion: 0,
                status: snapshotStatus,
                startedAt: Self.iso8601.string(from: startedAtDate),
                completedAt: snapshotCompletedAt.map { Self.iso8601.string(from: $0) },
                totalElapsedMS: snapshotCompletedAt.map { roundedMS($0.timeIntervalSince(startedAtDate)) },
                timeToCmdVMS: Self.lastElapsedMS(named: "inserter_cmd_v_posted", in: snapshotEvents),
                timeToFirstCmdVMS: Self.firstElapsedMS(named: "inserter_cmd_v_posted", in: snapshotEvents),
                timeToFinalCmdVMS: Self.lastElapsedMS(named: "inserter_cmd_v_posted", in: snapshotEvents),
                cmdVElapsedMS: Self.elapsedMS(
                    from: "insertion_started",
                    to: "inserter_cmd_v_posted",
                    in: snapshotEvents
                ),
                events: snapshotEvents
            )
        }

        private static func firstElapsedMS(named name: String, in events: [TimingEvent]) -> Double? {
            events.first { $0.name == name }?.elapsedMS
        }

        private static func lastElapsedMS(named name: String, in events: [TimingEvent]) -> Double? {
            events.last { $0.name == name }?.elapsedMS
        }

        private static func elapsedMS(from startName: String, to endName: String, in events: [TimingEvent]) -> Double? {
            guard let start = events.first(where: { $0.name == startName }),
                  let end = events.last(where: { $0.name == endName }),
                  end.elapsedMS >= start.elapsedMS else {
                return nil
            }
            return roundedMS((end.elapsedMS - start.elapsedMS) / 1000.0)
        }

        private static let iso8601: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
    }

    private let config: Config
    private let pasteboard = NSPasteboard.general
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "blink.batch-clipboard-history", qos: .userInitiated)
    private let historyLimit: Int
    private let workDir: URL
    private let htmlPreviewDir: URL
    private let runsDir: URL
    private let preparedReplayDir: URL
    private let imageTagCacheDir: URL
    private let snapshotWriter: PasteboardSnapshotWriter

    private var timer: DispatchSourceTimer?
    private var snapshots: [SnapshotSummary] = []
    private var lastChangeCount: Int
    private var captureSuppressed = false
    private var resetOnNextUserCapture = false
    private var preparedBatchCache: PreparedBatchCacheEntry?
    private var preparingBatchCacheKey: String?
    private var batchSelectorWorker: PythonRunner.WarmWorker?

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
        self.preparedReplayDir = workDir.appendingPathComponent("prepared-replay", isDirectory: true)
        self.imageTagCacheDir = workDir.appendingPathComponent("image-tags", isDirectory: true)
        self.snapshotWriter = PasteboardSnapshotWriter(outDir: htmlPreviewDir)
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            do {
                try fileManager.createDirectory(at: htmlPreviewDir, withIntermediateDirectories: true)
                try fileManager.createDirectory(at: runsDir, withIntermediateDirectories: true)
                try fileManager.createDirectory(at: preparedReplayDir, withIntermediateDirectories: true)
                try fileManager.createDirectory(at: imageTagCacheDir, withIntermediateDirectories: true)
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
            batchSelectorWorker?.discard()
            batchSelectorWorker = nil
        }
    }

    func runPasteAll() {
        let timings = TimingRecorder()
        queue.async { [self] in
            runPasteAllOnQueue(timings: timings)
        }
    }

    private func runPasteAllOnQueue(timings: TimingRecorder) {
            var timingsURL: URL?
            func persistTimings() {
                guard let timingsURL else { return }
                do {
                    try writeJSON(timings.report(), to: timingsURL)
                } catch {
                    NSLog("[blink] failed to write batch timings: %@", error.localizedDescription)
                }
            }

            do {
                status("batch paste: preparing history")
                try captureCurrentPasteboard(force: false)
                timings.mark(
                    "history_capture_checked",
                    details: [
                        "snapshot_count": snapshots.count,
                        "visible_snapshot_count": snapshots.filter { !$0.isConcealed }.count
                    ]
                )

                guard snapshots.contains(where: { !$0.isConcealed }) else {
                    throw DogfoodError.noCapturedItems
                }

                let runDir = runsDir.appendingPathComponent(Self.timestamp(), isDirectory: true)
                try fileManager.createDirectory(at: runDir, withIntermediateDirectories: true)
                timingsURL = runDir.appendingPathComponent("timings.json")
                timings.mark("run_directory_created", details: ["path": runDir.path])
                persistTimings()

                let targetFiles = try captureTargetFiles(in: runDir, timings: timings)
                persistTimings()

                let cacheLookup = preparedBatchForCurrentHistory(goal: "paste all")
                let pair: BatchRequestPair
                if let cacheLookup {
                    pair = cacheLookup.pair
                    timings.mark(
                        "batch_request_cache_hit",
                        details: [
                            "cache_key": cacheLookup.key,
                            "build_duration_ms": cacheLookup.buildDurationMS,
                            "snapshot_ids": cacheLookup.snapshotIDs.joined(separator: ",")
                        ]
                    )
                } else {
                    let replayDir = runDir.appendingPathComponent("replay", isDirectory: true)
                    let cacheKey = preparedBatchCacheKey(goal: "paste all", snapshots: visibleSnapshots())
                    timings.mark("batch_request_cache_miss", details: ["cache_key": cacheKey])
                    let assembler = BatchClipboardHistoryAssembler(
                        inputDirectory: htmlPreviewDir,
                        replayOutputDirectory: replayDir,
                        imageTagCacheDirectory: imageTagCacheDir
                    )
                    timings.mark("batch_request_assembly_started")
                    let assemblyStarted = ProcessInfo.processInfo.systemUptime
                    pair = try assembler.build(
                        goal: "paste all",
                        snapshots: snapshots,
                        historyLimit: historyLimit
                    )
                    timings.mark(
                        "batch_request_assembly_inline_done",
                        details: ["build_duration_ms": roundedMS(ProcessInfo.processInfo.systemUptime - assemblyStarted)]
                    )
                }
                timings.mark(
                    "batch_request_assembly_done",
                    details: [
                        "model_item_count": pair.model.items.count,
                        "allowed_handle_count": pair.model.allowedHandles.count,
                        "snapshot_count": pair.full.snapshots.count
                    ]
                )
                guard !pair.model.allowedHandles.isEmpty else {
                    throw DogfoodError.noAllowedHandles
                }

                let fullURL = runDir.appendingPathComponent("batch-request.full.json")
                let modelURL = runDir.appendingPathComponent("batch-request.model.json")
                let rawURL = runDir.appendingPathComponent("model-output.raw.txt")
                let parsedURL = runDir.appendingPathComponent("model-output.json")
                let resolvedURL = runDir.appendingPathComponent("resolved-selection.json")
                let selectorRunLogURL = runDir.appendingPathComponent("selector-run-log.json")

                try writeJSON(pair.full, to: fullURL)
                try writeJSON(pair.model, to: modelURL)
                timings.mark("batch_request_files_written")
                persistTimings()

                status("batch paste: selecting \(pair.model.items.count) item(s)")
                timings.mark(
                    "model_selection_started",
                    details: [
                        "model_item_count": pair.model.items.count,
                        "target_mode": targetFiles.targetMode,
                        "model_target_image_attached": targetFiles.modelTargetImage != nil,
                        "selector_warm_worker_available": batchSelectorWorker?.isAvailable ?? false
                    ]
                )
                let selectorWorker = batchSelectorWorker
                batchSelectorWorker = nil
                let selectorResult = try PythonRunner.runBatchModelSelectSync(
                    config: config,
                    requestJSON: modelURL,
                    settingsJSON: Paths.settingsPath,
                    rawOutput: rawURL,
                    targetPNG: targetFiles.targetPNG,
                    modelTargetPNG: targetFiles.modelTargetImage,
                    targetMetadataJSON: targetFiles.targetMetadataJSON,
                    geometryJSON: targetFiles.geometryJSON,
                    targetPacketOutput: targetFiles.targetPacketText,
                    targetBuildOutput: targetFiles.targetPacketBuildJSON,
                    requestOutput: modelURL,
                    runLogOutput: selectorRunLogURL,
                    warmWorker: selectorWorker
                )
                let raw = selectorResult.output
                var modelSelectionDetails: [String: Any] = [
                    "stdout_bytes": raw.utf8.count,
                    "selector_via_warm_worker": selectorResult.viaWarmWorker,
                ]
                if let workerReadyMS = selectorResult.workerReadyMS {
                    modelSelectionDetails["selector_worker_ready_ms"] = workerReadyMS
                }
                if let fallbackReason = selectorResult.fallbackReason, !fallbackReason.isEmpty {
                    modelSelectionDetails["selector_fallback_reason"] = fallbackReason
                }
                for (key, value) in selectorTimingSummary(from: selectorRunLogURL) {
                    modelSelectionDetails[key] = value
                }
                timings.mark("model_selection_done", details: modelSelectionDetails)
                let selectedItems = assignSyntheticTextHandles(
                    to: try parseAndValidateSelection(raw, allowedHandles: pair.model.allowedHandles)
                )
                let selectedHandles = selectedItems.compactMap(\.resolvedHandle)
                let pasteItems = pasteItemsForSelectedItems(
                    selectedItems,
                    fullRequest: pair.full,
                    preferRichHTMLParents: shouldPreferRichHTMLSourcePayloads(
                        targetMetadata: targetFiles.targetMetadata,
                        targetMode: targetFiles.targetMode
                    )
                )
                timings.mark(
                    "selection_parsed",
                    details: [
                        "selected_handles": selectedHandles.joined(separator: ","),
                        "paste_handles": pasteItems.compactMap(\.resolvedHandle).joined(separator: ","),
                        "generated_text_items": pasteItems.filter { $0.type == .text }.count
                    ]
                )
                let resolved = resolveSelection(selectedItems: pasteItems, fullRequest: pair.full)
                try writeJSON(
                    SelectionOutput(
                        selectedHandles: selectedHandles,
                        pasteItems: resolved.pasteItems,
                        generatedTextCharCountByHandle: resolved.generatedTextCharCountByHandle,
                        totalGeneratedTextChars: resolved.totalGeneratedTextChars,
                        pasteHandles: pasteItems.compactMap(\.resolvedHandle)
                    ),
                    to: parsedURL
                )
                if selectedItems != pasteItems {
                    NSLog(
                        "[blink] batch paste remapped selected items %@ to paste items %@",
                        String(describing: selectedItems),
                        String(describing: pasteItems)
                    )
                }

                let pasteHandles = pasteItems.compactMap(\.resolvedHandle)
                try writeJSON(resolved, to: resolvedURL)
                timings.mark(
                    "selection_resolved",
                    details: [
                        "resolved_item_count": resolved.items.count,
                        "generated_text_items": resolved.generatedTextCharCountByHandle.count,
                        "generated_text_chars": resolved.totalGeneratedTextChars,
                        "generated_text_char_count_by_handle": resolved.generatedTextCharCountByHandle
                            .sorted { lhs, rhs in lhs.key < rhs.key }
                            .map { "\($0.key)=\($0.value)" }
                            .joined(separator: ","),
                    ]
                )
                persistTimings()

                guard !pasteItems.isEmpty else {
                    throw DogfoodError.modelSelectedNoItems
                }

                timings.mark(
                    "payload_materialization_started",
                    details: [
                        "paste_handle_count": pasteHandles.count,
                        "generated_text_chars": resolved.totalGeneratedTextChars,
                    ]
                )
                let payloadItems = try materializePayloadItems(
                    selectedItems: pasteItems,
                    fullRequest: pair.full
                )
                timings.mark(
                    "payload_materialization_done",
                    details: [
                        "payload_item_count": payloadItems.count,
                        "representation_count": payloadItems.reduce(0) { $0 + $1.representations.count },
                        "byte_count": payloadItems.reduce(0) { total, item in
                            total + item.representations.reduce(0) { $0 + $1.data.count }
                        }
                    ]
                )
                persistTimings()

                status("batch paste: inserting \(payloadItems.count) item(s)")
                timings.mark("insertion_started", details: ["payload_item_count": payloadItems.count])
                captureSuppressed = true
                Inserter.insert(
                    payloadItems: payloadItems,
                    onTimingEvent: { event in
                        timings.mark(
                            event.name,
                            details: [
                                "handle": event.handle ?? "",
                                "item_index": event.itemIndex.map(String.init) ?? "",
                                "item_count": event.itemCount.map(String.init) ?? "",
                                "byte_count": event.byteCount.map(String.init) ?? ""
                            ].filter { !$0.value.isEmpty }
                        )
                    }
                ) { [weak self] result in
                    guard let self else { return }
                    self.queue.async {
                        self.captureSuppressed = false
                        self.lastChangeCount = self.pasteboard.changeCount
                        switch result {
                            case .success:
                            timings.finish(status: "success")
                            persistTimings()
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
                            timings.finish(status: "failure", details: ["error": self.shortErrorSummary(error)])
                            persistTimings()
                            self.reportFailure(title: "Batch Paste Failed", error: error)
                        }
                    }
                }
            } catch {
                timings.finish(status: "failure", details: ["error": shortErrorSummary(error)])
                persistTimings()
                reportFailure(title: "Batch Paste Failed", error: error)
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
        if !snapshot.isConcealed {
            refreshBatchSelectorWorker()
            prepareBatchRequestCache(goal: "paste all")
        }
    }

    private func refreshBatchSelectorWorker() {
        batchSelectorWorker?.discard()
        let started = ProcessInfo.processInfo.systemUptime
        batchSelectorWorker = PythonRunner.startBatchModelSelectWorker(config: config)
        if let worker = batchSelectorWorker {
            NSLog(
                "[blink] batch selector warm worker ready in %.2f ms",
                worker.readyElapsedMS ?? roundedMS(ProcessInfo.processInfo.systemUptime - started)
            )
        } else {
            NSLog("[blink] batch selector warm worker unavailable")
        }
    }

    private func prepareBatchRequestCache(goal: String) {
        let snapshotCopy = snapshots
        let visible = snapshotCopy.filter { !$0.isConcealed }
        guard !visible.isEmpty else { return }
        let key = preparedBatchCacheKey(goal: goal, snapshots: visible)
        if preparedBatchCache?.key == key || preparingBatchCacheKey == key {
            return
        }
        preparingBatchCacheKey = key
        let replayDir = preparedReplayDir.appendingPathComponent(key, isDirectory: true)
        let inputDirectory = htmlPreviewDir
        let historyLimit = historyLimit

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let assembler = BatchClipboardHistoryAssembler(
                    inputDirectory: inputDirectory,
                    replayOutputDirectory: replayDir,
                    imageTagCacheDirectory: self?.imageTagCacheDir
                )
                let pair = try assembler.build(
                    goal: goal,
                    snapshots: snapshotCopy,
                    historyLimit: historyLimit
                )
                let entry = PreparedBatchCacheEntry(
                    key: key,
                    pair: pair,
                    replayDir: replayDir,
                    buildDurationMS: roundedMS(ProcessInfo.processInfo.systemUptime - started),
                    snapshotIDs: visible.map(\.id)
                )
                self?.queue.async {
                    guard self?.preparingBatchCacheKey == key else { return }
                    self?.preparedBatchCache = entry
                    self?.preparingBatchCacheKey = nil
                    NSLog("[blink] prepared batch replay cache key=%@ in %.2f ms", key, entry.buildDurationMS)
                }
            } catch {
                self?.queue.async {
                    if self?.preparingBatchCacheKey == key {
                        self?.preparingBatchCacheKey = nil
                    }
                    NSLog("[blink] prepared batch replay cache failed key=%@: %@", key, error.localizedDescription)
                }
            }
        }
    }

    private func preparedBatchForCurrentHistory(goal: String) -> PreparedBatchCacheEntry? {
        let visible = visibleSnapshots()
        let key = preparedBatchCacheKey(goal: goal, snapshots: visible)
        guard let entry = preparedBatchCache, entry.key == key else {
            return nil
        }
        return entry
    }

    private func visibleSnapshots() -> [SnapshotSummary] {
        snapshots.filter { !$0.isConcealed }
    }

    private func preparedBatchCacheKey(goal: String, snapshots: [SnapshotSummary]) -> String {
        let source = ([goal, String(historyLimit)] + snapshots.map(\.id)).joined(separator: "\u{1f}")
        return "v2-\(fnv1a64Hex(source))"
    }

    private func materializePayloadItems(
        selectedItems: [BatchPastePlanItem],
        fullRequest: BatchFullRequest
    ) throws -> [Inserter.PayloadItem] {
        let htmlPreviewBase = URL(fileURLWithPath: fullRequest.pathBases.htmlPreview, isDirectory: true)
        let replayOutputBase = URL(fileURLWithPath: fullRequest.pathBases.replayOutput, isDirectory: true)

        return try selectedItems.enumerated().map { index, selectedItem in
            switch selectedItem.type {
            case .handle:
                guard let handle = selectedItem.handle else {
                    throw DogfoodError.missingRuntimePayload(handle: "")
                }
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
            case .text:
                guard let text = selectedItem.text else {
                    throw DogfoodError.missingSyntheticHandle(itemIndex: index)
                }
                guard let handle = selectedItem.syntheticHandle else {
                    throw DogfoodError.missingSyntheticHandle(itemIndex: index)
                }
                let utf8Data = Data(text.utf8)
                return Inserter.PayloadItem(
                    handle: handle,
                    representations: [
                        Inserter.PayloadRepresentation(
                            type: NSPasteboard.PasteboardType("public.utf8-plain-text"),
                            data: utf8Data
                        ),
                        Inserter.PayloadRepresentation(
                            type: NSPasteboard.PasteboardType("NSStringPboardType"),
                            data: utf8Data
                        )
                    ]
                )
            }
        }
    }

    private func pasteItemsForSelectedItems(
        _ selectedItems: [BatchPastePlanItem],
        fullRequest: BatchFullRequest,
        preferRichHTMLParents: Bool
    ) -> [BatchPastePlanItem] {
        guard preferRichHTMLParents else {
            return selectedItems
        }

        var itemsByHandle: [String: BatchModelItem] = [:]
        for item in fullRequest.items {
            itemsByHandle[item.handle] = item
        }

        var pasteItems: [BatchPastePlanItem] = []
        var seen = Set<String>()
        for selectedItem in selectedItems {
            guard selectedItem.type == .handle, let handle = selectedItem.handle else {
                pasteItems.append(selectedItem)
                continue
            }
            let pasteHandle = richHTMLParentHandle(for: handle, itemsByHandle: itemsByHandle, fullRequest: fullRequest) ?? handle
            guard !seen.contains(pasteHandle) else {
                continue
            }
            seen.insert(pasteHandle)
            var item = selectedItem
            item.handle = pasteHandle
            pasteItems.append(item)
        }
        return pasteItems
    }

    private func captureTargetFiles(in runDir: URL, timings: TimingRecorder) throws -> TargetFiles {
        status("batch paste: parsing target")
        timings.mark("target_capture_started")
        let metadata = TargetMetadataCapture.capture()
        timings.mark(
            "target_metadata_captured",
            details: [
                "focused_role": metadata.focusedRole ?? "",
                "focused_label": metadata.focusedLabel ?? "",
                "frontmost_app": metadata.frontmostApp ?? ""
            ].filter { !$0.value.isEmpty }
        )
        let caret = TargetMetadataCapture.captureCaret()
        timings.mark("target_caret_captured")
        let targetCapture = try ScreenCapture.captureFrontmostWindowSync(
            preferredGlobalRect: metadata.focusedBounds
        )
        timings.mark(
            "target_screenshot_captured",
            details: [
                "png_bytes": targetCapture.pngData.count,
                "window_width_points": Int(targetCapture.windowFramePoints.width),
                "window_height_points": Int(targetCapture.windowFramePoints.height)
            ]
        )
        let geometry = geometryPayload(for: targetCapture, metadata: metadata)
        let targetMode = targetMode(metadata: metadata, geometry: geometry)
        timings.mark("target_geometry_built", details: ["target_mode": targetMode])

        let targetPNG = runDir.appendingPathComponent("target.png")
        let annotatedTargetImage = runDir.appendingPathComponent("target_annotated.request.jpg")
        let targetMetadataJSON = runDir.appendingPathComponent("target_metadata.json")
        let caretJSON = runDir.appendingPathComponent("caret.json")
        let geometryJSON = runDir.appendingPathComponent("geometry.json")
        let targetPacketText = runDir.appendingPathComponent("target_ocr_packet.txt")
        let targetPacketBuildJSON = runDir.appendingPathComponent("target_ocr_packet.build.json")
        let targetProbeJSON = runDir.appendingPathComponent("target_copy_probe.json")

        try targetCapture.pngData.write(to: targetPNG, options: .atomic)
        timings.mark("target_png_written", details: ["byte_count": targetCapture.pngData.count])
        let probe: TargetProbeSummary?
        if targetMode == "document_canvas" {
            timings.mark("target_copy_probe_started")
            probe = suppressedTargetCopyProbe()
            timings.mark(
                "target_copy_probe_done",
                details: [
                    "status": probe?.status ?? "",
                    "change_count_changed": probe?.changeCountChanged ?? false,
                    "item_count": probe?.itemCount ?? 0,
                    "html_bytes": probe?.htmlBytes ?? 0,
                    "plain_text_bytes": probe?.plainTextBytes ?? 0,
                    "elapsed_ms": probe?.elapsedMS ?? 0,
                    "timeout_ms": probe?.timeoutMS ?? 0,
                    "poll_count": probe?.pollCount ?? 0,
                    "timed_out": probe?.timedOut ?? false
                ]
            )
        } else {
            probe = nil
        }
        let annotation: [String: Any]?
        if targetMode == "document_canvas" {
            if let degenerate = degenerateDocumentCanvasAnchorMetadata(metadata: metadata, geometry: geometry) {
                annotation = degenerate
                timings.mark(
                    "target_annotation_skipped",
                    details: [
                        "reason": "degenerate_document_canvas_anchor",
                    ]
                )
            } else {
                timings.mark("target_annotation_started")
                annotation = try annotateTargetCapture(
                    targetCapture,
                    metadata: metadata,
                    geometry: geometry,
                    output: annotatedTargetImage,
                    settings: modelImageSettings()
                )
            }
            let byteCount = fileManager.fileExists(atPath: annotatedTargetImage.path)
                ? ((try? annotatedTargetImage.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                : 0
            timings.mark(
                "target_annotation_done",
                details: [
                    "created": fileManager.fileExists(atPath: annotatedTargetImage.path),
                    "status": annotation?["status"] ?? "",
                    "byte_count": byteCount
                ]
            )
        } else {
            annotation = nil
        }
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
        timings.mark("target_metadata_files_written")

        return TargetFiles(
            targetPNG: targetPNG,
            modelTargetImage: fileManager.fileExists(atPath: annotatedTargetImage.path) ? annotatedTargetImage : nil,
            targetMetadataJSON: targetMetadataJSON,
            caretJSON: caretJSON,
            geometryJSON: geometryJSON,
            targetPacketText: targetPacketText,
            targetPacketBuildJSON: targetPacketBuildJSON,
            targetProbeJSON: targetProbeJSON,
            annotatedTargetImage: fileManager.fileExists(atPath: annotatedTargetImage.path) ? annotatedTargetImage : nil,
            targetMode: targetMode,
            targetMetadata: metadata
        )
    }

    private func degenerateDocumentCanvasAnchorMetadata(
        metadata: TargetMetadata,
        geometry: [String: Any]
    ) -> [String: Any]? {
        guard let focused = geometry["focused_bounds_points"] as? [String: Any] else {
            return nil
        }
        let width = doubleValue(focused["width"]) ?? 0
        let height = doubleValue(focused["height"]) ?? 0
        guard width <= 2 || height <= 2 else {
            return nil
        }
        return [
            "status": "degenerate_document_canvas_anchor",
            "source": "swift_focus_bounds",
            "annotation_confidence": "low",
            "reason": "focused_bounds_width_or_height_le_2",
            "focused_label": metadata.focusedLabel ?? "",
            "focused_description": metadata.focusedDescription ?? "",
            "focused_bounds_points": focused,
        ]
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
            let elapsedMS = 0.0
            return TargetProbeSummary(
                status: "copy_failed:\(error.localizedDescription)",
                changeCountChanged: false,
                itemCount: 0,
                types: [],
                htmlBytes: 0,
                plainTextBytes: 0,
                stringPreview: nil,
                elapsedMS: elapsedMS,
                timeoutMS: 220.0,
                pollCount: 0,
                timedOut: false
            )
        }

        let started = ProcessInfo.processInfo.systemUptime
        let timeout: TimeInterval = 0.22
        let pollInterval: TimeInterval = 0.01
        let deadline = Date().addingTimeInterval(timeout)
        var pollCount = 0
        while pasteboard.changeCount == originalChangeCount && Date() < deadline {
            pollCount += 1
            Thread.sleep(forTimeInterval: pollInterval)
        }
        let elapsedMS = roundedMS(ProcessInfo.processInfo.systemUptime - started)
        let changed = pasteboard.changeCount != originalChangeCount
        guard changed else {
            return TargetProbeSummary(
                status: "empty",
                changeCountChanged: false,
                itemCount: 0,
                types: [],
                htmlBytes: 0,
                plainTextBytes: 0,
                stringPreview: nil,
                elapsedMS: elapsedMS,
                timeoutMS: roundedMS(timeout),
                pollCount: pollCount,
                timedOut: true
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
            stringPreview: plainText.map { String($0.prefix(180)) },
            elapsedMS: elapsedMS,
            timeoutMS: roundedMS(timeout),
            pollCount: pollCount,
            timedOut: false
        )
    }

    private func annotateTargetCapture(
        _ capture: ScreenCapture.Capture,
        metadata: TargetMetadata,
        geometry: [String: Any],
        output: URL,
        settings: ModelImageSettings
    ) throws -> [String: Any]? {
        guard let baseImage = NSImage(data: capture.pngData) else {
            return nil
        }
        let rawSize = pixelSize(of: baseImage)
        guard let focusedRect = localFocusedRectPixels(
            metadata: metadata,
            geometry: geometry,
            imageSize: rawSize
        ) else {
            return nil
        }
        let maxRawDimension = max(rawSize.width, rawSize.height)
        let scale = settings.maxDimension > 0 && maxRawDimension > CGFloat(settings.maxDimension)
            ? CGFloat(settings.maxDimension) / maxRawDimension
            : 1.0
        let requestSize = NSSize(
            width: max(1, round(rawSize.width * scale)),
            height: max(1, round(rawSize.height * scale))
        )
        let requestFocusRect = scaleRect(focusedRect, by: scale)
        let rawCanvasRect = focusedRect.insetBy(dx: -180, dy: -140).intersection(
            NSRect(origin: .zero, size: rawSize)
        )
        let requestCanvasRect = scaleRect(rawCanvasRect, by: scale)

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(requestSize.width),
            pixelsHigh: Int(requestSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: requestSize).fill()
        baseImage.draw(in: NSRect(origin: .zero, size: requestSize))
        NSColor.systemRed.setStroke()
        let focusPath = NSBezierPath(rect: requestFocusRect)
        focusPath.lineWidth = max(2, 6 * scale)
        focusPath.stroke()

        NSColor.systemBlue.withAlphaComponent(0.9).setStroke()
        let canvasPath = NSBezierPath(rect: requestCanvasRect)
        canvasPath.lineWidth = max(2, 4 * scale)
        canvasPath.stroke()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: settings.jpegQuality]
        ) else {
            return nil
        }
        try data.write(to: output, options: .atomic)
        return [
            "source": "swift_focus_line_canvas_region",
            "annotated_target": output.lastPathComponent,
            "format": "jpeg",
            "jpeg_quality": Double(settings.jpegQuality),
            "raw_image_size_pixels": [
                "width": Double(rawSize.width),
                "height": Double(rawSize.height),
            ],
            "request_image_size_pixels": [
                "width": Double(requestSize.width),
                "height": Double(requestSize.height),
            ],
            "request_image_max_dimension": settings.maxDimension,
            "scale": Double(scale),
            "focus_rect_pixels": rectDictionary(requestFocusRect),
            "canvas_region_pixels": rectDictionary(requestCanvasRect),
            "raw_focus_rect_pixels": rectDictionary(focusedRect),
            "raw_canvas_region_pixels": rectDictionary(rawCanvasRect),
        ]
    }

    private func modelImageSettings() -> ModelImageSettings {
        var settings = ModelImageSettings(maxDimension: 1600, jpegQuality: 0.8)
        guard let settingsPath = Paths.settingsPath,
              let data = try? Data(contentsOf: settingsPath),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return settings
        }
        if let maxDimension = intValue(payload["request_image_max_dimension"]), maxDimension > 0 {
            settings.maxDimension = maxDimension
        }
        if let quality = doubleValue(payload["request_image_jpeg_quality"]) {
            if quality > 1 {
                settings.jpegQuality = CGFloat(max(1, min(100, quality)) / 100.0)
            } else {
                settings.jpegQuality = CGFloat(max(0.01, min(1.0, quality)))
            }
        }
        return settings
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

    private func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private func pixelSize(of image: NSImage) -> NSSize {
        if let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first {
            return NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        }
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return NSSize(width: cgImage.width, height: cgImage.height)
        }
        return image.size
    }

    private func scaleRect(_ rect: NSRect, by scale: CGFloat) -> NSRect {
        NSRect(
            x: rect.origin.x * scale,
            y: rect.origin.y * scale,
            width: rect.size.width * scale,
            height: rect.size.height * scale
        )
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

    private func selectorTimingSummary(from url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["selector_run_log": "missing"]
        }
        var summary: [String: String] = ["selector_run_log": url.lastPathComponent]
        if let timings = payload["timings"] as? [String: Any] {
            for key in ["request_build_ms", "target_image_prepare_ms", "model_latency_ms", "ttft_ms", "stream_duration_ms"] {
                if let value = timings[key] {
                    summary["selector_\(key)"] = String(describing: value)
                }
            }
        }
        if let request = payload["request"] as? [String: Any] {
            if let provider = request["provider"] {
                summary["selector_provider"] = String(describing: provider)
            }
            if let model = request["model"] {
                summary["selector_model"] = String(describing: model)
            }
            if let images = request["images"] as? [String: Any],
               let target = images["target"] as? [String: Any],
               let status = target["status"] {
                summary["selector_target_image_status"] = String(describing: status)
            }
        }
        return summary
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

private func roundedMS(_ seconds: TimeInterval) -> Double {
    ((seconds * 1000.0) * 100.0).rounded() / 100.0
}

private func fnv1a64Hex(_ value: String) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x100000001b3
    }
    return String(format: "%016llx", hash)
}
