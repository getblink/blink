import AppKit
import CryptoKit
import Foundation
import ScreenCaptureKit

final class TLDRCoordinator {
    private struct CapturedFrame {
        let index: Int
        let pngURL: URL
        let capturedAt: Date
        let captureMS: Int
        let windowID: CGWindowID
        let screenshotMeta: [String: Any]
        let imageDiagnostics: [String: Any]
        let sha256: String
        let thumbnail: NSImage?
    }

    private struct CaptureSession {
        let requestID: String
        let startedAt: Date
        let startedPerf: DispatchTime
        let runtime: RuntimeConfigFile
        let clientMetadata: [String: Any]
        var frontmostApp: [String: Any]
        let staging: URL
        var frames: [CapturedFrame]
        var shareableContent: SCShareableContent?
        var debounceTimer: DispatchSourceTimer?
        var collectingTimer: DispatchSourceTimer?
    }

    private struct CapturedFrameResult {
        let frame: CapturedFrame
        let shareableContent: SCShareableContent
    }

    private let config: Config
    private let runtimeStore: RuntimeConfigStore
    private let eventClient: TLDREventClient
    private let summaryHotkey: Hotkey
    private let soundEffects: SoundEffects
    private let queue = DispatchQueue(label: "tldr.coordinator", qos: .userInitiated)
    private let overlay = SuggestionsOverlay()
    private var currentSuggestions: [String] = []
    private var currentBundleDir: URL?
    private var currentRequestID: String?
    // Tracks the request ID for which a terminal event (copied / inserted /
    // paste_failed flow) has already been emitted, so a follow-on dismissOverlay
    // call during the close/insert animation does not emit a redundant
    // suggestion_dismissed and overwrite the server-side outcome.
    private var terminalEmittedRequestID: String?
    private var currentStreamingRun: PythonRunner.StreamingRun?
    private var choiceState = SuggestionChoiceState(suggestionCount: 0)
    private var running = false
    private var session: CaptureSession?
    private let collectingStateLock = NSLock()
    private var collectingState = false
    private let singlePressDebounceMS = 600
    private let collectingTimeoutSeconds = 8
    private let maxCapturedFrames = 8

    var onStatusChange: ((String) -> Void)?
    var onFailureNotice: ((String, String) -> Void)?

    init(
        config: Config,
        runtimeStore: RuntimeConfigStore,
        eventClient: TLDREventClient,
        summaryHotkey: Hotkey,
        soundEffects: SoundEffects
    ) {
        self.config = config
        self.runtimeStore = runtimeStore
        self.eventClient = eventClient
        self.summaryHotkey = summaryHotkey
        self.soundEffects = soundEffects
    }

    var isOverlayActive: Bool {
        overlay.isVisible
    }

    var isCustomInputActive: Bool {
        choiceState.customInputActive
    }

    var isCollectingActive: Bool {
        collectingStateLock.lock()
        defer { collectingStateLock.unlock() }
        return collectingState
    }

