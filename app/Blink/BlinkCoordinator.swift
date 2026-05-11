import AppKit
import Combine
import CryptoKit
import Foundation
import ScreenCaptureKit

final class BlinkCoordinator {
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
        let frontmostApp: [String: Any]
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
        var collectingTimer: DispatchSourceTimer?
    }

    private struct CapturedFrameResult {
        let frame: CapturedFrame
        let shareableContent: SCShareableContent
    }

    private struct InflightSubmission {
        let token: UUID
        let requestID: String
        var run: PythonRunner.StreamingRun?
    }

    private let config: Config
    private let runtimeStore: RuntimeConfigStore
    private let eventClient: BlinkEventClient
    private let summaryHotkey: Hotkey
    private let soundEffects: SoundEffects
    private let queue = DispatchQueue(label: "blink.coordinator", qos: .userInitiated)
    private let submitQueue = DispatchQueue(label: "blink.coordinator.submit", qos: .userInitiated)
    private let overlay = SuggestionsOverlay()
    private var currentSuggestions: [String] = []
    private var currentSuggestionDetails: [SuggestionDetail] = []
    private var currentBundleDir: URL?
    private var currentRequestID: String?
    // Tracks the request ID for which a terminal event (copied / inserted /
    // paste_failed flow) has already been emitted, so a follow-on dismissOverlay
    // call during the close/insert animation does not emit a redundant
    // suggestion_dismissed and overwrite the server-side outcome.
    private var terminalEmittedRequestID: String?
    private var currentStreamingRun: PythonRunner.StreamingRun?
    // Token for the in-flight Python submission. Used by the double-tap
    // promotion path to mark a specific submission as cancelled without
    // affecting any later submission that reuses the same requestID.
    private var currentSubmission: InflightSubmission?
    private var cancelledSubmissionTokens: Set<UUID> = []
    private var choiceState = SuggestionChoiceState(suggestionCount: 0)
    private var running = false
    private var session: CaptureSession?
    private var pendingDoubleTap: CaptureSession?
    private var doubleTapTimer: DispatchSourceTimer?
    private var pendingDoubleTapRequestID: String?
    private let collectingStateLock = NSLock()
    private var collectingState = false
    private let doubleTapWindowMS = 400
    private let collectingTimeoutSeconds = 8
    private let maxCapturedFrames = 8
    private var onboardingSampleActive = false

    var onStatusChange: ((String) -> Void)?
    var onFailureNotice: ((String, String) -> Void)?
    var onPermissionsNeeded: (() -> Void)?

    /// Combine subject for surfaces that want to subscribe rather than own
    /// the callback (the menubar already owns `onStatusChange`). Mirrors what
    /// `status(_:)` sends — last-write-wins, replays the current value to
    /// new subscribers via `CurrentValueSubject`.
    let statusSubject = CurrentValueSubject<String, Never>("Idle")

    init(
        config: Config,
        runtimeStore: RuntimeConfigStore,
        eventClient: BlinkEventClient,
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
        let name = info["CFBundleName"] as? String ?? "Blink"
        return [
            "app_name": name,
            "app_version": version,
            "app_build": build,
            "bundle_id": Bundle.main.bundleIdentifier ?? "com.henryz2004.blink",
            "install_id": Paths.loadOrCreateInstallID(),
            "platform": "macOS",
            "platform_version": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
    }

    /// Per-invocation client metadata. Merges `source = onboarding_sample`
    /// when the onboarding mock window is the active capture target so the
    /// server can distinguish first-run sample invocations from real ones.
    func clientMetadata() -> [String: Any] {
        var meta = Self.clientMetadata()
        if onboardingSampleActive {
            meta["source"] = "onboarding_sample"
        }
        return meta
    }

    /// The active summary hotkey. Read-only mirror so surfaces (e.g. the
    /// permissions wizard) can render up-to-date copy without owning the
    /// HotkeyManager.
    var currentHotkey: Hotkey { summaryHotkey }

    /// Flips the onboarding-sample flag. Main-thread only; the value is
    /// read on the capture queue at session start, but the queue dispatches
    /// to main for the runtime snapshot so a single hop is sufficient.
    func setOnboardingSampleActive(_ active: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        onboardingSampleActive = active
    }

    private static func requiredPermissionsGranted(caller: String) -> Bool {
        let accessibility = AXIsProcessTrusted()
        let screenRecording = CGPreflightScreenCaptureAccess()
        let inputMonitoring = HotkeyManager.inputMonitoringGranted()
        TCCDiagnostics.log(
            "required_permissions caller=\(caller) accessibility=\(accessibility) screen_recording_preflight=\(screenRecording) input_monitoring=\(inputMonitoring)"
        )
        return accessibility && screenRecording && inputMonitoring
    }

    func summarizeFrontmostWindow() {
        guard Self.requiredPermissionsGranted(caller: "BlinkCoordinator.summarizeFrontmostWindow") else {
            status("permissions needed")
            // HotkeyManager dispatches onSummarize on the main queue, so we
            // can show the wizard inline without another hop.
            onPermissionsNeeded?()
            return
        }
        acknowledgeCaptureHotkey()
        queue.async { [self] in
            if pendingDoubleTap != nil {
                promoteToMultiFrame()
                return
            }
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

    private func acknowledgeCaptureHotkey() {
        DispatchQueue.main.async {
            self.onStatusChange?("capturing window...")
            self.statusSubject.send("capturing window...")
            self.soundEffects.play(.capture)
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

    /// Called from `dismissOverlay` (main) to clean up coordinator-owned
    /// pending double-tap state when the user dismisses while a single-shot
    /// submission is in flight but still inside the double-tap window.
    /// Does NOT remove the staging directory: the Python subprocess may
    /// still be reading the request envelope and screenshot files until
    /// SIGTERM lands. Orphans in `/tmp` get cleaned up by the OS.
    func clearPendingDoubleTap() {
        queue.async { [self] in
            guard pendingDoubleTap != nil else { return }
            doubleTapTimer?.cancel()
            doubleTapTimer = nil
            pendingDoubleTap = nil
        }
    }

    private func setCollectingActive(_ active: Bool) {
        collectingStateLock.lock()
        collectingState = active
        collectingStateLock.unlock()
    }

    private func cancelActiveSession(statusText: String) {
        guard let active = session else { return }
        active.collectingTimer?.cancel()
        session = nil
        // Defensive: a future caller could reach this path while a pending
        // double-tap is also armed (e.g. cancelling a freshly-promoted
        // session). Tear that down so the timer doesn't outlive us.
        doubleTapTimer?.cancel()
        doubleTapTimer = nil
        pendingDoubleTap = nil
        setCollectingActive(false)
        DispatchQueue.main.sync {
            if let submission = self.currentSubmission, submission.requestID == active.requestID {
                self.cancelledSubmissionTokens.insert(submission.token)
                submission.run?.terminate()
                self.currentSubmission = nil
            }
            self.currentStreamingRun = nil
        }
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

        let (runtime, clientMetadata) = DispatchQueue.main.sync {
            (runtimeStore.snapshot, self.clientMetadata())
        }
        let frontmostApp = frontmostAppMetadata()
        let requestID = UUID().uuidString.lowercased()
        let startedAt = Date()
        let staging: URL
        do {
            staging = try makeStagingDir()
        } catch {
            reportFailure(
                title: "Blink Failed",
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
            let captureResult = try captureFrame(index: 0, staging: staging)
            let frame = captureResult.frame
            var sessionFrontmost = frame.frontmostApp
            if sessionFrontmost["bundle_id"] == nil, let bundle = frontmostApp["bundle_id"] {
                sessionFrontmost["bundle_id"] = bundle
            }
            if sessionFrontmost["app_name"] == nil, let name = frontmostApp["app_name"] {
                sessionFrontmost["app_name"] = name
            }
            let active = CaptureSession(
                requestID: requestID,
                startedAt: startedAt,
                startedPerf: monotonicNow(),
                runtime: runtime,
                clientMetadata: clientMetadata,
                frontmostApp: sessionFrontmost,
                staging: staging,
                frames: [frame],
                collectingTimer: nil
            )
            recordFrameCaptured(active, frame: frame, mode: "frontmost_window")
            status("captured frame 1")
            // Single press is the most common case, so submit the session
            // immediately. The double-tap timer keeps the submission
            // promotable into multi-frame mode if a second tap arrives
            // within `doubleTapWindowMS`. Set the coord-queue and main
            // mirrors of the pending state together so dismissOverlay
            // (main) can never observe one without the other.
            pendingDoubleTap = active
            DispatchQueue.main.sync {
                self.pendingDoubleTapRequestID = requestID
            }
            armDoubleTapTimer(requestID: requestID)
            dispatchSubmit(active)
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
                title: "Blink Failed",
                statusText: "failed: \(shortErrorSummary(error))",
                detail: detailedErrorMessage(error)
            )
        }
    }

    private func dispatchSubmit(_ active: CaptureSession) {
        let token = UUID()
        DispatchQueue.main.sync {
            // If an earlier submission is still streaming, abandon it so
            // it doesn't head-of-line-block this submit on the serial
            // submitQueue (and so its tail main blocks don't briefly
            // overwrite this submission's overlay state).
            if let inflight = self.currentSubmission {
                self.cancelledSubmissionTokens.insert(inflight.token)
                inflight.run?.terminate()
            }
            self.currentSubmission = InflightSubmission(
                token: token,
                requestID: active.requestID,
                run: nil
            )
        }
        submitQueue.async { [self] in
            submitCapturedSession(active, submissionToken: token)
        }
    }

    private func promoteToMultiFrame() {
        guard var pending = pendingDoubleTap else { return }
        let requestID = pending.requestID
        doubleTapTimer?.cancel()
        doubleTapTimer = nil
        pendingDoubleTap = nil

        // Mark the in-flight submission cancelled and tear down its UI
        // state so the original submit's still-pending main blocks bail
        // out instead of clobbering the collecting overlay.
        DispatchQueue.main.sync {
            if let submission = self.currentSubmission, submission.requestID == requestID {
                self.cancelledSubmissionTokens.insert(submission.token)
                submission.run?.terminate()
                self.currentSubmission = nil
            }
            self.currentStreamingRun = nil
            self.currentRequestID = nil
            self.pendingDoubleTapRequestID = nil
        }

        emitEvent(
            requestID: requestID,
            type: "capture_promoted_to_multiframe",
            allowLogging: pending.runtime.allowEventLogging,
            clientMetadata: pending.clientMetadata,
            details: ["frame_count": pending.frames.count]
        )

        running = true
        defer { running = false }
        do {
            status("capturing frame \(pending.frames.count + 1)...")
            let captureResult = try captureFrame(
                index: pending.frames.count,
                staging: pending.staging,
                shareableContent: nil,
                preferredPID: nil
            )
            let frame = captureResult.frame
            let isDuplicate: Bool
            if let previous = pending.frames.last, previous.windowID == frame.windowID {
                try replaceFrameFile(at: previous.pngURL, with: frame.pngURL)
                pending.frames[pending.frames.count - 1] = CapturedFrame(
                    index: previous.index,
                    pngURL: previous.pngURL,
                    capturedAt: frame.capturedAt,
                    captureMS: frame.captureMS,
                    windowID: frame.windowID,
                    screenshotMeta: frame.screenshotMeta,
                    imageDiagnostics: frame.imageDiagnostics,
                    sha256: frame.sha256,
                    thumbnail: frame.thumbnail,
                    frontmostApp: frame.frontmostApp
                )
                status("no new content — scroll first")
                isDuplicate = true
            } else {
                pending.frames.append(frame)
                status("collecting \(pending.frames.count) frames")
                isDuplicate = false
            }
            session = pending
            updatePendingFrames(pending)
            recordFrameCaptured(pending, frame: frame, mode: deriveCaptureMode(frames: pending.frames))
            let thumbnails = pending.frames.compactMap(\.thumbnail)
            let collectingMessage = collectingMessage(
                frames: pending.frames,
                duplicate: isDuplicate
            )
            DispatchQueue.main.async {
                self.overlay.showCollecting(
                    frameCount: pending.frames.count,
                    maxFrames: self.maxCapturedFrames,
                    hotkeyDisplay: self.summaryHotkey.displayString,
                    thumbnails: thumbnails,
                    message: collectingMessage,
                    flashLastThumbnail: isDuplicate
                )
            }
            armCollectingTimer(requestID: requestID)
        } catch {
            session = pending
            cancelActiveSession(statusText: "capture failed")
            reportFailure(
                title: "Blink Failed",
                statusText: "failed: \(shortErrorSummary(error))",
                detail: detailedErrorMessage(error)
            )
        }
    }

    private func armDoubleTapTimer(requestID: String) {
        doubleTapTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(doubleTapWindowMS))
        timer.setEventHandler { [weak self] in
            self?.doubleTapWindowExpired(requestID: requestID)
        }
        doubleTapTimer = timer
        timer.resume()
    }

    private func doubleTapWindowExpired(requestID: String) {
        guard let pending = pendingDoubleTap, pending.requestID == requestID else { return }
        pendingDoubleTap = nil
        doubleTapTimer = nil
        DispatchQueue.main.async {
            if self.pendingDoubleTapRequestID == requestID {
                self.pendingDoubleTapRequestID = nil
            }
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
        do {
            status("capturing frame \(active.frames.count + 1)...")
            // Multi-frame is now an explicit double-tap mode that may span
            // any frontmost window or app. Re-query SCShareableContent on
            // every frame so windows from a different app surface as
            // capturable, and let `ScreenCapture` pick whatever is
            // frontmost right now.
            let captureResult = try captureFrame(
                index: active.frames.count,
                staging: active.staging,
                shareableContent: nil,
                preferredPID: nil
            )
            let frame = captureResult.frame
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
                    thumbnail: frame.thumbnail,
                    frontmostApp: frame.frontmostApp
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
            let collectingMsg = collectingMessage(frames: active.frames, duplicate: isDuplicate)
            DispatchQueue.main.async {
                self.overlay.showCollecting(
                    frameCount: active.frames.count,
                    maxFrames: self.maxCapturedFrames,
                    hotkeyDisplay: self.summaryHotkey.displayString,
                    thumbnails: thumbnails,
                    message: collectingMsg,
                    flashLastThumbnail: isDuplicate
                )
            }
            armCollectingTimer(requestID: active.requestID)
        } catch {
            session = active
            cancelActiveSession(statusText: "capture failed")
            reportFailure(title: "Blink Failed", statusText: "failed: \(shortErrorSummary(error))", detail: detailedErrorMessage(error))
        }
    }

    private func submitSession() {
        guard let active = session else { return }
        active.collectingTimer?.cancel()
        session = nil
        setCollectingActive(false)
        dispatchSubmit(active)
    }

    private func captureFrame(
        index: Int,
        staging: URL,
        shareableContent: SCShareableContent? = nil,
        preferredPID: pid_t? = nil
    ) throws -> CapturedFrameResult {
        TCCDiagnostics.log(
            "capture_frame_start index=\(index) preferred_pid=\(preferredPID.map(String.init) ?? "nil") cached_shareable_content=\(shareableContent != nil)"
        )
        let captureStartedPerf = monotonicNow()
        let capture = try ScreenCapture.captureFrontmostWindowSync(
            shareableContent: shareableContent,
            preferredPID: preferredPID
        )
        let captureMS = durationMS(since: captureStartedPerf)
        TCCDiagnostics.log(
            "capture_frame_success index=\(index) capture_ms=\(captureMS) owner_pid=\(capture.ownerPID) owner_bundle_id=\(capture.ownerBundleID ?? "nil") window_id=\(capture.windowID)"
        )
        guard let capturePayload = ImageDiagnostics.makePayload(pngData: capture.pngData) else {
            throw NSError(domain: "BlinkCoordinator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't inspect screenshot metadata."])
        }
        let frameURL = staging.appendingPathComponent("screenshot_\(index).png")
        try capture.pngData.write(to: frameURL, options: .atomic)
        var frontmostApp: [String: Any] = [
            "pid": Int(capture.ownerPID),
            "window_id": Int(capture.windowID),
        ]
        if let bundleID = capture.ownerBundleID {
            frontmostApp["bundle_id"] = bundleID
        }
        if let name = capture.ownerName {
            frontmostApp["app_name"] = name
        }
        if let title = capture.windowTitle, !title.isEmpty {
            frontmostApp["window_title"] = title
        }
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
                thumbnail: Self.makeThumbnail(from: capture.pngData),
                frontmostApp: frontmostApp
            ),
            shareableContent: capture.shareableContent
        )
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

    private func frameInfo(_ frame: CapturedFrame) -> CaptureModeDeriver.FrameInfo {
        CaptureModeDeriver.FrameInfo(
            windowID: frame.windowID,
            pid: frame.frontmostApp["pid"] as? Int,
            appName: frame.frontmostApp["app_name"] as? String,
            bundleID: frame.frontmostApp["bundle_id"] as? String
        )
    }

    private func deriveCaptureMode(frames: [CapturedFrame]) -> String {
        CaptureModeDeriver.captureMode(for: frames.map(frameInfo))
    }

    private func collectingMessage(frames: [CapturedFrame], duplicate: Bool) -> String? {
        CaptureModeDeriver.collectingMessage(
            frames: frames.map(frameInfo),
            duplicate: duplicate
        )
    }

    private func submitCapturedSession(_ active: CaptureSession, submissionToken: UUID) {
        guard let firstFrame = active.frames.first else { return }
        let requestID = active.requestID
        let runtime = active.runtime
        let clientMetadata = active.clientMetadata
        let captureMode = deriveCaptureMode(frames: active.frames)
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

            status("calling Blink backend...")
            DispatchQueue.main.async {
                guard !self.cancelledSubmissionTokens.contains(submissionToken) else { return }
                self.currentRequestID = requestID
                self.currentSuggestions = []
                self.currentSuggestionDetails = []
                self.currentBundleDir = nil
                self.choiceState = SuggestionChoiceState(suggestionCount: 0, allowsCustomInput: false)
                self.overlay.onCustomInputFocusChanged = nil
                self.overlay.onCustomInsert = nil
                self.overlay.onCustomInsertKey = nil
                self.overlay.onLeaveCustomInputKey = nil
                self.overlay.onTextEditingKey = nil
                self.overlay.onRerollKey = nil
                self.overlay.onChoiceKey = { _ in }
                self.overlay.onInsertKey = { true }
                self.overlay.onDismissKey = { [weak self] in
                    self?.dismissOverlay()
                }
                self.overlay.showLoading(tldr: active.frames.count > 1 ? "Reading \(active.frames.count) frames..." : "Reading this screen...")
                if active.frames.contains(where: { ($0.imageDiagnostics["blank_likely"] as? Bool) == true }) {
                    self.overlay.showSoftError("One capture looks blank. Blink will still try to read it.")
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
                        if self.cancelledSubmissionTokens.contains(submissionToken) {
                            run.terminate()
                            return
                        }
                        if var submission = self.currentSubmission, submission.token == submissionToken {
                            submission.run = run
                            self.currentSubmission = submission
                        }
                        self.currentStreamingRun = run
                    }
                },
                onEvent: { event in
                    DispatchQueue.main.async {
                        guard !self.cancelledSubmissionTokens.contains(submissionToken) else { return }
                        guard self.currentRequestID == requestID else { return }
                        switch event {
                        case .phase(let message):
                            self.overlay.updateLoadingPhase(message)
                        case .partialSummary(let text):
                            self.overlay.updateSummary(text)
                        case .partialSuggestions(let list):
                            self.overlay.updateSuggestions(Array(list.prefix(3)))
                        }
                    }
                }
            )
            let streamCompletedAt = Date()
            let firstTokenAt = DispatchQueue.main.sync { self.currentStreamingRun?.firstTokenAt }
            DispatchQueue.main.async {
                if let submission = self.currentSubmission, submission.token == submissionToken {
                    self.currentSubmission = nil
                }
                if self.currentRequestID == requestID {
                    self.currentStreamingRun = nil
                }
            }
            let wasAbandoned = DispatchQueue.main.sync { () -> Bool in
                if self.cancelledSubmissionTokens.remove(submissionToken) != nil {
                    return true
                }
                return self.currentRequestID != requestID
            }
            if wasAbandoned { return }
            let pythonMS = durationMS(since: pythonStartedPerf)
            let totalMS = durationMS(since: active.startedPerf)

            let bundleDir = URL(fileURLWithPath: result.bundleDir)
            try updateRunHostProfile(
                bundleDir: bundleDir,
                requestID: requestID,
                captureMS: captureMS,
                pythonMS: pythonMS,
                totalMS: totalMS,
                result: result,
                firstTokenAt: firstTokenAt,
                streamCompletedAt: streamCompletedAt
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
                self.currentSuggestionDetails = self.normalizedSuggestionDetails(
                    result.suggestionDetails,
                    fallbackSuggestions: result.suggestions,
                    draft: focusedSnapshot.meaningfulDraftText ?? ""
                )
                self.currentSuggestions = self.currentSuggestionDetails.map(\.text)
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
                self.overlay.onRerollKey = { [weak self] in
                    self?.rerollCurrentSuggestions()
                }
                self.overlay.onDismissKey = { [weak self] in
                    self?.dismissOverlay()
                }
                if self.overlay.isStreamingActive {
                    // Streaming already populated the panel via updateSummary
                    // and updateSuggestions. Calling show() here would close
                    // and rebuild the entire NSPanel, producing a whole-UI
                    // flicker. Push the final values through the in-place
                    // update entry points instead.
                    self.overlay.updateSummary(result.tldr)
                    self.overlay.updateSuggestionDetails(self.currentSuggestionDetails)
                } else {
                    self.overlay.show(
                        tldr: result.tldr,
                        suggestionDetails: self.currentSuggestionDetails
                    )
                }
                self.soundEffects.play(.resultReady)
                if result.tldr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && self.currentSuggestions.isEmpty {
                    self.overlay.showSoftError("Blink came back empty. Try a clearer or more text-heavy window.")
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
            let wasAbandoned = DispatchQueue.main.sync { () -> Bool in
                if self.cancelledSubmissionTokens.remove(submissionToken) != nil {
                    return true
                }
                return self.currentRequestID != requestID
            }
            if wasAbandoned {
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
                title: "Blink Failed",
                statusText: "failed: \(shortErrorSummary(error))",
                detail: detailedErrorMessage(error)
            )
        }
    }

    @MainActor
    func rerollCurrentSuggestions() {
        guard overlay.isVisible,
              let sourceBundleDir = currentBundleDir,
              let sourceRequestID = currentRequestID,
              !currentSuggestions.isEmpty
        else {
            return
        }
        if currentStreamingRun?.isRunning == true {
            status("already rerolling")
            return
        }
        let screenshotURLs = rerollScreenshotURLs(in: sourceBundleDir)
        guard !screenshotURLs.isEmpty else {
            overlay.showSoftError("Can't reroll this one. The saved screenshot is missing.")
            return
        }
        let requestID = UUID().uuidString.lowercased()
        let clientMetadata = self.clientMetadata()
        let runtime = runtimeStore.snapshot
        let allowEventLogging = runtime.allowEventLogging
        let startedAt = Date()
        let pendingPayload: [String: Any] = [
            "request_id": requestID,
            "started_at": JSONFiles.isoString(startedAt),
            "updated_at": JSONFiles.isoString(startedAt),
            "last_phase": "reroll_started",
            "client": clientMetadata,
            "capture_mode": "frontmost_window",
            "input_mode": "screenshot",
            "source_request_id": sourceRequestID,
            "source_bundle_dir": sourceBundleDir.path,
            "frames": screenshotURLs.map(\.lastPathComponent),
        ]
        do {
            try PendingRunStore.create(requestID: requestID, payload: pendingPayload)
        } catch {
            overlay.showSoftError("Couldn't prepare a reroll.")
            status("reroll failed")
            return
        }
        let priorSuggestions = currentSuggestionDetails.isEmpty
            ? currentSuggestions.map(SuggestionDetail.plain)
            : currentSuggestionDetails
        let runtimeURL: URL
        let hostProfileURL = sourceBundleDir.appendingPathComponent("host_profile.json")
        let tempDir: URL
        do {
            tempDir = try makeStagingDir()
            runtimeURL = tempDir.appendingPathComponent("runtime.json")
            try writeJSON(runtime, to: runtimeURL)
            var requestEnvelope = JSONFiles.readObject(at: sourceBundleDir.appendingPathComponent("request.json")) ?? [:]
            requestEnvelope["request_id"] = requestID
            requestEnvelope.removeValue(forKey: "stateful_context")
            // Keep full prior suggestions in the local request.json so the direct local runner can reroll without a server store. The Python proxy path trims this to schema_version + source_request_id before upload.
            requestEnvelope["reroll_context"] = [
                "schema_version": 1,
                "source_request_id": sourceRequestID,
                "previous_suggestions": currentSuggestions,
                "previous_suggestion_details": priorSuggestions.map { detail in
                    [
                        "text": detail.text,
                        "tags": detail.tags,
                    ]
                },
            ]
            try JSONFiles.writeObject(
                requestEnvelope,
                to: tempDir.appendingPathComponent("request.json")
            )
        } catch {
            PendingRunStore.finish(requestID: requestID)
            overlay.showSoftError("Couldn't prepare a reroll.")
            status("reroll failed")
            return
        }

        terminalEmittedRequestID = sourceRequestID
        emitEvent(
            requestID: sourceRequestID,
            type: "run_completed",
            allowLogging: allowEventLogging,
            clientMetadata: clientMetadata,
            details: ["outcome": "rerolled"]
        )
        PendingRunStore.finish(requestID: sourceRequestID)

        let token = UUID()
        if let inflight = currentSubmission {
            cancelledSubmissionTokens.insert(inflight.token)
            inflight.run?.terminate()
        }
        currentSubmission = InflightSubmission(token: token, requestID: requestID, run: nil)
        currentStreamingRun = nil
        currentRequestID = requestID
        currentBundleDir = nil
        currentSuggestions = []
        currentSuggestionDetails = []
        choiceState = SuggestionChoiceState(suggestionCount: 0, allowsCustomInput: false)
        overlay.onChoiceKey = { _ in }
        overlay.onInsertKey = { true }
        overlay.onCustomInputFocusChanged = nil
        overlay.onCustomInsert = nil
        overlay.onCustomInsertKey = nil
        overlay.onLeaveCustomInputKey = nil
        overlay.onTextEditingKey = nil
        overlay.onRerollKey = nil
        overlay.onDismissKey = { [weak self] in
            self?.dismissOverlay()
        }
        overlay.beginSuggestionRefresh()
        status("rerolling suggestions...")
        emitEvent(
            requestID: requestID,
            type: "reroll_started",
            allowLogging: allowEventLogging,
            clientMetadata: clientMetadata,
            details: [
                "source_request_id": sourceRequestID,
                "previous_suggestion_count": priorSuggestions.count,
            ]
        )

        let requestURL = tempDir.appendingPathComponent("request.json")
        let rerollStartedPerf = monotonicNow()
        submitQueue.async { [self] in
            do {
                let result = try PythonRunner.runOnceStreaming(
                    config: config,
                    screenshotPNGs: screenshotURLs,
                    runtimeJSON: runtimeURL,
                    settingsJSON: Paths.settingsPath,
                    prompt: Paths.promptPath,
                    requestJSON: requestURL,
                    outputParent: Paths.runsDir,
                    hostProfileJSON: hostProfileURL,
                    onRunStarted: { run in
                        DispatchQueue.main.async {
                            if self.cancelledSubmissionTokens.contains(token) {
                                run.terminate()
                                return
                            }
                            if var submission = self.currentSubmission, submission.token == token {
                                submission.run = run
                                self.currentSubmission = submission
                            }
                            self.currentStreamingRun = run
                        }
                    },
                    onEvent: { event in
                        DispatchQueue.main.async {
                            guard !self.cancelledSubmissionTokens.contains(token) else { return }
                            guard self.currentRequestID == requestID else { return }
                            switch event {
                            case .phase:
                                break
                            case .partialSummary:
                                break
                            case .partialSuggestions(let list):
                                self.overlay.updateSuggestions(Array(list.prefix(3)))
                            }
                        }
                    }
                )
                let streamCompletedAt = Date()
                let firstTokenAt = DispatchQueue.main.sync { self.currentStreamingRun?.firstTokenAt }
                DispatchQueue.main.async {
                    if let submission = self.currentSubmission, submission.token == token {
                        self.currentSubmission = nil
                    }
                    if self.currentRequestID == requestID {
                        self.currentStreamingRun = nil
                    }
                }
                let wasAbandoned = DispatchQueue.main.sync { () -> Bool in
                    if self.cancelledSubmissionTokens.remove(token) != nil {
                        return true
                    }
                    return self.currentRequestID != requestID
                }
                if wasAbandoned { return }

                let pythonMS = durationMS(since: rerollStartedPerf)
                let bundleDir = URL(fileURLWithPath: result.bundleDir)
                try updateRunHostProfile(
                    bundleDir: bundleDir,
                    requestID: requestID,
                    captureMS: 0,
                    pythonMS: pythonMS,
                    totalMS: pythonMS,
                    result: result,
                    firstTokenAt: firstTokenAt,
                    streamCompletedAt: streamCompletedAt
                )
                emitEvent(
                    requestID: requestID,
                    type: "server_response_received",
                    allowLogging: allowEventLogging,
                    clientMetadata: clientMetadata,
                    details: [
                        "duration_ms": result.durationMS as Any,
                        "warnings": result.warnings,
                        "model": result.model as Any,
                        "reroll": true,
                    ]
                )

                DispatchQueue.main.async {
                    guard self.currentRequestID == requestID else { return }
                    self.currentSuggestionDetails = self.normalizedSuggestionDetails(
                        result.suggestionDetails,
                        fallbackSuggestions: result.suggestions,
                        draft: ""
                    )
                    self.currentSuggestions = self.currentSuggestionDetails.map(\.text)
                    self.currentBundleDir = bundleDir
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
                    self.overlay.onRerollKey = { [weak self] in
                        self?.rerollCurrentSuggestions()
                    }
                    self.overlay.onDismissKey = { [weak self] in
                        self?.dismissOverlay()
                    }
                    if self.overlay.isStreamingActive {
                        self.overlay.updateSuggestionDetails(self.currentSuggestionDetails)
                    } else {
                        self.overlay.show(
                            tldr: result.tldr,
                            suggestionDetails: self.currentSuggestionDetails
                        )
                    }
                    self.soundEffects.play(.resultReady)
                    self.status("ready - press 1/2/3 to expand")
                    self.emitEvent(
                        requestID: requestID,
                        type: "overlay_shown",
                        allowLogging: allowEventLogging,
                        clientMetadata: clientMetadata,
                        details: ["suggestion_count": self.currentSuggestions.count, "reroll": true]
                    )
                }
            } catch {
                let wasAbandoned = DispatchQueue.main.sync { () -> Bool in
                    if self.cancelledSubmissionTokens.remove(token) != nil {
                        return true
                    }
                    return self.currentRequestID != requestID
                }
                if wasAbandoned { return }
                emitEvent(
                    requestID: requestID,
                    type: "request_upload_failed",
                    allowLogging: allowEventLogging,
                    clientMetadata: clientMetadata,
                    details: [
                        "reroll": true,
                        "error": shortErrorSummary(error),
                    ]
                )
                DispatchQueue.main.async {
                    self.overlay.endSuggestionRefresh()
                }
                reportFailure(
                    title: "Blink Failed",
                    statusText: "reroll failed: \(shortErrorSummary(error))",
                    detail: detailedErrorMessage(error)
                )
            }
        }
    }

    private func rerollScreenshotURLs(in bundleDir: URL) -> [URL] {
        if let frameLogs = JSONFiles.readArray(at: bundleDir.appendingPathComponent("frames.json")) {
            let urls = frameLogs.compactMap { item -> (Int, URL)? in
                guard let object = item as? [String: Any],
                      let index = object["index"] as? Int,
                      let filename = object["filename"] as? String
                else {
                    return nil
                }
                let url = bundleDir.appendingPathComponent(filename)
                return FileManager.default.fileExists(atPath: url.path) ? (index, url) : nil
            }
            let sorted = urls.sorted { $0.0 < $1.0 }.map(\.1)
            if !sorted.isEmpty {
                return sorted
            }
        }
        let fallback = bundleDir.appendingPathComponent("screenshot.png")
        return FileManager.default.fileExists(atPath: fallback.path) ? [fallback] : []
    }

    private func normalizedSuggestionDetails(
        _ details: [SuggestionDetail],
        fallbackSuggestions: [String],
        draft: String
    ) -> [SuggestionDetail] {
        let source = details.isEmpty ? fallbackSuggestions.map(SuggestionDetail.plain) : details
        return Array(source.prefix(3)).enumerated().map { offset, detail in
            let text = SuggestionPrefixStripper.stripDuplicatedDraftPrefix(
                from: detail.text,
                draft: draft
            )
            return SuggestionDetail(
                text: text,
                tags: normalizedSuggestionTags(detail.tags, text: text, index: offset)
            )
        }
    }

    private func normalizedSuggestionTags(_ tags: [String], text: String, index: Int) -> [String] {
        let trimmed = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !trimmed.isEmpty {
            return Array(trimmed.prefix(2))
        }
        return [fallbackSuggestionTag(for: text, index: index)]
    }

    private func fallbackSuggestionTag(for text: String, index: Int) -> String {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized.contains("?")
            || normalized.hasPrefix("can you")
            || normalized.hasPrefix("could you")
            || normalized.hasPrefix("would you")
            || normalized.hasPrefix("please") {
            return "Ask"
        }
        if normalized.hasPrefix("wait")
            || normalized.hasPrefix("hold on")
            || normalized.hasPrefix("i don't")
            || normalized.hasPrefix("no,") {
            return "Pushback"
        }
        if normalized.hasPrefix("show me")
            || normalized.hasPrefix("check")
            || normalized.hasPrefix("fix")
            || normalized.hasPrefix("add")
            || normalized.hasPrefix("update")
            || normalized.hasPrefix("implement")
            || normalized.hasPrefix("push") {
            return "Next step"
        }
        return ["Reply", "Ask", "Next step"][min(max(index, 0), 2)]
    }

    private func recordFrameCaptured(_ active: CaptureSession, frame: CapturedFrame, mode: String) {
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
                "frontmost_app": frame.frontmostApp,
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
            payload["capture_mode"] = self.deriveCaptureMode(frames: active.frames)
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
                "frontmost_app": frame.frontmostApp,
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
                // sometimes hits Blink's still-active panel context instead.
                Inserter.insert(text: text, activationDelay: 0.15) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success(let outcome):
                        switch outcome {
                        case .pasted:
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
                        case .skippedNoTextTarget:
                            self.status("paste skipped - still on clipboard")
                            self.overlay.confirmPasteFallback()
                            if let requestID {
                                self.emitEvent(
                                    requestID: requestID,
                                    type: "paste_skipped",
                                    allowLogging: self.runtimeStore.allowEventLogging,
                                    clientMetadata: clientMetadata,
                                    details: [
                                        "chosen_index": index + 1,
                                        "reason": "no_text_target",
                                    ]
                                )
                                self.emitEvent(
                                    requestID: requestID,
                                    type: "run_completed",
                                    allowLogging: self.runtimeStore.allowEventLogging,
                                    clientMetadata: clientMetadata,
                                    details: ["outcome": "paste_skipped", "chosen_index": index + 1]
                                )
                                PendingRunStore.finish(requestID: requestID)
                            }
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
        let modalCaret = overlay.customInputCaretScreenPoint()
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
                case .success(let outcome):
                    switch outcome {
                    case .pasted:
                        self.status("inserted your reply")
                        self.soundEffects.play(.insert)
                        self.celebrateAtDestinationCaret(modalFallback: modalCaret)
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
                    case .skippedNoTextTarget:
                        self.status("paste skipped - still on clipboard")
                        self.overlay.confirmPasteFallback()
                        if let requestID {
                            self.emitEvent(
                                requestID: requestID,
                                type: "paste_skipped",
                                allowLogging: self.runtimeStore.allowEventLogging,
                                clientMetadata: clientMetadata,
                                details: [
                                    "chosen_action": "user_typed",
                                    "reason": "no_text_target",
                                ]
                            )
                            self.emitEvent(
                                requestID: requestID,
                                type: "run_completed",
                                allowLogging: self.runtimeStore.allowEventLogging,
                                clientMetadata: clientMetadata,
                                details: ["outcome": "paste_skipped", "chosen_action": "user_typed"]
                            )
                            PendingRunStore.finish(requestID: requestID)
                        }
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
        currentSuggestionDetails = []
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
        overlay.onRerollKey = nil
        overlay.onChoiceKey = nil
        overlay.onInsertKey = nil
        overlay.onDismissKey = nil
    }

    private func celebrateAtDestinationCaret(modalFallback: CGPoint? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            if let caret = FocusedContextCapture.caretScreenPoint() {
                ConfettiPanel.fire(at: caret)
            } else if let fallback = modalFallback {
                ConfettiPanel.fire(at: fallback)
            }
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
        let pendingRequestID = pendingDoubleTapRequestID
        let overlayWasVisible = overlay.isVisible
        guard overlayWasVisible || pendingRequestID != nil else { return }
        let resolvedRequestID = currentRequestID ?? pendingRequestID
        let alreadyTerminal = (resolvedRequestID != nil && resolvedRequestID == terminalEmittedRequestID)
        let streamingRun = currentStreamingRun
        let cancelledBundleDir = streamingRun?.bundleDir
        let cancelledFirstTokenAt = streamingRun?.firstTokenAt
        let cancelledMidStream = streamingRun?.isRunning == true
            && streamingRun?.finalReceived == false
        if let submission = currentSubmission {
            cancelledSubmissionTokens.insert(submission.token)
            submission.run?.terminate()
            currentSubmission = nil
        }
        streamingRun?.terminate()
        currentStreamingRun = nil
        let dismissedWithoutOverlay = !overlayWasVisible && pendingRequestID != nil
        currentRequestID = nil
        pendingDoubleTapRequestID = nil
        currentBundleDir = nil
        currentSuggestions = []
        currentSuggestionDetails = []
        if cancelledMidStream,
           let requestID = resolvedRequestID,
           let bundleDirString = cancelledBundleDir {
            recordStreamCancelled(
                bundleDir: URL(fileURLWithPath: bundleDirString),
                requestID: requestID,
                firstTokenAt: cancelledFirstTokenAt
            )
        }
        choiceState = SuggestionChoiceState(suggestionCount: 0)
        // Coordinator-side pending double-tap state lives on its own queue;
        // tear it down so a follow-on hotkey starts a fresh single-shot
        // session instead of trying to promote a session whose UI was
        // already dismissed.
        clearPendingDoubleTap()
        status("dismissed")
        if !alreadyTerminal && !dismissedWithoutOverlay {
            recordDismiss()
        }
        if let requestID = resolvedRequestID, !alreadyTerminal {
            let clientMetadata = Self.clientMetadata()
            // Esc inside the double-tap window cancels a submission that
            // never rendered a suggestion to the user. Reporting it as a
            // suggestion_dismissed misleads downstream analytics, so emit
            // the cancellation event family instead.
            if dismissedWithoutOverlay {
                emitEvent(
                    requestID: requestID,
                    type: "capture_cancelled",
                    allowLogging: runtimeStore.allowEventLogging,
                    clientMetadata: clientMetadata,
                    details: ["phase": "double_tap_window"]
                )
                emitEvent(
                    requestID: requestID,
                    type: "run_completed",
                    allowLogging: runtimeStore.allowEventLogging,
                    clientMetadata: clientMetadata,
                    details: ["outcome": "cancelled"]
                )
            } else {
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
            }
            PendingRunStore.finish(requestID: requestID)
        }
        overlay.dismissAnimated { [weak self] in
            self?.resetCurrentRun()
        }
    }

    private func makeStagingDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blink-\(ArtifactWriter.newBundleID())", isDirectory: true)
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
        if let level = runtime.thinkingLevel, !level.isEmpty {
            preferences["thinking_level"] = level
        }
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

    private func recordStreamCancelled(
        bundleDir: URL,
        requestID: String,
        firstTokenAt: Date?
    ) {
        let path = bundleDir.appendingPathComponent("host_profile.json")
        var payload = JSONFiles.readObject(at: path) ?? [:]
        payload["request_id"] = requestID
        payload["cancelled_at"] = JSONFiles.isoString()
        if let firstTokenAt {
            payload["first_token_at"] = JSONFiles.isoString(firstTokenAt)
        }
        try? JSONFiles.writeObject(payload, to: path)
    }

    private func updateRunHostProfile(
        bundleDir: URL,
        requestID: String,
        captureMS: Int,
        pythonMS: Int,
        totalMS: Int,
        result: PythonRunner.ResultPayload,
        firstTokenAt: Date?,
        streamCompletedAt: Date?
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
        if let firstTokenAt {
            payload["first_token_at"] = JSONFiles.isoString(firstTokenAt)
        }
        if let streamCompletedAt {
            payload["stream_completed_at"] = JSONFiles.isoString(streamCompletedAt)
        }
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
            self.statusSubject.send(text)
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
