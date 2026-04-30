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
                let focusedContext = FocusedContextCapture.capture(
                    allowContentRetention: runtime.allowContentRetention
                )
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
                let pythonStartedPerf = monotonicNow()
                let result = try PythonRunner.runOnceSync(
                    config: config,
                    screenshotPNG: screenshotURL,
                    runtimeJSON: runtimeURL,
                    settingsJSON: Paths.settingsPath,
                    prompt: Paths.promptPath,
                    requestJSON: requestURL,
                    outputParent: Paths.runsDir,
                    hostProfileJSON: hostProfileURL
                )
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

                status("ready - press 1/2/3")
                DispatchQueue.main.async {
                    self.currentSuggestions = result.suggestions
                    self.currentBundleDir = bundleDir
                    self.currentRequestID = requestID
                    self.overlay.show(
                        tldr: result.tldr,
                        suggestions: result.suggestions,
                        autoPaste: self.runtimeStore.autoPaste
                    )
                    self.emitEvent(
                        requestID: requestID,
                        type: "overlay_shown",
                        allowLogging: runtime.allowEventLogging,
                        clientMetadata: clientMetadata,
                        details: ["auto_paste": self.runtimeStore.autoPaste]
                    )
                }
            } catch {
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
        guard index >= 0 && index < currentSuggestions.count else { return }
        let text = currentSuggestions[index]
        let requestID = currentRequestID
        let clientMetadata = Self.clientMetadata()
        overlay.close()

        if let requestID {
            emitEvent(
                requestID: requestID,
                type: "suggestion_chosen",
                allowLogging: runtimeStore.allowEventLogging,
                clientMetadata: clientMetadata,
                details: [
                    "chosen_index": index + 1,
                    "auto_paste": runtimeStore.autoPaste,
                ]
            )
        }

        if runtimeStore.autoPaste {
            status("pasting suggestion \(index + 1)...")
            if let requestID {
                emitEvent(
                    requestID: requestID,
                    type: "paste_started",
                    allowLogging: runtimeStore.allowEventLogging,
                    clientMetadata: clientMetadata,
                    details: ["chosen_index": index + 1]
                )
            }
            Inserter.insert(text: text) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.status("pasted suggestion \(index + 1)")
                    if let requestID {
                        self.emitEvent(
                            requestID: requestID,
                            type: "run_completed",
                            allowLogging: self.runtimeStore.allowEventLogging,
                            clientMetadata: clientMetadata,
                            details: ["outcome": "pasted", "chosen_index": index + 1]
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
                            details: ["outcome": "paste_failed"]
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
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            status("copied suggestion \(index + 1)")
            if let requestID {
                emitEvent(
                    requestID: requestID,
                    type: "copy_completed",
                    allowLogging: runtimeStore.allowEventLogging,
                    clientMetadata: clientMetadata,
                    details: ["chosen_index": index + 1]
                )
                emitEvent(
                    requestID: requestID,
                    type: "run_completed",
                    allowLogging: runtimeStore.allowEventLogging,
                    clientMetadata: clientMetadata,
                    details: ["outcome": "copied", "chosen_index": index + 1]
                )
                PendingRunStore.finish(requestID: requestID)
            }
        }

        recordChoice(index: index, text: text)
        currentSuggestions = []
        currentBundleDir = nil
        currentRequestID = nil
    }

    @MainActor
    func dismissOverlay() {
        guard overlay.isVisible else { return }
        let requestID = currentRequestID
        overlay.close()
        status("dismissed")
        recordDismiss()
        if let requestID {
            emitEvent(
                requestID: requestID,
                type: "run_completed",
                allowLogging: runtimeStore.allowEventLogging,
                clientMetadata: Self.clientMetadata(),
                details: ["outcome": "dismissed"]
            )
            PendingRunStore.finish(requestID: requestID)
        }
        currentSuggestions = []
        currentBundleDir = nil
        currentRequestID = nil
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
    private func recordChoice(index: Int, text: String) {
        guard let bundleDir = currentBundleDir else { return }
        let path = bundleDir.appendingPathComponent("run.json")
        var payload = JSONFiles.readObject(at: path) ?? [:]
        payload["chosen_index"] = index + 1
        payload["chosen_text"] = text
        payload["chosen_at"] = JSONFiles.isoString()
        payload["auto_paste"] = runtimeStore.autoPaste
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
