import AppKit
import Foundation

/// Orchestrates one copy-paste trial:
///   ⌃⇧C → captures source screenshot, optionally prepares a source packet,
///          then stashes it in memory
///   ⌃⇧V → captures target screenshot + AX metadata, invokes Python, pastes result
final class TrialCoordinator {
    private final class StashedSource {
        let image: Data
        let capturedAt: Date
        let preparedSource: PythonRunner.PreparedSource?
        let hostProfile: [String: Any]
        let timingSummary: [String: Any]
        var warmWorker: PythonRunner.WarmWorker?
        /// True once `runTarget` has consumed this stash. Used to discard a
        /// late-arriving warm-worker handle that the paste path no longer needs.
        var consumed: Bool = false

        init(
            image: Data,
            capturedAt: Date,
            preparedSource: PythonRunner.PreparedSource?,
            hostProfile: [String: Any],
            timingSummary: [String: Any],
            warmWorker: PythonRunner.WarmWorker? = nil
        ) {
            self.image = image
            self.capturedAt = capturedAt
            self.preparedSource = preparedSource
            self.hostProfile = hostProfile
            self.timingSummary = timingSummary
            self.warmWorker = warmWorker
        }
    }

    private let config: Config
    private let runtimeStore: RuntimeConfigStore
    private let queue = DispatchQueue(label: "blink.coordinator", qos: .userInitiated)
    private var stashedSource: StashedSource?

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()

    var onStatusChange: ((String) -> Void)?
    var onArtifactsChange: (() -> Void)?
    var onFailureNotice: ((String, String) -> Void)?

    init(config: Config, runtimeStore: RuntimeConfigStore) {
        self.config = config
        self.runtimeStore = runtimeStore
    }