    static func clientMetadata() -> [String: Any] {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        let name = info["CFBundleName"] as? String ?? "TLDR"
        return [
            "app_name": name,
            "app_version": version,
            "app_build": build,
            "bundle_id": Bundle.main.bundleIdentifier ?? "com.henryz2004.tldr",
            "install_id": Paths.loadOrCreateInstallID(),
            "platform": "macOS",
            "platform_version": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
    }

    func summarizeFrontmostWindow() {
        queue.async { [self] in
            guard !running else {
                status("already working")
                return
            }
            if session == nil {
                startCaptureSession()
            } else {
                appendFrameToSession()
            }
        }
    }

    func submitCollectingSession() {
        queue.async { [self] in
            submitSession()
        }
    }

    func cancelCollectingSession() {
        queue.async { [self] in
            cancelActiveSession(statusText: "cancelled")
        }
    }

    private func setCollectingActive(_ active: Bool) {
        collectingStateLock.lock()
        collectingState = active
        collectingStateLock.unlock()
    }

    private func cancelActiveSession(statusText: String) {
        guard let active = session else { return }
        active.debounceTimer?.cancel()
        active.collectingTimer?.cancel()
        session = nil
        setCollectingActive(false)
        try? FileManager.default.removeItem(at: active.staging)
        PendingRunStore.finish(requestID: active.requestID)
        emitEvent(
            requestID: active.requestID,
            type: "capture_cancelled",
            allowLogging: active.runtime.allowEventLogging,
            clientMetadata: active.clientMetadata,
            details: ["frame_count": active.frames.count]
        )
        status(statusText)
        DispatchQueue.main.async {
            self.overlay.close()
        }
    }

    private func startCaptureSession() {
        running = true
        defer { running = false }

        let runtime = DispatchQueue.main.sync { runtimeStore.snapshot }
        let clientMetadata = Self.clientMetadata()
        let frontmostApp = frontmostAppMetadata()
        let requestID = UUID().uuidString.lowercased()
        let startedAt = Date()
        let staging: URL
        do {
            staging = try makeStagingDir()
        } catch {
            reportFailure(
                title: "TLDR Failed",
                statusText: "failed: \(shortErrorSummary(error))",
                detail: detailedErrorMessage(error)
            )
            return
        }
        let pendingPayload: [String: Any] = [
            "request_id": requestID,
            "started_at": JSONFiles.isoString(startedAt),
            "updated_at": JSONFiles.isoString(startedAt),
            "last_phase": "capture_started",
            "client": clientMetadata,
            "capture_mode": "frontmost_window",
            "input_mode": "screenshot",
            "frontmost_app": frontmostApp,
            "frames": [],
        ]
        do {
            try PendingRunStore.create(requestID: requestID, payload: pendingPayload)
            emitEvent(
                requestID: requestID,
                type: "capture_started",
                allowLogging: runtime.allowEventLogging,
                clientMetadata: clientMetadata,
                details: ["frontmost_app": frontmostApp]
            )
            status("capturing window...")
            DispatchQueue.main.async {
                self.soundEffects.play(.capture)
            }
            let captureResult = try captureFrame(index: 0, staging: staging)
            let frame = captureResult.frame
            var appWithWindow = frontmostApp
            appWithWindow["window_id"] = Int(frame.windowID)
            session = CaptureSession(
                requestID: requestID,
                startedAt: startedAt,
                startedPerf: monotonicNow(),
                runtime: runtime,
                clientMetadata: clientMetadata,
                frontmostApp: appWithWindow,
                staging: staging,
                frames: [frame],
                shareableContent: captureResult.shareableContent,
                debounceTimer: nil,
                collectingTimer: nil
            )
            recordFrameCaptured(frame, mode: "frontmost_window")
            armDebounceTimer(requestID: requestID)
            status("captured frame 1")
        } catch {
            try? FileManager.default.removeItem(at: staging)
            PendingRunStore.finish(requestID: requestID)
            emitEvent(
                requestID: requestID,
                type: failureEventType(for: error, lastPhase: "capture_started"),
                allowLogging: runtime.allowEventLogging,
                clientMetadata: clientMetadata,
                details: ["error": shortErrorSummary(error)]
            )
            reportFailure(
                title: "TLDR Failed",
                statusText: "failed: \(shortErrorSummary(error))",
                detail: detailedErrorMessage(error)
            )
        }
    }

    private func appendFrameToSession() {
        guard var active = session else { return }
        if active.frames.count >= maxCapturedFrames {
            status("max frames reached")
            session = active
            armCollectingTimer(requestID: active.requestID)
            let thumbnails = active.frames.compactMap(\.thumbnail)
            DispatchQueue.main.async {
                self.overlay.showCollecting(
                    frameCount: active.frames.count,
                    maxFrames: self.maxCapturedFrames,
                    hotkeyDisplay: self.summaryHotkey.displayString,
                    thumbnails: thumbnails,
                    message: "Max frames reached"
                )
            }
            return
        }
        running = true
        defer { running = false }
        active.debounceTimer?.cancel()
        active.debounceTimer = nil
        do {
            status("capturing frame \(active.frames.count + 1)...")
            DispatchQueue.main.async {
                self.soundEffects.play(.capture)
            }
            // Pin to the source app captured at frame 0. Without this, if
            // the overlay ever momentarily activates TLDR, `NSWorkspace`
            // reports TLDR as frontmost and capture would target our own
            // panel — which surfaces as a misleading "permission denied"
            // through SCK.
            let pinnedPID: pid_t? = (active.frontmostApp["pid"] as? Int).map(pid_t.init)
            let captureResult = try captureFrame(
                index: active.frames.count,
                staging: active.staging,
                shareableContent: active.shareableContent,
                preferredPID: pinnedPID
            )
            let frame = captureResult.frame
            active.shareableContent = captureResult.shareableContent
            guard frame.windowID == active.frames[0].windowID else {
                status("different window ignored")
                emitEvent(
                    requestID: active.requestID,
                    type: "capture_frame_dropped",
                    allowLogging: active.runtime.allowEventLogging,
                    clientMetadata: active.clientMetadata,
                    details: [
                        "reason": "window_id_mismatch",
                        "expected_window_id": Int(active.frames[0].windowID),
                        "actual_window_id": Int(frame.windowID),
                    ]
                )
                try? FileManager.default.removeItem(at: frame.pngURL)
                session = active
                let thumbnails = active.frames.compactMap(\.thumbnail)
                DispatchQueue.main.async {
                    self.overlay.showCollecting(
                        frameCount: active.frames.count,
                        maxFrames: self.maxCapturedFrames,
                        hotkeyDisplay: self.summaryHotkey.displayString,
                        thumbnails: thumbnails,
                        message: "Different window ignored"
                    )
                }
                armCollectingTimer(requestID: active.requestID)
                return
            }
            let isDuplicate: Bool
            if let previous = active.frames.last, previous.sha256 == frame.sha256 {
                do {
                    try replaceFrameFile(at: previous.pngURL, with: frame.pngURL)
                } catch {
                    try? FileManager.default.removeItem(at: frame.pngURL)
                    throw error
                }
                active.frames[active.frames.count - 1] = CapturedFrame(
                    index: previous.index,
                    pngURL: previous.pngURL,
                    capturedAt: frame.capturedAt,
                    captureMS: frame.captureMS,
                    windowID: frame.windowID,
                    screenshotMeta: frame.screenshotMeta,
                    imageDiagnostics: frame.imageDiagnostics,
                    sha256: frame.sha256,
                    thumbnail: frame.thumbnail
                )
                status("no new content — scroll first")
                isDuplicate = true
            } else {
                active.frames.append(frame)
                status("collecting \(active.frames.count) frames")
                isDuplicate = false
            }
            session = active
            if let current = session {
                updatePendingFrames(current)
            }
            let thumbnails = active.frames.compactMap(\.thumbnail)
            DispatchQueue.main.async {
                self.overlay.showCollecting(
                    frameCount: active.frames.count,
                    maxFrames: self.maxCapturedFrames,
                    hotkeyDisplay: self.summaryHotkey.displayString,
                    thumbnails: thumbnails,
                    message: isDuplicate ? "Same content. Scroll first" : nil,
                    flashLastThumbnail: isDuplicate
                )
            }
            armCollectingTimer(requestID: active.requestID)
        } catch {
            session = active
            cancelActiveSession(statusText: "capture failed")
            reportFailure(title: "TLDR Failed", statusText: "failed: \(shortErrorSummary(error))", detail: detailedErrorMessage(error))
        }
    }

    private func submitSession() {
        guard let active = session else { return }
        guard !running else { return }
        running = true
        defer { running = false }
        active.debounceTimer?.cancel()
        active.collectingTimer?.cancel()
        session = nil
        setCollectingActive(false)
        submitCapturedSession(active)
    }

    private func captureFrame(
        index: Int,
        staging: URL,
        shareableContent: SCShareableContent? = nil,
        preferredPID: pid_t? = nil
    ) throws -> CapturedFrameResult {
        let captureStartedPerf = monotonicNow()
        let capture = try ScreenCapture.captureFrontmostWindowSync(
            shareableContent: shareableContent,
            preferredPID: preferredPID
        )
        let captureMS = durationMS(since: captureStartedPerf)
        guard let capturePayload = ImageDiagnostics.makePayload(pngData: capture.pngData) else {
            throw NSError(domain: "TLDRCoordinator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't inspect screenshot metadata."])
        }
        let frameURL = staging.appendingPathComponent("screenshot_\(index).png")
        try capture.pngData.write(to: frameURL, options: .atomic)
        return CapturedFrameResult(
            frame: CapturedFrame(
                index: index,
                pngURL: frameURL,
                capturedAt: capture.capturedAt,
                captureMS: captureMS,
                windowID: capture.windowID,
                screenshotMeta: capturePayload.screenshot,
                imageDiagnostics: capturePayload.diagnostics,
                sha256: sha256Hex(capture.pngData),
                thumbnail: Self.makeThumbnail(from: capture.pngData)
            ),
            shareableContent: capture.shareableContent
        )
    }

