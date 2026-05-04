import AppKit
import Foundation

final class TLDRCoordinator {
    private let config: Config
    private let runtimeStore: RuntimeConfigStore
    private let eventClient: TLDREventClient
    private let queue = DispatchQueue(label: "tldr.coordinator", qos: .userInitiated)
    private let overlay = SuggestionsOverlay()
    private var currentSuggestions: [String] = []
    private var currentBundleDir: URL?
    private var currentRequestID: String?
    private var currentStreamingRun: PythonRunner.StreamingRun?
    private var choiceState = SuggestionChoiceState(suggestionCount: 0)
    private var running = false

    var onStatusChange: ((String) -> Void)?
    var onFailureNotice: ((String, String) -> Void)?

    init(config: Config, runtimeStore: RuntimeConfigStore, eventClient: TLDREventClient) {
        self.config = config
        self.runtimeStore = runtimeStore
        self.eventClient = eventClient
    }

    var isOverlayActive: Bool {
        overlay.isVisible
    }

    var isCustomInputActive: Bool {
        choiceState.customInputActive
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
            running = true
            defer { running = false }

            let runtime = DispatchQueue.main.sync { runtimeStore.snapshot }
            let clientMetadata = Self.clientMetadata()
            let frontmostApp = frontmostAppMetadata()
            let requestID = UUID().uuidString.lowercased()
            let startedAt = Date()
            let startedPerf = monotonicNow()
            var lastPhase = "capture_started"

            let pendingPayload: [String: Any] = [
                "request_id": requestID,
                "started_at": JSONFiles.isoString(startedAt),
                "updated_at": JSONFiles.isoString(startedAt),
                "last_phase": lastPhase,
                "client": clientMetadata,
                "capture_mode": "frontmost_window",
                "input_mode": "screenshot",
                "frontmost_app": frontmostApp,
            ]

            do {
                try PendingRunStore.create(requestID: requestID, payload: pendingPayload)
            } catch {
                status("failed to prepare run metadata")
                DispatchQueue.main.async {
                    self.onFailureNotice?("TLDR Failed", "Couldn't create the pending-run record: \(error.localizedDescription)")
                }
                return
            }

            emitEvent(
                requestID: requestID,
                type: "capture_started",
                allowLogging: runtime.allowEventLogging,
                clientMetadata: clientMetadata,
                details: ["frontmost_app": frontmostApp]
            )
            status("capturing window...")

            do {
                let captureStartedPerf = monotonicNow()
                let capture = try ScreenCapture.captureFrontmostWindowSync()
                let captureMS = durationMS(since: captureStartedPerf)
                let focusedSnapshot = FocusedContextCapture.captureSnapshot(
                    allowContentRetention: runtime.allowContentRetention
                )
                let focusedContext = focusedSnapshot.uploadPayload
                guard let capturePayload = ImageDiagnostics.makePayload(pngData: capture.pngData) else {
                    throw NSError(domain: "TLDRCoordinator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't inspect screenshot metadata."])
                }
                let screenshotMeta = capturePayload.screenshot
                let diagnostics = capturePayload.diagnostics

                let staging = try makeStagingDir()
                let screenshotURL = staging.appendingPathComponent("screenshot.png")
                let runtimeURL = staging.appendingPathComponent("runtime.json")
                let hostProfileURL = staging.appendingPathComponent("host_profile.json")
                let requestURL = staging.appendingPathComponent("request.json")
                try capture.pngData.write(to: screenshotURL, options: .atomic)
                try writeJSON(runtime, to: runtimeURL)

                let requestEnvelope = makeRequestEnvelope(
                    requestID: requestID,
                    runtime: runtime,
                    clientMetadata: clientMetadata,
                    frontmostApp: frontmostApp,
                    screenshotMeta: screenshotMeta,
                    diagnostics: diagnostics,
                    focusedContext: focusedContext
                )
                try JSONFiles.writeObject(requestEnvelope, to: requestURL)

                let hostProfile: [String: Any] = [
                    "request_id": requestID,
                    "started_at": JSONFiles.isoString(startedAt),
                    "capture_ms": captureMS,
                    "window_frame_points": [
                        "x": capture.windowFramePoints.origin.x,
                        "y": capture.windowFramePoints.origin.y,
                        "width": capture.windowFramePoints.width,
                        "height": capture.windowFramePoints.height,
                    ],
                    "frontmost_app": frontmostApp,
                    "client": clientMetadata,
                    "image_diagnostics": diagnostics,
                ]
                try JSONFiles.writeObject(hostProfile, to: hostProfileURL)

                lastPhase = "capture_succeeded"
                PendingRunStore.update(requestID: requestID) { payload in
                    payload["last_phase"] = lastPhase
                    payload["screenshot"] = screenshotMeta
                    payload["image_diagnostics"] = diagnostics
                    payload["focused_context"] = focusedContext
                }
                emitEvent(
                    requestID: requestID,
                    type: "capture_succeeded",
                    allowLogging: runtime.allowEventLogging,
                    clientMetadata: clientMetadata,
                    details: [
                        "capture_ms": captureMS,
                        "screenshot": screenshotMeta,
                        "image_diagnostics": diagnostics,
                    ]
                )
                if (diagnostics["blank_likely"] as? Bool) == true {
                    emitEvent(
                        requestID: requestID,
                        type: "capture_blank_detected",
                        allowLogging: runtime.allowEventLogging,
                        clientMetadata: clientMetadata,
                        details: ["image_diagnostics": diagnostics]
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
                    details: ["input_mode": "screenshot"]
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
                    self.overlay.showLoading(tldr: "Reading this screen...")
                }
                let pythonStartedPerf = monotonicNow()
                let result = try PythonRunner.runOnceStreaming(
                    config: config,
                    screenshotPNG: screenshotURL,
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
                                self.overlay.updateSummary(message)
                            case .partialTLDR(let text):
                                self.overlay.updateSummary(text)
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
                let totalMS = durationMS(since: startedPerf)

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
                let eventType = failureEventType(for: error, lastPhase: lastPhase)
                emitEvent(
                    requestID: requestID,
                    type: eventType,
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
    }

    @MainActor
    func chooseSuggestion(index: Int) {
        guard currentBundleDir != nil else { return }
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
        resetCurrentRun()
    }

    @MainActor
    private func insertSuggestion(index: Int) {
        guard index >= 0 && index < currentSuggestions.count else { return }
        let text = currentSuggestions[index]
        let requestID = currentRequestID
        let clientMetadata = Self.clientMetadata()
        overlay.close()
        recordChoice(index: index, text: text, action: "inserted")
        status("inserting suggestion \(index + 1)...")

        if let requestID {
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

        // Give NSRunningApplication.activate time to land on the previous
        // frontmost app before we synthesize Cmd+V — otherwise the paste
        // sometimes hits TLDR's still-active panel context instead.
        Inserter.insert(text: text, activationDelay: 0.15) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.status("inserted suggestion \(index + 1)")
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

        resetCurrentRun()
    }

    @MainActor
    private func insertCustomReply(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let requestID = currentRequestID
        let clientMetadata = Self.clientMetadata()
        overlay.close()
        recordCustomReply(text: trimmed)
        status("inserting your reply...")

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

        Inserter.insert(text: trimmed, activationDelay: 0.15) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.status("inserted your reply")
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

        resetCurrentRun()
    }

    @MainActor
    private func resetCurrentRun() {
        currentSuggestions = []
        currentBundleDir = nil
        currentRequestID = nil
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
        guard overlay.isVisible else { return }
        let requestID = currentRequestID
        currentStreamingRun?.terminate()
        currentStreamingRun = nil
        overlay.close()
        status("dismissed")
        recordDismiss()
        if let requestID {
            let clientMetadata = Self.clientMetadata()
            emitEvent(
                requestID: requestID,
                type: "overlay_dismissed",
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
        resetCurrentRun()
    }

    private func makeStagingDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tldr-\(ArtifactWriter.newBundleID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeRequestEnvelope(
        requestID: String,
        runtime: RuntimeConfigFile,
        clientMetadata: [String: Any],
        frontmostApp: [String: Any],
        screenshotMeta: [String: Any],
        diagnostics: [String: Any],
        focusedContext: [String: Any]
    ) -> [String: Any] {
        var preferences = requestPreferences(runtime: runtime)
        preferences["model"] = runtime.model
        return [
            "schema_version": 1,
            "request_id": requestID,
            "client": clientMetadata,
            "capture_mode": "frontmost_window",
            "preferences": preferences,
            "frontmost_app": frontmostApp,
            "input_mode": "screenshot",
            "screenshot": screenshotMeta,
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
}