    func setSource() {
        queue.async { [self] in
            let setSourceStartedAt = Date()
            let setSourceStartedPerf = monotonicNow()
            status("capturing source…")
            notify(title: "Source capture started", detail: "Capturing the source window…", sound: .trigger)
            do {
                let runtime = DispatchQueue.main.sync { runtimeStore.currentSnapshot() }

                let captureStartedAt = Date()
                let captureStartedPerf = monotonicNow()
                let capture = try ScreenCapture.captureFrontmostWindowSync()
                let captureFinishedAt = Date()
                let captureFinishedPerf = monotonicNow()

                var sourceHostProfile: [String: Any] = [
                    "captured_at": isoString(capture.capturedAt),
                    "request_mode": runtime.requestMode.rawValue,
                    "capture_started_at": isoString(captureStartedAt),
                    "capture_finished_at": isoString(captureFinishedAt),
                    "capture_ms": durationMS(since: captureStartedPerf, endingAt: captureFinishedPerf),
                ]
                var sourceTimingSummary: [String: Any] = [
                    "host_source_capture_ms": durationMS(since: captureStartedPerf, endingAt: captureFinishedPerf),
                ]

                let prepareStartedAt = Date()
                let prepareStartedPerf = monotonicNow()
                let preparedSource = try maybePrepareSource(
                    from: capture,
                    runtime: runtime
                )
                let prepareFinishedAt = Date()
                let prepareFinishedPerf = monotonicNow()

                if runtime.requestMode.requiresSourcePacket {
                    let prepareMS = durationMS(since: prepareStartedPerf, endingAt: prepareFinishedPerf)
                    sourceHostProfile["prepare_source_packet_started_at"] = isoString(prepareStartedAt)
                    sourceHostProfile["prepare_source_packet_finished_at"] = isoString(prepareFinishedAt)
                    sourceHostProfile["prepare_source_packet_ms"] = prepareMS
                    sourceHostProfile["prepared_source_packet"] = preparedSource != nil
                    sourceTimingSummary["host_source_prepare_source_packet_ms"] = prepareMS
                }

                let setSourceTotalMS = durationMS(since: setSourceStartedPerf)
                sourceHostProfile["set_source_started_at"] = isoString(setSourceStartedAt)
                sourceHostProfile["set_source_finished_at"] = isoString(Date())
                sourceHostProfile["set_source_total_ms"] = setSourceTotalMS
                sourceTimingSummary["host_source_set_total_ms"] = setSourceTotalMS

                // If a previous source-capture spawned a warm worker that
                // never got consumed (no ⌃⇧V followed it), tear it down so
                // we don't leak processes. Subsequent ⌃⇧V calls will use the
                // freshly-spawned worker below.
                if let stale = stashedSource?.warmWorker {
                    stale.discard()
                }

                let stash = StashedSource(
                    image: capture.pngData,
                    capturedAt: capture.capturedAt,
                    preparedSource: preparedSource,
                    hostProfile: sourceHostProfile,
                    timingSummary: sourceTimingSummary
                )
                stashedSource = stash

                let configForWorker = config
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let worker = PythonRunner.startWarmWorker(config: configForWorker) else {
                        return
                    }
                    self?.queue.async {
                        // Only attach if this stash is still the current
                        // unconsumed one. ⌃⇧V may have already fired (sees
                        // nil warmWorker, takes fresh-spawn path) — in that
                        // case the worker is orphaned and we must discard it.
                        if self?.stashedSource === stash, !stash.consumed, stash.warmWorker == nil {
                            stash.warmWorker = worker
                        } else {
                            worker.discard()
                        }
                    }
                }

                if runtime.requestMode.requiresSourcePacket {
                    status("source captured + packet prepared — press ⌃⇧V on the target field")
                    notify(
                        title: "Source ready",
                        detail: "Packet prepared. Press \u{2303}\u{21E7}V on the target field.",
                        sound: .success
                    )
                } else {
                    status("source captured — press ⌃⇧V on the target field")
                    notify(
                        title: "Source ready",
                        detail: "Press \u{2303}\u{21E7}V on the target field.",
                        sound: .success
                    )
                }
            } catch {
                reportFailure(
                    title: "Source Capture Failed",
                    statusText: "source capture failed: \(shortErrorSummary(error))",
                    detail: detailedErrorMessage(error)
                )
            }
        }
    }

    func runTarget() {
        queue.async { [self] in
            guard let source = stashedSource else {
                status("no source stashed — press ⌃⇧C first")
                notify(title: "No source set", detail: "Press \u{2303}\u{21E7}C first.", sound: .failure)
                return
            }
            let runTargetStartedPerf = monotonicNow()
            let runtime = DispatchQueue.main.sync { runtimeStore.currentSnapshot() }
            status("capturing target…")
            let stopwatch = startStopwatchOnMain(
                title: "Pasting…",
                detail: "Capturing target",
                sound: .trigger
            )

            let metadata: TargetMetadata
            let caret: [String: Any]
            let targetCapture: ScreenCapture.Capture
            let metadataStartedAt: Date
            let metadataFinishedAt: Date
            let caretStartedAt: Date
            let caretFinishedAt: Date
            let screenshotStartedAt: Date
            let screenshotFinishedAt: Date
            let targetTimingSummary: [String: Any]
            let targetHostProfile: [String: Any]
            do {
                let targetCaptureStartedAt = Date()
                let targetCaptureStartedPerf = monotonicNow()

                metadataStartedAt = Date()
                let metadataStartedPerf = monotonicNow()
                metadata = TargetMetadataCapture.capture()
                metadataFinishedAt = Date()
                let metadataFinishedPerf = monotonicNow()

                caretStartedAt = Date()
                let caretStartedPerf = monotonicNow()
                caret = TargetMetadataCapture.captureCaret()
                caretFinishedAt = Date()
                let caretFinishedPerf = monotonicNow()

                screenshotStartedAt = Date()
                let screenshotStartedPerf = monotonicNow()
                targetCapture = try ScreenCapture.captureFrontmostWindowSync(
                    preferredGlobalRect: metadata.focusedBounds
                )
                screenshotFinishedAt = Date()
                let screenshotFinishedPerf = monotonicNow()

                targetTimingSummary = [
                    "host_target_metadata_capture_ms": durationMS(since: metadataStartedPerf, endingAt: metadataFinishedPerf),
                    "host_target_caret_capture_ms": durationMS(since: caretStartedPerf, endingAt: caretFinishedPerf),
                    "host_target_screenshot_capture_ms": durationMS(since: screenshotStartedPerf, endingAt: screenshotFinishedPerf),
                    "host_target_capture_total_ms": durationMS(since: targetCaptureStartedPerf, endingAt: screenshotFinishedPerf),
                ]
                targetHostProfile = [
                    "request_mode": runtime.requestMode.rawValue,
                    "capture_started_at": isoString(targetCaptureStartedAt),
                    "capture_finished_at": isoString(screenshotFinishedAt),
                    "metadata_capture_started_at": isoString(metadataStartedAt),
                    "metadata_capture_finished_at": isoString(metadataFinishedAt),
                    "metadata_capture_ms": durationMS(since: metadataStartedPerf, endingAt: metadataFinishedPerf),
                    "caret_capture_started_at": isoString(caretStartedAt),
                    "caret_capture_finished_at": isoString(caretFinishedAt),
                    "caret_capture_ms": durationMS(since: caretStartedPerf, endingAt: caretFinishedPerf),
                    "screenshot_capture_started_at": isoString(screenshotStartedAt),
                    "screenshot_capture_finished_at": isoString(screenshotFinishedAt),
                    "screenshot_capture_ms": durationMS(since: screenshotStartedPerf, endingAt: screenshotFinishedPerf),
                    "capture_total_ms": durationMS(since: targetCaptureStartedPerf, endingAt: screenshotFinishedPerf),
                    "focused_bounds_present": metadata.focusedBounds != nil,
                ]
            } catch {
                stopStopwatchOnMain(
                    stopwatch,
                    title: "Target Capture Failed",
                    detail: shortErrorSummary(error),
                    sound: .failure
                )
                reportFailure(
                    title: "Target Capture Failed",
                    statusText: "target capture failed: \(shortErrorSummary(error))",
                    detail: detailedErrorMessage(error),
                    skipNotify: true
                )
                source.warmWorker?.discard()
                return
            }

            let bundleId = ArtifactWriter.newBundleID()
            let bundleDir = Paths.runsDir.appendingPathComponent(bundleId, isDirectory: true)
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("blink-\(bundleId)-\(UUID().uuidString)", isDirectory: true)
            let artifactPrepStartedAt = Date()
            let artifactPrepStartedPerf = monotonicNow()
            do {
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                try source.image.write(to: tempDir.appendingPathComponent("source.png"))
                try targetCapture.pngData.write(to: tempDir.appendingPathComponent("target.png"))
                try ArtifactWriter.writeJSON(
                    metadata.asDictionary(),
                    to: tempDir.appendingPathComponent("target_metadata.json")
                )
                try ArtifactWriter.writeJSON(
                    caret,
                    to: tempDir.appendingPathComponent("caret.json")
                )
                try ArtifactWriter.writeJSON(
                    geometryPayload(for: targetCapture, metadata: metadata),
                    to: tempDir.appendingPathComponent("geometry.json")
                )
                try ArtifactWriter.writeJSON(
                    runtime.payload,
                    to: tempDir.appendingPathComponent("runtime_selection.json")
                )
                if let preparedSource = source.preparedSource {
                    try ArtifactWriter.writeJSON(
                        preparedSource.payload,
                        to: tempDir.appendingPathComponent("prepared_source.json")
                    )
                }
            } catch {
                try? FileManager.default.removeItem(at: tempDir)
                stopStopwatchOnMain(
                    stopwatch,
                    title: "Artifact Prep Failed",
                    detail: shortErrorSummary(error),
                    sound: .failure
                )
                reportFailure(
                    title: "Artifact Prep Failed",
                    statusText: "artifact prep failed: \(shortErrorSummary(error))",
                    detail: detailedErrorMessage(error),
                    skipNotify: true
                )
                source.warmWorker?.discard()
                return
            }
            let artifactPrepFinishedAt = Date()
            let artifactPrepFinishedPerf = monotonicNow()
            let artifactPrepMS = durationMS(since: artifactPrepStartedPerf, endingAt: artifactPrepFinishedPerf)

            let targetProfileWithPrep = targetHostProfile.merging([
                "artifact_prep_started_at": isoString(artifactPrepStartedAt),
                "artifact_prep_finished_at": isoString(artifactPrepFinishedAt),
                "artifact_prep_ms": artifactPrepMS,
            ]) { _, new in new }

            var hostTimingSummary = source.timingSummary
            hostTimingSummary.merge(targetTimingSummary) { _, new in new }
            hostTimingSummary["host_artifact_prep_ms"] = artifactPrepMS
            hostTimingSummary["host_pre_python_ms"] = durationMS(since: runTargetStartedPerf, endingAt: artifactPrepFinishedPerf)

            status("calling \(runtime.pasteProviderLabel)…")
            updateStopwatchOnMain(
                stopwatch,
                detail: "Generating via \(runtime.pasteProviderLabel)"
            )
            let pythonStartedAt = Date()
            let pythonStartedPerf = monotonicNow()
            let warmWorker = source.warmWorker
            source.warmWorker = nil
            source.consumed = true

            var pythonExtraEnv: [String: String] = [:]
            if let screenshotMS = targetTimingSummary["host_target_screenshot_capture_ms"] as? Double {
                pythonExtraEnv["BLINK_TARGET_CAPTURE_MS"] = String(screenshotMS)
            }

            PythonRunner.runOnce(
                config: config,
                sourcePNG: tempDir.appendingPathComponent("source.png"),
                targetPNG: tempDir.appendingPathComponent("target.png"),
                targetMetadataJSON: tempDir.appendingPathComponent("target_metadata.json"),
                caretJSON: tempDir.appendingPathComponent("caret.json"),
                geometryJSON: tempDir.appendingPathComponent("geometry.json"),
                runtimeJSON: tempDir.appendingPathComponent("runtime_selection.json"),
                preparedSourceJSON: source.preparedSource == nil
                    ? nil
                    : tempDir.appendingPathComponent("prepared_source.json"),
                settingsJSON: runtime.settingsPath,
                outputParent: Paths.runsDir,
                bundleId: bundleId,
                extraEnvironment: pythonExtraEnv,
                warmWorker: warmWorker
            ) { [weak self] result in
                guard let self = self else {
                    try? FileManager.default.removeItem(at: tempDir)
                    return
                }
                self.queue.async {
                    defer { try? FileManager.default.removeItem(at: tempDir) }
                    DispatchQueue.main.async {
                        self.onArtifactsChange?()
                    }

                    let pythonFinishedAt = Date()
                    let pythonWallMS = self.durationMS(since: pythonStartedPerf)
                    hostTimingSummary["host_python_wall_ms"] = pythonWallMS

                    let pythonStatus: String = {
                        switch result {
                        case .success:
                            return "ok"
                        case .failure:
                            return "error"
                        }
                    }()
                    let pythonProfile: [String: Any] = [
                        "started_at": self.isoString(pythonStartedAt),
                        "finished_at": self.isoString(pythonFinishedAt),
                        "wall_ms": pythonWallMS,
                        "status": pythonStatus,
                    ]

                    var pasteProfile: [String: Any] = [
                        "status": "pending",
                    ]

                    self.persistHostProfile(
                        bundleDir: bundleDir,
                        profile: self.makeHostProfile(
                            bundleID: bundleId,
                            sourceProfile: source.hostProfile,
                            targetProfile: targetProfileWithPrep,
                            pythonProfile: pythonProfile,
                            pasteProfile: pasteProfile,
                            timingSummary: hostTimingSummary
                        )
                    )

                    switch result {
                    case .success(let output):
                        if output.isEmpty {
                            pasteProfile["status"] = "skipped_empty_output"
                            hostTimingSummary["host_run_target_total_ms"] = self.durationMS(since: runTargetStartedPerf)
                            self.persistHostProfile(
                                bundleDir: bundleDir,
                                profile: self.makeHostProfile(
                                    bundleID: bundleId,
                                    sourceProfile: source.hostProfile,
                                    targetProfile: targetProfileWithPrep,
                                    pythonProfile: pythonProfile,
                                    pasteProfile: pasteProfile,
                                    timingSummary: hostTimingSummary
                                )
                            )
                            self.stopStopwatchOnMain(
                                stopwatch,
                                title: "Empty Output",
                                detail: "Inspect run bundle",
                                sound: .failure
                            )
                            self.reportFailure(
                                title: "Empty Output",
                                statusText: "empty output; inspect the run bundle for errors",
                                detail: "Blink did not receive any text to paste. Open the newest run in Control Center and inspect `stderr.log`, `run.json`, `host_profile.json`, and the assembled prompts.",
                                skipNotify: true
                            )
                            return
                        }

                        let insertStartedAt = Date()
                        let insertStartedPerf = self.monotonicNow()
                        self.status("inserting \(output.count) chars…")
                        self.updateStopwatchOnMain(
                            stopwatch,
                            detail: "Inserting \(output.count) chars"
                        )
                        Inserter.insert(text: output) { insertResult in
                            self.queue.async {
                                let insertFinishedAt = Date()
                                let insertMS = self.durationMS(since: insertStartedPerf)
                                hostTimingSummary["host_insert_ms"] = insertMS
                                hostTimingSummary["host_run_target_total_ms"] = self.durationMS(since: runTargetStartedPerf)
                                pasteProfile["started_at"] = self.isoString(insertStartedAt)
                                pasteProfile["finished_at"] = self.isoString(insertFinishedAt)
                                pasteProfile["insert_ms"] = insertMS

                                switch insertResult {
                                case .success:
                                    pasteProfile["status"] = "ok"
                                    self.persistHostProfile(
                                        bundleDir: bundleDir,
                                        profile: self.makeHostProfile(
                                            bundleID: bundleId,
                                            sourceProfile: source.hostProfile,
                                            targetProfile: targetProfileWithPrep,
                                            pythonProfile: pythonProfile,
                                            pasteProfile: pasteProfile,
                                            timingSummary: hostTimingSummary
                                        )
                                    )
                                    DispatchQueue.main.async {
                                        self.onArtifactsChange?()
                                    }
                                    self.status("done — output pasted")
                                    self.stopStopwatchOnMain(
                                        stopwatch,
                                        title: "Paste complete",
                                        detail: "Pasted \(output.count) chars",
                                        sound: .success
                                    )
                                case .failure(let err):
                                    pasteProfile["status"] = "error"
                                    pasteProfile["error"] = self.shortErrorSummary(err)
                                    self.persistHostProfile(
                                        bundleDir: bundleDir,
                                        profile: self.makeHostProfile(
                                            bundleID: bundleId,
                                            sourceProfile: source.hostProfile,
                                            targetProfile: targetProfileWithPrep,
                                            pythonProfile: pythonProfile,
                                            pasteProfile: pasteProfile,
                                            timingSummary: hostTimingSummary
                                        )
                                    )
                                    DispatchQueue.main.async {
                                        self.onArtifactsChange?()
                                    }
                                    self.stopStopwatchOnMain(
                                        stopwatch,
                                        title: "Paste Failed",
                                        detail: self.shortErrorSummary(err),
                                        sound: .failure
                                    )
                                    self.reportFailure(
                                        title: "Paste Failed",
                                        statusText: "paste failed: \(self.shortErrorSummary(err))",
                                        detail: self.detailedErrorMessage(err),
                                        skipNotify: true
                                    )
                                }
                            }
                        }
                    case .failure(let err):
                        pasteProfile["status"] = "skipped_python_failure"
                        pasteProfile["error"] = self.shortErrorSummary(err)
                        hostTimingSummary["host_run_target_total_ms"] = self.durationMS(since: runTargetStartedPerf)
                        self.persistHostProfile(
                            bundleDir: bundleDir,
                            profile: self.makeHostProfile(
                                bundleID: bundleId,
                                sourceProfile: source.hostProfile,
                                targetProfile: targetProfileWithPrep,
                                pythonProfile: pythonProfile,
                                pasteProfile: pasteProfile,
                                timingSummary: hostTimingSummary
                            )
                        )
                        self.stopStopwatchOnMain(
                            stopwatch,
                            title: "Paste Generation Failed",
                            detail: self.shortErrorSummary(err),
                            sound: .failure
                        )
                        self.reportFailure(
                            title: "Paste Generation Failed",
                            statusText: "python failed: \(self.shortErrorSummary(err))",
                            detail: self.detailedErrorMessage(err),
                            skipNotify: true
                        )
                    }
                }
            }
        }
    }

    private func maybePrepareSource(
        from capture: ScreenCapture.Capture,
        runtime: RuntimeSelectionSnapshot
    ) throws -> PythonRunner.PreparedSource? {
        guard runtime.requestMode.requiresSourcePacket else { return nil }

        status("preparing source packet…")
        notify(title: "Preparing source packet", detail: runtime.requestMode.title)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blink-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceURL = tempDir.appendingPathComponent("source.png")
        let runtimeURL = tempDir.appendingPathComponent("runtime_selection.json")
        try capture.pngData.write(to: sourceURL)
        try ArtifactWriter.writeJSON(runtime.payload, to: runtimeURL)

        return try PythonRunner.prepareSourceSync(
            config: config,
            sourcePNG: sourceURL,
            runtimeJSON: runtimeURL,
            settingsJSON: runtime.settingsPath
        )
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

    private func status(_ text: String) {
        onStatusChange?(text)
        NSLog("[blink] %@", text)
    }

    private func reportFailure(
        title: String,
        statusText: String,
        detail: String,
        skipNotify: Bool = false
    ) {
        status(statusText)
        if !skipNotify {
            notify(title: title, detail: statusText, sound: .failure, duration: 2.6)
        }
        DispatchQueue.main.async {
            self.onFailureNotice?(title, detail)
        }
    }

    private func startStopwatchOnMain(
        title: String,
        detail: String?,
        sound: FeedbackSound
    ) -> StopwatchHandle {
        var handle: StopwatchHandle!
        DispatchQueue.main.sync {
            handle = FeedbackCenter.shared.startStopwatch(
                title: title,
                detail: detail,
                sound: sound
            )
        }
        return handle
    }

    private func updateStopwatchOnMain(
        _ handle: StopwatchHandle,
        title: String? = nil,
        detail: String? = nil
    ) {
        DispatchQueue.main.async {
            FeedbackCenter.shared.updateStopwatch(handle, title: title, detail: detail)
        }
    }

    private func stopStopwatchOnMain(
        _ handle: StopwatchHandle,
        title: String,
        detail: String?,
        sound: FeedbackSound,
        dismissAfter: TimeInterval = 1.2
    ) {
        DispatchQueue.main.async {
            FeedbackCenter.shared.stopStopwatch(
                handle,
                title: title,
                detail: detail,
                sound: sound,
                dismissAfter: dismissAfter
            )
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
                return summary.isEmpty
                    ? "python exited \(status)"
                    : "python exited \(status): \(summary)"
            case .invalidJSONOutput:
                return "Python returned invalid JSON"
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
                if detail.isEmpty {
                    return "Python exited with status \(status)."
                }
                return "Python exited with status \(status).\n\n\(detail)"
            case .invalidJSONOutput:
                return "Python returned invalid JSON. This usually means the helper crashed before it could emit a valid payload."
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
        return String(tail[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private func makeHostProfile(
        bundleID: String,
        sourceProfile: [String: Any],
        targetProfile: [String: Any],
        pythonProfile: [String: Any],
        pasteProfile: [String: Any],
        timingSummary: [String: Any]
    ) -> [String: Any] {
        [
            "schema_version": 1,
            "bundle_id": bundleID,
            "recorded_at": isoString(Date()),
            "source": sourceProfile,
            "target": targetProfile,
            "python": pythonProfile,
            "paste": pasteProfile,
            "summary": timingSummary,
        ]
    }

    private func persistHostProfile(bundleDir: URL, profile: [String: Any]) {
        let profileURL = bundleDir.appendingPathComponent("host_profile.json")
        try? ArtifactWriter.writeJSON(profile, to: profileURL)
        guard let summary = profile["summary"] as? [String: Any] else { return }
        mergeHostTimingSummary(into: bundleDir.appendingPathComponent("run.json"), summary: summary)
    }

    private func mergeHostTimingSummary(into runJSONURL: URL, summary: [String: Any]) {
        guard let data = try? Data(contentsOf: runJSONURL),
              var payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }
        var timings = payload["timings"] as? [String: Any] ?? [:]
        for (key, value) in summary {
            timings[key] = value
        }
        payload["timings"] = timings
        try? ArtifactWriter.writeJSON(payload, to: runJSONURL)
    }

    private func isoString(_ date: Date) -> String {
        Self.isoFormatter.string(from: date)
    }

    private func monotonicNow() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private func durationMS(since start: TimeInterval, endingAt end: TimeInterval? = nil) -> Double {
        let final = end ?? monotonicNow()
        return round((final - start) * 100_000) / 100
    }
}