    private func armDebounceTimer(requestID: String) {
        guard var active = session, active.requestID == requestID else { return }
        active.debounceTimer?.cancel()
        active.collectingTimer?.cancel()
        setCollectingActive(false)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(singlePressDebounceMS))
        timer.setEventHandler { [weak self] in
            self?.submitSession()
        }
        active.debounceTimer = timer
        session = active
        timer.resume()
    }

    private func armCollectingTimer(requestID: String) {
        guard var active = session, active.requestID == requestID else { return }
        active.collectingTimer?.cancel()
        setCollectingActive(true)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(collectingTimeoutSeconds))
        timer.setEventHandler { [weak self] in
            self?.submitSession()
        }
        active.collectingTimer = timer
        session = active
        timer.resume()
    }

    private func submitCapturedSession(_ active: CaptureSession) {
        guard let firstFrame = active.frames.first else { return }
        let requestID = active.requestID
        let runtime = active.runtime
        let clientMetadata = active.clientMetadata
        let captureMode = active.frames.count > 1 ? "frontmost_window_scroll" : "frontmost_window"
        var lastPhase = "capture_succeeded"
        do {
            let focusedSnapshot = FocusedContextCapture.captureSnapshot(
                allowContentRetention: runtime.allowContentRetention
            )
            let focusedContext = focusedSnapshot.uploadPayload
            let runtimeURL = active.staging.appendingPathComponent("runtime.json")
            let hostProfileURL = active.staging.appendingPathComponent("host_profile.json")
            let requestURL = active.staging.appendingPathComponent("request.json")
            try writeJSON(runtime, to: runtimeURL)
            try? FileManager.default.removeItem(at: active.staging.appendingPathComponent("screenshot.png"))
            try FileManager.default.copyItem(
                at: firstFrame.pngURL,
                to: active.staging.appendingPathComponent("screenshot.png")
            )

            let requestEnvelope = makeRequestEnvelope(
                requestID: requestID,
                runtime: runtime,
                clientMetadata: clientMetadata,
                frontmostApp: active.frontmostApp,
                screenshotMeta: firstFrame.screenshotMeta,
                diagnostics: firstFrame.imageDiagnostics,
                focusedContext: focusedContext,
                captureMode: captureMode,
                frames: active.frames
            )
            try JSONFiles.writeObject(requestEnvelope, to: requestURL)

            let captureMS = active.frames.reduce(0) { $0 + $1.captureMS }
            let hostProfile: [String: Any] = [
                "request_id": requestID,
                "started_at": JSONFiles.isoString(active.startedAt),
                "capture_ms": captureMS,
                "frame_count": active.frames.count,
                "frontmost_app": active.frontmostApp,
                "client": clientMetadata,
                "image_diagnostics": firstFrame.imageDiagnostics,
                "frames": framePayloads(active.frames),
            ]
            try JSONFiles.writeObject(hostProfile, to: hostProfileURL)

            updatePendingFrames(active, focusedContext: focusedContext, phase: lastPhase)
            emitEvent(
                requestID: requestID,
                type: "capture_succeeded",
                allowLogging: runtime.allowEventLogging,
                clientMetadata: clientMetadata,
                details: [
                    "capture_ms": captureMS,
                    "frame_count": active.frames.count,
                    "screenshot": firstFrame.screenshotMeta,
                    "image_diagnostics": firstFrame.imageDiagnostics,
                ]
            )
            for frame in active.frames where (frame.imageDiagnostics["blank_likely"] as? Bool) == true {
                emitEvent(
                    requestID: requestID,
                    type: "capture_blank_detected",
                    allowLogging: runtime.allowEventLogging,
                    clientMetadata: clientMetadata,
                    details: ["frame_index": frame.index, "image_diagnostics": frame.imageDiagnostics]
                )
            }

            lastPhase = "request_upload_started"
            PendingRunStore.update(requestID: requestID) { payload in
                payload["last_phase"] = lastPhase
            }
            emitEvent(
                requestID: requestID,
                type: "request_upload_started",
                allowLogging: runtime.allowEventLogging,
                clientMetadata: clientMetadata,
                details: ["input_mode": "screenshot", "frame_count": active.frames.count]
            )

            status("calling TLDR backend...")
            DispatchQueue.main.async {
                self.currentRequestID = requestID
                self.currentSuggestions = []
                self.currentBundleDir = nil
                self.choiceState = SuggestionChoiceState(suggestionCount: 0, allowsCustomInput: false)
                self.overlay.onCustomInputFocusChanged = nil
                self.overlay.onCustomInsert = nil
                self.overlay.onCustomInsertKey = nil
                self.overlay.onLeaveCustomInputKey = nil
                self.overlay.onTextEditingKey = nil
                self.overlay.onChoiceKey = { _ in }
                self.overlay.onInsertKey = { true }
                self.overlay.onDismissKey = { [weak self] in
                    self?.dismissOverlay()
                }
                self.overlay.showLoading(tldr: active.frames.count > 1 ? "Reading \(active.frames.count) frames..." : "Reading this screen...")
                if active.frames.contains(where: { ($0.imageDiagnostics["blank_likely"] as? Bool) == true }) {
                    self.overlay.showSoftError("One capture looks blank. TLDR will still try to read it.")
                }
            }
            let pythonStartedPerf = monotonicNow()
            let result = try PythonRunner.runOnceStreaming(
                config: config,
                screenshotPNGs: active.frames.map(\.pngURL),
                runtimeJSON: runtimeURL,
                settingsJSON: Paths.settingsPath,
                prompt: Paths.promptPath,
                requestJSON: requestURL,
                outputParent: Paths.runsDir,
                hostProfileJSON: hostProfileURL,
                onRunStarted: { run in
                    DispatchQueue.main.async {
                        self.currentStreamingRun = run
                    }
                },
                onEvent: { event in
                    DispatchQueue.main.async {
                        guard self.currentRequestID == requestID else { return }
                        switch event {
                        case .phase(let message):
                            self.overlay.updateLoadingPhase(message)
                        case .partialTLDR(let text):
                            self.overlay.updateSummary(text)
                        case .partialSuggestions(let list):
                            self.overlay.updateSuggestions(Array(list.prefix(3)))
                        }
                    }
                }
            )
            DispatchQueue.main.async {
                if self.currentRequestID == requestID {
                    self.currentStreamingRun = nil
                }
            }
            guard isCurrentRequest(requestID) else { return }
            let pythonMS = durationMS(since: pythonStartedPerf)
            let totalMS = durationMS(since: active.startedPerf)

            let bundleDir = URL(fileURLWithPath: result.bundleDir)
            try updateRunHostProfile(
                bundleDir: bundleDir,
                requestID: requestID,
                captureMS: captureMS,
                pythonMS: pythonMS,
                totalMS: totalMS,
                result: result
            )

            lastPhase = "overlay_shown"
            PendingRunStore.update(requestID: requestID) { payload in
                payload["last_phase"] = lastPhase
                payload["bundle_dir"] = result.bundleDir
            }
            emitEvent(
                requestID: requestID,
                type: "server_response_received",
                allowLogging: runtime.allowEventLogging,
                clientMetadata: clientMetadata,
                details: [
                    "duration_ms": result.durationMS as Any,
                    "warnings": result.warnings,
                    "model": result.model as Any,
                    "frame_count": active.frames.count,
                ]
            )

            status("ready - press 1/2/3 to expand")
            DispatchQueue.main.async {
                guard self.currentRequestID == requestID else { return }
                self.currentSuggestions = Array(result.suggestions.prefix(3)).map { suggestion in
                    SuggestionPrefixStripper.stripDuplicatedDraftPrefix(
                        from: suggestion,
                        draft: focusedSnapshot.meaningfulDraftText
                    )
                }
                self.currentBundleDir = bundleDir
                self.currentRequestID = requestID
                self.choiceState = SuggestionChoiceState(suggestionCount: self.currentSuggestions.count)
                self.overlay.onCustomInputFocusChanged = { [weak self] active in
                    self?.choiceState.setCustomInputActive(active)
                }
                self.overlay.onCustomInsert = { [weak self] text in
                    self?.insertCustomReply(text: text)
                }
                self.overlay.onChoiceKey = { [weak self] index in
                    self?.chooseSuggestion(index: index)
                }
                self.overlay.onInsertKey = { [weak self] in
                    self?.insertExpandedSuggestion() ?? false
                }
                self.overlay.onCustomInsertKey = { [weak self] in
                    _ = self?.insertCustomReplyFromInput()
                    return true
                }
                self.overlay.onLeaveCustomInputKey = { [weak self] in
                    self?.leaveCustomInput()
                }
                self.overlay.onTextEditingKey = { [weak self] shortcut in
                    self?.performCustomInputShortcut(shortcut) ?? false
                }
                self.overlay.onDismissKey = { [weak self] in
                    self?.dismissOverlay()
                }
                self.overlay.show(
                    tldr: result.tldr,
                    suggestions: self.currentSuggestions
                )
                self.soundEffects.play(.resultReady)
                if result.tldr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && self.currentSuggestions.isEmpty {
                    self.overlay.showSoftError("TLDR came back empty. Try a clearer or more text-heavy window.")
                }
                self.emitEvent(
                    requestID: requestID,
                    type: "overlay_shown",
                    allowLogging: runtime.allowEventLogging,
                    clientMetadata: clientMetadata,
                    details: ["suggestion_count": self.currentSuggestions.count]
                )
            }
        } catch {
            let wasDismissed = DispatchQueue.main.sync {
                self.currentRequestID != requestID
            }
            if wasDismissed {
                return
            }
            PendingRunStore.update(requestID: requestID) { payload in
                payload["last_phase"] = lastPhase
                payload["error"] = self.shortErrorSummary(error)
            }
            emitEvent(
                requestID: requestID,
                type: failureEventType(for: error, lastPhase: lastPhase),
                allowLogging: runtime.allowEventLogging,
                clientMetadata: clientMetadata,
                details: [
                    "last_phase": lastPhase,
                    "error": shortErrorSummary(error),
                ]
            )
            PendingRunStore.finish(requestID: requestID)
            reportFailure(
                title: "TLDR Failed",
                statusText: "failed: \(shortErrorSummary(error))",
                detail: detailedErrorMessage(error)
            )
        }
    }

    private func recordFrameCaptured(_ frame: CapturedFrame, mode: String) {
        guard let active = session else { return }
        updatePendingFrames(active, phase: "capture_succeeded")
        emitEvent(
            requestID: active.requestID,
            type: "capture_frame_added",
            allowLogging: active.runtime.allowEventLogging,
            clientMetadata: active.clientMetadata,
            details: [
                "capture_mode": mode,
                "frame_index": frame.index,
                "frame_count": active.frames.count,
                "capture_ms": frame.captureMS,
                "screenshot": frame.screenshotMeta,
                "image_diagnostics": frame.imageDiagnostics,
            ]
        )
    }

    private func updatePendingFrames(
        _ active: CaptureSession,
        focusedContext: [String: Any]? = nil,
        phase: String? = nil
    ) {
        PendingRunStore.update(requestID: active.requestID) { payload in
            if let phase {
                payload["last_phase"] = phase
            }
            payload["capture_mode"] = active.frames.count > 1 ? "frontmost_window_scroll" : "frontmost_window"
            payload["frontmost_app"] = active.frontmostApp
            payload["screenshot"] = active.frames.first?.screenshotMeta
            payload["image_diagnostics"] = active.frames.first?.imageDiagnostics
            payload["frames"] = self.framePayloads(active.frames)
            if let focusedContext {
                payload["focused_context"] = focusedContext
            }
        }
    }

    private func framePayloads(_ frames: [CapturedFrame]) -> [[String: Any]] {
        frames.map { frame in
            [
                "index": frame.index,
                "screenshot": frame.screenshotMeta,
                "image_diagnostics": frame.imageDiagnostics,
                "captured_at": JSONFiles.isoString(frame.capturedAt),
                "sha256": frame.sha256,
            ]
        }
    }

    @MainActor
    func chooseSuggestion(index: Int) {
        guard currentBundleDir != nil else { return }
        // Picking a suggestion card via click while #4 is focused must drop
        // the field's first responder so the caret and selection tint clear.
        // The gesture recognizer that drives this code path doesn't transfer
        // first responder on its own.
        if index != 3 && choiceState.customInputActive {
            leaveCustomInput()
        }
        switch choiceState.pressNumber(index: index) {
        case .ignored:
            return
        case .expand(let index):
            expandSuggestion(index: index)
        case .copy(let index):
            copySuggestion(index: index)
        case .focusInput:
            overlay.focusCustomInput()
            status("type your own reply")
        }
    }

    @MainActor
    func insertExpandedSuggestion() -> Bool {
        guard currentBundleDir != nil else { return true }
        switch choiceState.pressReturn() {
        case .propagate:
            return false
        case .insert(let index):
            insertSuggestion(index: index)
            return true
        }
    }

    @MainActor
    func insertCustomReplyFromInput() -> Bool {
        guard currentBundleDir != nil else { return true }
        let text = overlay.customInputText
        guard !text.isEmpty else { return false }
        insertCustomReply(text: text)
        return true
    }

    @MainActor
    func leaveCustomInput() {
        guard choiceState.customInputActive else { return }
        choiceState.setCustomInputActive(false)
        overlay.leaveCustomInput()
        status("ready - press 1/2/3 to expand")
    }

    @MainActor
    func performCustomInputShortcut(_ shortcut: TextEditingShortcut) -> Bool {
        overlay.performCustomInputShortcut(shortcut)
    }

    @MainActor
    private func expandSuggestion(index: Int) {
        guard index >= 0 && index < currentSuggestions.count else { return }
        guard overlay.expandSuggestion(index: index) else { return }
        status("suggestion \(index + 1) expanded")
        if let requestID = currentRequestID {
            PendingRunStore.update(requestID: requestID) { payload in
                payload["last_phase"] = "suggestion_expanded"
                payload["expanded_index"] = index + 1
            }
            emitEvent(
                requestID: requestID,
                type: "suggestion_expanded",
                allowLogging: runtimeStore.allowEventLogging,
                clientMetadata: Self.clientMetadata(),
                details: ["chosen_index": index + 1]
            )
        }
    }

    @MainActor
    private func copySuggestion(index: Int) {
        let text = currentSuggestions[index]
        let requestID = currentRequestID
        let clientMetadata = Self.clientMetadata()
        if let requestID {
            terminalEmittedRequestID = requestID
        }
        overlay.close()

        if let requestID {
            emitEvent(
                requestID: requestID,
                type: "suggestion_copied",
                allowLogging: runtimeStore.allowEventLogging,
                clientMetadata: clientMetadata,
                details: ["chosen_index": index + 1]
            )
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status("copied suggestion \(index + 1)")
        soundEffects.play(.copy)
        if let requestID {
            emitEvent(
                requestID: requestID,
                type: "run_completed",
                allowLogging: runtimeStore.allowEventLogging,
                clientMetadata: clientMetadata,
                details: ["outcome": "copied", "chosen_index": index + 1]
            )
            PendingRunStore.finish(requestID: requestID)
        }

        recordChoice(index: index, text: text, action: "copied")
        currentBundleDir = nil
        choiceState = SuggestionChoiceState(suggestionCount: 0)
        let finishingRequestID = requestID
        overlay.confirmCopy { [weak self] in
            guard let self else { return }
            if let finishingRequestID {
                guard self.currentRequestID == finishingRequestID else { return }
            } else {
                guard self.currentRequestID == nil else { return }
            }
            self.overlay.dismissAnimated { [weak self] in
                self?.resetCurrentRun()
            }
        }
    }

    @MainActor
    private func insertSuggestion(index: Int) {
        guard index >= 0 && index < currentSuggestions.count else { return }
        let text = currentSuggestions[index]
        let requestID = currentRequestID
        let clientMetadata = Self.clientMetadata()
        recordChoice(index: index, text: text, action: "inserted")
        currentBundleDir = nil
        choiceState = SuggestionChoiceState(suggestionCount: 0)
        let finishingRequestID = requestID
        status("inserting suggestion \(index + 1)...")

        if let requestID {
            terminalEmittedRequestID = requestID
            PendingRunStore.update(requestID: requestID) { payload in
                payload["last_phase"] = "paste_started"
                payload["chosen_index"] = index + 1
            }
            emitEvent(
                requestID: requestID,
                type: "paste_started",
                allowLogging: runtimeStore.allowEventLogging,
                clientMetadata: clientMetadata,
                details: ["chosen_index": index + 1]
            )
        }

        overlay.confirmInsert { [weak self] in
            guard let self else { return }
            if let finishingRequestID {
                guard self.currentRequestID == finishingRequestID else { return }
            } else {
                guard self.currentRequestID == nil else { return }
            }
            self.overlay.dismissAnimated { [weak self] in
                guard let self else { return }
                // Give NSRunningApplication.activate time to land on the previous
                // frontmost app before we synthesize Cmd+V — otherwise the paste
                // sometimes hits TLDR's still-active panel context instead.
                Inserter.insert(text: text, activationDelay: 0.15) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success:
                        self.status("inserted suggestion \(index + 1)")
                        self.soundEffects.play(.insert)
                        if let requestID {
                            self.emitEvent(
                                requestID: requestID,
                                type: "suggestion_inserted",
                                allowLogging: self.runtimeStore.allowEventLogging,
                                clientMetadata: clientMetadata,
                                details: ["chosen_index": index + 1]
                            )
                            self.emitEvent(
                                requestID: requestID,
                                type: "run_completed",
                                allowLogging: self.runtimeStore.allowEventLogging,
                                clientMetadata: clientMetadata,
                                details: ["outcome": "inserted", "chosen_index": index + 1]
                            )
                            PendingRunStore.finish(requestID: requestID)
                        }
                    case .failure(let error):
                        if let requestID {
                            self.emitEvent(
                                requestID: requestID,
                                type: "paste_failed",
                                allowLogging: self.runtimeStore.allowEventLogging,
                                clientMetadata: clientMetadata,
                                details: [
                                    "chosen_index": index + 1,
                                    "error": self.shortErrorSummary(error),
                                ]
                            )
                            self.emitEvent(
                                requestID: requestID,
                                type: "run_completed",
                                allowLogging: self.runtimeStore.allowEventLogging,
                                clientMetadata: clientMetadata,
                                details: ["outcome": "paste_failed", "chosen_index": index + 1]
                            )
                            PendingRunStore.finish(requestID: requestID)
                        }
                        self.reportFailure(
                            title: "Paste Failed",
                            statusText: "paste failed: \(self.shortErrorSummary(error))",
                            detail: self.detailedErrorMessage(error)
                        )
                    }
                }
                self.resetCurrentRun()
            }
        }
    }

    @MainActor
    private func insertCustomReply(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let requestID = currentRequestID
        let clientMetadata = Self.clientMetadata()
        recordCustomReply(text: trimmed)
        status("nice - inserting your reply...")

        if let requestID {
            PendingRunStore.update(requestID: requestID) { payload in
                payload["last_phase"] = "paste_started"
                payload["chosen_action"] = "user_typed"
                payload["custom_reply_at"] = JSONFiles.isoString()
            }
            emitEvent(
                requestID: requestID,
                type: "paste_started",
                allowLogging: runtimeStore.allowEventLogging,
                clientMetadata: clientMetadata,
                details: ["chosen_action": "user_typed"]
            )
        }

        let pasteRequestID = requestID
        overlay.dismissAnimated { [weak self] in
            guard let self else { return }
            if let pasteRequestID, self.currentRequestID != pasteRequestID {
                return
            }
            if pasteRequestID == nil, self.currentRequestID != nil {
                return
            }
            Inserter.insert(text: trimmed, activationDelay: 0.15) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.status("inserted your reply")
                    self.soundEffects.play(.insert)
                    self.celebrateAtDestinationCaret()
                    if let requestID {
                        self.emitEvent(
                            requestID: requestID,
                            type: "run_completed",
                            allowLogging: self.runtimeStore.allowEventLogging,
                            clientMetadata: clientMetadata,
                            details: ["outcome": "user_typed"]
                        )
                        PendingRunStore.finish(requestID: requestID)
                    }
                case .failure(let error):
                    if let requestID {
                        self.emitEvent(
                            requestID: requestID,
                            type: "paste_failed",
                            allowLogging: self.runtimeStore.allowEventLogging,
                            clientMetadata: clientMetadata,
                            details: [
                                "chosen_action": "user_typed",
                                "error": self.shortErrorSummary(error),
                            ]
                        )
                        self.emitEvent(
                            requestID: requestID,
                            type: "run_completed",
                            allowLogging: self.runtimeStore.allowEventLogging,
                            clientMetadata: clientMetadata,
                            details: ["outcome": "paste_failed", "chosen_action": "user_typed"]
                        )
                        PendingRunStore.finish(requestID: requestID)
                    }
                    self.reportFailure(
                        title: "Paste Failed",
                        statusText: "paste failed: \(self.shortErrorSummary(error))",
                        detail: self.detailedErrorMessage(error)
                    )
                }
            }
            self.resetCurrentRun()
        }
    }

    @MainActor
    private func resetCurrentRun() {
        currentSuggestions = []
        currentBundleDir = nil
        currentRequestID = nil
        terminalEmittedRequestID = nil
        currentStreamingRun = nil
        choiceState = SuggestionChoiceState(suggestionCount: 0)
        overlay.onCustomInputFocusChanged = nil
        overlay.onCustomInsert = nil
        overlay.onCustomInsertKey = nil
        overlay.onLeaveCustomInputKey = nil
        overlay.onTextEditingKey = nil
        overlay.onChoiceKey = nil
        overlay.onInsertKey = nil
        overlay.onDismissKey = nil
    }

    private func celebrateAtDestinationCaret() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard let caret = FocusedContextCapture.caretScreenPoint() else { return }
            ConfettiPanel.fire(at: caret)
        }
    }

    private func isCurrentRequest(_ requestID: String) -> Bool {
        if Thread.isMainThread {
            return currentRequestID == requestID
        }
        return DispatchQueue.main.sync {
            currentRequestID == requestID
        }
    }

    @MainActor
    func dismissOverlay() {
        if isCollectingActive {
            cancelCollectingSession()
            return
        }
        guard overlay.isVisible else { return }
        let requestID = currentRequestID
        let alreadyTerminal = (requestID != nil && requestID == terminalEmittedRequestID)
        currentStreamingRun?.terminate()
        currentStreamingRun = nil
        currentRequestID = nil
        currentBundleDir = nil
        choiceState = SuggestionChoiceState(suggestionCount: 0)
        status("dismissed")
        if !alreadyTerminal {
            recordDismiss()
        }
        if let requestID, !alreadyTerminal {
            let clientMetadata = Self.clientMetadata()
            emitEvent(
                requestID: requestID,
                type: "suggestion_dismissed",
                allowLogging: runtimeStore.allowEventLogging,
                clientMetadata: clientMetadata,
                details: [:]
            )
            emitEvent(
                requestID: requestID,
                type: "run_completed",
                allowLogging: runtimeStore.allowEventLogging,
                clientMetadata: clientMetadata,
                details: ["outcome": "dismissed"]
            )
            PendingRunStore.finish(requestID: requestID)
        }
        overlay.dismissAnimated { [weak self] in
            self?.resetCurrentRun()
        }
    }

    private func makeStagingDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tldr-\(ArtifactWriter.newBundleID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func makeThumbnail(from pngData: Data, maxHeight: CGFloat = 80) -> NSImage? {
        guard let source = NSImage(data: pngData) else { return nil }
        let size = source.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxHeight / size.height)
        let target = NSSize(width: size.width * scale, height: size.height * scale)
        let thumb = NSImage(size: target)
        thumb.lockFocus()
        source.draw(in: NSRect(origin: .zero, size: target))
        thumb.unlockFocus()
        return thumb
    }

    private func replaceFrameFile(at destination: URL, with source: URL) throws {
        _ = try FileManager.default.replaceItemAt(
            destination,
            withItemAt: source,
            backupItemName: nil,
            options: []
        )
    }

    private func makeRequestEnvelope(
        requestID: String,
        runtime: RuntimeConfigFile,
        clientMetadata: [String: Any],
        frontmostApp: [String: Any],
        screenshotMeta: [String: Any],
        diagnostics: [String: Any],
        focusedContext: [String: Any],
        captureMode: String = "frontmost_window",
        frames: [CapturedFrame] = []
    ) -> [String: Any] {
        var preferences = requestPreferences(runtime: runtime)
        preferences["model"] = runtime.model
        return [
            "schema_version": 1,
            "request_id": requestID,
            "client": clientMetadata,
            "capture_mode": captureMode,
            "preferences": preferences,
            "frontmost_app": frontmostApp,
            "input_mode": "screenshot",
            "screenshot": screenshotMeta,
            "frames": framePayloads(frames),
            "image_diagnostics": diagnostics,
            "ocr_packet": NSNull(),
            "focused_context": focusedContext,
            "consent": [
                "allow_event_logging": runtime.allowEventLogging,
                "allow_content_retention": runtime.allowContentRetention,
            ],
        ]
    }

    private func requestPreferences(runtime: RuntimeConfigFile) -> [String: Any] {
        var preferences: [String: Any] = [
            "model": runtime.model,
            "style": "default",
        ]
        if let settingsPath = Paths.settingsPath,
           let settings = JSONFiles.readObject(at: settingsPath) {
            if let temperature = settings["temperature"] {
                preferences["temperature"] = temperature
            }
            if let maxOutputTokens = settings["max_output_tokens"] {
                preferences["max_output_tokens"] = maxOutputTokens
            }
        }
        return preferences
    }

    private func frontmostAppMetadata() -> [String: Any] {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return [:]
        }
        return [
            "bundle_id": app.bundleIdentifier as Any,
            "app_name": app.localizedName as Any,
            "pid": Int(app.processIdentifier),
        ]
    }

    private func failureEventType(for error: Error, lastPhase: String) -> String {
        if let captureError = error as? ScreenCapture.CaptureError,
           case .permissionDenied = captureError {
            return "capture_permission_denied"
        }
        if lastPhase == "request_upload_started" {
            return "request_upload_failed"
        }
        return "capture_failed"
    }

    private func updateRunHostProfile(
        bundleDir: URL,
        requestID: String,
        captureMS: Int,
        pythonMS: Int,
        totalMS: Int,
        result: PythonRunner.ResultPayload
    ) throws {
        let path = bundleDir.appendingPathComponent("host_profile.json")
        var payload = JSONFiles.readObject(at: path) ?? [:]
        payload["request_id"] = requestID
        payload["host_capture_ms"] = captureMS
        payload["host_python_wall_ms"] = pythonMS
        payload["host_total_ms"] = totalMS
        payload["server_duration_ms"] = result.durationMS as Any
        payload["model"] = result.model as Any
        payload["warnings"] = result.warnings
        payload["finished_at"] = JSONFiles.isoString()
        try JSONFiles.writeObject(payload, to: path)
    }

    @MainActor
    private func recordChoice(index: Int, text: String, action: String) {
        guard let bundleDir = currentBundleDir else { return }
        let path = bundleDir.appendingPathComponent("run.json")
        var payload = JSONFiles.readObject(at: path) ?? [:]
        payload["chosen_index"] = index + 1
        payload["chosen_text"] = text
        payload["chosen_at"] = JSONFiles.isoString()
        payload["chosen_action"] = action
        try? JSONFiles.writeObject(payload, to: path)
    }

    @MainActor
    private func recordCustomReply(text: String) {
        guard let bundleDir = currentBundleDir else { return }
        let path = bundleDir.appendingPathComponent("run.json")
        var payload = JSONFiles.readObject(at: path) ?? [:]
        payload["chosen_index"] = NSNull()
        payload["chosen_text"] = NSNull()
        payload["chosen_at"] = JSONFiles.isoString()
        payload["chosen_action"] = "user_typed"
        payload["custom_reply_text"] = text
        payload["custom_reply_at"] = payload["chosen_at"]
        try? JSONFiles.writeObject(payload, to: path)
    }

    private func recordDismiss() {
        guard let bundleDir = currentBundleDir else { return }
        let path = bundleDir.appendingPathComponent("run.json")
        var payload = JSONFiles.readObject(at: path) ?? [:]
        payload["dismissed_at"] = JSONFiles.isoString()
        try? JSONFiles.writeObject(payload, to: path)
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func emitEvent(
        requestID: String,
        type: String,
        allowLogging: Bool,
        clientMetadata: [String: Any],
        details: [String: Any] = [:]
    ) {
        eventClient.send(
            requestID: requestID,
            eventType: type,
            allowLogging: allowLogging,
            clientMetadata: clientMetadata,
            details: details
        )
    }

    private func status(_ text: String) {
        DispatchQueue.main.async {
            self.onStatusChange?(text)
        }
    }

    private func reportFailure(title: String, statusText: String, detail: String) {
        status(statusText)
        DispatchQueue.main.async {
            self.soundEffects.play(.hardError)
            self.onFailureNotice?(title, detail)
        }
    }

    private func shortErrorSummary(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription {
            return localized
        }
        return error.localizedDescription
    }

    private func detailedErrorMessage(_ error: Error) -> String {
        shortErrorSummary(error)
    }

    private func durationMS(since start: DispatchTime) -> Int {
        Int(Double(monotonicNow().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0)
    }

    private func monotonicNow() -> DispatchTime {
        DispatchTime.now()
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
