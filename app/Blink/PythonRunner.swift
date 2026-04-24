import Foundation

/// Spawns the bundled (or dev) Python + `run_once.py` once per trial.
enum PythonRunner {
    enum RunError: LocalizedError {
        case noPythonBinary
        case noRunOnceScript
        case nonZeroExit(status: Int32, stderr: String)

        var errorDescription: String? {
            switch self {
            case .noPythonBinary: return "Python binary not found; set BLINK_DEV_PYTHON or rebuild with bundled python-dist."
            case .noRunOnceScript: return "run_once.py not found in app bundle"
            case .nonZeroExit(let status, let stderr): return "run_once exited \(status): \(stderr)"
            }
        }
    }

    static func runOnce(
        config: Config,
        sourcePNG: URL,
        targetPNG: URL,
        targetMetadataJSON: URL,
        caretJSON: URL?,
        outputParent: URL,
        bundleId: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let python = Paths.pythonBinary(config: config) else {
            completion(.failure(RunError.noPythonBinary))
            return
        }
        guard let runOnce = Paths.runOncePath else {
            completion(.failure(RunError.noRunOnceScript))
            return
        }
        let prompt = Paths.promptPath
        let settings = Paths.settingsPath

        let process = Process()
        process.executableURL = python

        var args: [String] = [
            runOnce.path,
            "--source", sourcePNG.path,
            "--target", targetPNG.path,
            "--target-meta", targetMetadataJSON.path,
            "--out-dir", outputParent.path,
            "--bundle-id", bundleId,
        ]
        if let caretJSON {
            args += ["--caret", caretJSON.path]
        }
        if let prompt = prompt { args += ["--prompt", prompt.path] }
        if let settings = settings { args += ["--settings", settings.path] }
        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        if let url = config.proxyURL { env["BLINK_PROXY_URL"] = url }
        if let token = config.proxyToken { env["BLINK_PROXY_TOKEN"] = token }
        // GEMINI_API_KEY is inherited from our environment if present, but
        // launchd-launched .apps don't see shell env vars — so also surface
        // the value Config resolved from overrides.plist.
        if let key = config.geminiApiKey { env["GEMINI_API_KEY"] = key }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let bundleDir = outputParent.appendingPathComponent(bundleId, isDirectory: true)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try process.run()
            } catch {
                completion(.failure(error))
                return
            }
            process.waitUntilExit()
            let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(data: errData, encoding: .utf8) ?? ""
            // Persist stderr alongside the v1 bundle when the bundle already
            // exists (run_once.py creates it early). If Python died before
            // getting that far, skip — don't leave a schema-incomplete stub
            // directory that importers would reject.
            var bundleIsDir: ObjCBool = false
            if !errData.isEmpty,
               FileManager.default.fileExists(atPath: bundleDir.path, isDirectory: &bundleIsDir),
               bundleIsDir.boolValue {
                try? errData.write(to: bundleDir.appendingPathComponent("stderr.log"))
            }
            if process.terminationStatus != 0 {
                completion(.failure(RunError.nonZeroExit(
                    status: process.terminationStatus, stderr: stderrText)))
                return
            }
            let text = String(data: outData, encoding: .utf8) ?? ""
            completion(.success(text))
        }
    }
}
