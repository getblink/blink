import Foundation

enum PythonRunner {
    struct ResultPayload {
        let status: String
        let bundleDir: String
        let tldr: String
        let suggestions: [String]
        let requestID: String?
        let durationMS: Int?
        let warnings: [String]
        let model: String?
        let stderr: String
    }

    enum RunError: LocalizedError {
        case noPythonBinary
        case noScript
        case invalidJSONOutput(String)
        case invalidStreamEvent(String)
        case missingFinalStreamEvent(String)
        case nonZeroExit(status: Int32, stderr: String)

        var errorDescription: String? {
            switch self {
            case .noPythonBinary:
                return "Python binary not found; set TLDR_DEV_PYTHON or rebuild with bundled python-dist."
            case .noScript:
                return "tldr_once.py not found in app bundle."
            case .invalidJSONOutput(let output):
                return "Python returned invalid JSON: \(output)"
            case .invalidStreamEvent(let line):
                return "Python returned invalid stream event: \(line)"
            case .missingFinalStreamEvent(let output):
                return "Python stream ended without a final event: \(output)"
            case .nonZeroExit(let status, let stderr):
                return "Python exited \(status): \(stderr)"
            }
        }
    }

    enum StreamEvent {
        case phase(String)
        case partialTLDR(String)
        case partialSuggestions([String])
    }

    final class StreamingRun {
        fileprivate let process: Process

        fileprivate init(process: Process) {
            self.process = process
        }

        func terminate() {
            if process.isRunning {
                process.terminate()
            }
        }
    }

    static func runOnceSync(
        config: Config,
        screenshotPNG: URL,
        screenshotPNGs: [URL]? = nil,
        runtimeJSON: URL,
        settingsJSON: URL?,
        prompt: URL?,
        requestJSON: URL?,
        outputParent: URL,
        hostProfileJSON: URL?,
        skipGemini: Bool = false
    ) throws -> ResultPayload {
        guard let python = Paths.pythonBinary(config: config) else {
            throw RunError.noPythonBinary
        }
        guard let script = Paths.tldrOncePath else {
            throw RunError.noScript
        }

        let process = Process()
        process.executableURL = python
        let screenshots = screenshotPNGs ?? [screenshotPNG]
        var args = [
            script.path,
            "--runtime", runtimeJSON.path,
            "--out-dir", outputParent.path,
        ]
        for screenshot in screenshots {
            args += ["--screenshot", screenshot.path]
        }
        if let settingsJSON {
            args += ["--settings", settingsJSON.path]
        }
        if let prompt {
            args += ["--prompt", prompt.path]
        }
        if let requestJSON {
            args += ["--request-json", requestJSON.path]
        }
        if let hostProfileJSON {
            args += ["--host-profile", hostProfileJSON.path]
        }
        if skipGemini {
            args.append("--skip-gemini")
        }
        process.arguments = args
        process.environment = buildEnvironment(config: config)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let stdoutText = String(data: outData, encoding: .utf8) ?? ""
        let stderrText = String(data: errData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw RunError.nonZeroExit(status: process.terminationStatus, stderr: stderrText)
        }
        guard let object = try JSONSerialization.jsonObject(with: outData) as? [String: Any],
              let status = object["status"] as? String,
              let bundleDir = object["bundle_dir"] as? String,
              let tldr = object["tldr"] as? String,
              let suggestions = object["suggestions"] as? [String] else {
            throw RunError.invalidJSONOutput(stdoutText)
        }

        return ResultPayload(
            status: status,
            bundleDir: bundleDir,
            tldr: tldr,
            suggestions: suggestions,
            requestID: object["request_id"] as? String,
            durationMS: object["duration_ms"] as? Int,
            warnings: object["warnings"] as? [String] ?? [],
            model: object["model"] as? String,
            stderr: stderrText
        )
    }

