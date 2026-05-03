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
        case nonZeroExit(status: Int32, stderr: String)

        var errorDescription: String? {
            switch self {
            case .noPythonBinary:
                return "Python binary not found; set TLDR_DEV_PYTHON or rebuild with bundled python-dist."
            case .noScript:
                return "tldr_once.py not found in app bundle."
            case .invalidJSONOutput(let output):
                return "Python returned invalid JSON: \(output)"
            case .nonZeroExit(let status, let stderr):
                return "Python exited \(status): \(stderr)"
            }
        }
    }

    static func runOnceSync(
        config: Config,
        screenshotPNG: URL,
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
        var args = [
            script.path,
            "--screenshot", screenshotPNG.path,
            "--runtime", runtimeJSON.path,
            "--out-dir", outputParent.path,
        ]
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

    private static func buildEnvironment(config: Config) -> [String: String] {
        var env = RuntimeEnvironment.mergedEnvironment()
        if let key = config.geminiApiKey {
            env["GEMINI_API_KEY"] = key
        }
        env["TLDR_RUNTIME_DIR"] = Paths.runtimeDir.path
        return env
    }
}