    static func runOnceStreaming(
        config: Config,
        screenshotPNG: URL? = nil,
        screenshotPNGs: [URL]? = nil,
        runtimeJSON: URL,
        settingsJSON: URL?,
        prompt: URL?,
        requestJSON: URL?,
        outputParent: URL,
        hostProfileJSON: URL?,
        skipGemini: Bool = false,
        onRunStarted: @escaping (StreamingRun) -> Void,
        onEvent: @escaping (StreamEvent) -> Void
    ) throws -> ResultPayload {
        guard let python = Paths.pythonBinary(config: config) else {
            throw RunError.noPythonBinary
        }
        guard let script = Paths.tldrOncePath else {
            throw RunError.noScript
        }

        let process = Process()
        process.executableURL = python
        let screenshots = screenshotPNGs ?? screenshotPNG.map { [$0] } ?? []
        var args = [
            script.path,
            "--runtime", runtimeJSON.path,
            "--out-dir", outputParent.path,
            "--stream-events",
        ]
        for screenshot in screenshots {
            args += ["--screenshot", screenshot.path]
        }
        if let settingsJSON {
            args += ["--settings", settingsJSON.path]
        }
        if let prompt {
            args += ["--prompt", prompt.path]
        }
        if let requestJSON {
            args += ["--request-json", requestJSON.path]
        }
        if let hostProfileJSON {
            args += ["--host-profile", hostProfileJSON.path]
        }
        if skipGemini {
            args.append("--skip-gemini")
        }
        process.arguments = args
        process.environment = buildEnvironment(config: config)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let stateQueue = DispatchQueue(label: "tldr.python.stream")
        let finished = DispatchSemaphore(value: 0)
        var buffer = Data()
        var stdoutText = ""
        var stderrText = ""
        var finalPayload: ResultPayload?
        var streamError: Error?

        func handleLine(_ rawLine: String) {
            let line = rawLine.trimmingCharacters(in: .newlines)
            guard !line.isEmpty else { return }
            stdoutText += line + "\n"
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let event = object["event"] as? String else {
                streamError = RunError.invalidStreamEvent(line)
                return
            }
            switch event {
            case "phase":
                let message = (object["message"] as? String) ?? (object["phase"] as? String) ?? "Working..."
                onEvent(.phase(message))
            case "partial_tldr":
                if let text = object["tldr"] as? String, !text.isEmpty {
                    onEvent(.partialTLDR(text))
                }
            case "partial_suggestions":
                if let list = object["suggestions"] as? [String], !list.isEmpty {
                    onEvent(.partialSuggestions(list))
                }
            case "final":
                guard let status = object["status"] as? String,
                      let bundleDir = object["bundle_dir"] as? String,
                      let tldr = object["tldr"] as? String,
                      let suggestions = object["suggestions"] as? [String] else {
                    streamError = RunError.invalidStreamEvent(line)
                    return
                }
                finalPayload = ResultPayload(
                    status: status,
                    bundleDir: bundleDir,
                    tldr: tldr,
                    suggestions: suggestions,
                    requestID: object["request_id"] as? String,
                    durationMS: object["duration_ms"] as? Int,
                    warnings: object["warnings"] as? [String] ?? [],
                    model: object["model"] as? String,
                    stderr: ""
                )
            case "error":
                let message = (object["message"] as? String) ?? line
                streamError = RunError.invalidStreamEvent(message)
            default:
                streamError = RunError.invalidStreamEvent(line)
            }
        }

        func drainCompleteLines() {
            while let newline = buffer.firstIndex(of: 10) {
                let lineData = buffer[..<newline]
                buffer.removeSubrange(...newline)
                if let line = String(data: lineData, encoding: .utf8) {
                    handleLine(line)
                } else {
                    streamError = RunError.invalidStreamEvent("<non-utf8>")
                }
            }
        }

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            stateQueue.async {
                if data.isEmpty {
                    return
                }
                buffer.append(data)
                drainCompleteLines()
            }
        }

        process.terminationHandler = { _ in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            stateQueue.async {
                if !outData.isEmpty {
                    buffer.append(outData)
                }
                stderrText = String(data: errData, encoding: .utf8) ?? ""
                drainCompleteLines()
                if !buffer.isEmpty {
                    if let line = String(data: buffer, encoding: .utf8) {
                        handleLine(line)
                    } else {
                        streamError = RunError.invalidStreamEvent("<non-utf8>")
                    }
                    buffer.removeAll()
                }
                finished.signal()
            }
        }

        try process.run()
        onRunStarted(StreamingRun(process: process))
        finished.wait()

        if process.terminationStatus != 0 {
            throw RunError.nonZeroExit(status: process.terminationStatus, stderr: stderrText)
        }
        if let streamError {
            throw streamError
        }
        guard let finalPayload else {
            throw RunError.missingFinalStreamEvent(stdoutText)
        }
        return ResultPayload(
            status: finalPayload.status,
            bundleDir: finalPayload.bundleDir,
            tldr: finalPayload.tldr,
            suggestions: finalPayload.suggestions,
            requestID: finalPayload.requestID,
            durationMS: finalPayload.durationMS,
            warnings: finalPayload.warnings,
            model: finalPayload.model,
            stderr: stderrText
        )
    }

    private static func buildEnvironment(config: Config) -> [String: String] {
        var env = RuntimeEnvironment.mergedEnvironment()
        if let key = config.geminiApiKey {
            env["GEMINI_API_KEY"] = key
        }
        env["TLDR_RUNTIME_DIR"] = Paths.runtimeDir.path
        return env
    }
}
