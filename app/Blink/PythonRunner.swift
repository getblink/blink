import Foundation

/// Spawns the bundled (or dev) Python helper scripts.
enum PythonRunner {
    struct PreparedSource {
        let payload: [String: Any]

        var packetText: String {
            payload["packet_text"] as? String ?? ""
        }
    }

    /// A pre-warmed Python worker process that's already finished imports and
    /// is blocked on stdin waiting for a single JSON request. Created at
    /// ⌃⇧C source-prep time; consumed at ⌃⇧V paste time.
    final class WarmWorker {
        let process: Process
        let stdin: FileHandle
        let stdout: FileHandle
        let stderr: FileHandle
        let stdoutBuffer = StdoutBuffer()
        private let lock = NSLock()
        private var consumed = false

        init(process: Process, stdin: FileHandle, stdout: FileHandle, stderr: FileHandle) {
            self.process = process
            self.stdin = stdin
            self.stdout = stdout
            self.stderr = stderr
        }

        /// True if no caller has tried to use this worker yet. Used by the
        /// coordinator to decide whether to consume or discard.
        var isAvailable: Bool {
            lock.lock(); defer { lock.unlock() }
            return !consumed && process.isRunning
        }

        /// Atomically take ownership; returns false if another caller already did.
        func tryConsume() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !consumed, process.isRunning else { return false }
            consumed = true
            return true
        }

        /// Best-effort termination — used when a fresh ⌃⇧C arrives while a
        /// previous worker is still alive but unconsumed.
        func discard() {
            lock.lock()
            consumed = true
            lock.unlock()
            try? stdin.close()
            if process.isRunning {
                process.terminate()
            }
        }
    }

    /// Tiny actor-style buffer for the bytes emitted by the worker before it
    /// printed READY. ``startWarmWorker`` reads stdout on a background queue;
    /// the post-READY bytes are fed back here so ``runOnceUsingWorker`` can
    /// pick them up after writing the request.
    final class StdoutBuffer {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            data.append(chunk)
        }

        func drain() -> Data {
            lock.lock(); defer { lock.unlock() }
            let copy = data
            data.removeAll(keepingCapacity: false)
            return copy
        }
    }

    enum RunError: LocalizedError {
        case noPythonBinary
        case noRunOnceScript
        case noPrepareSourceScript
        case invalidJSONOutput
        case nonZeroExit(status: Int32, stderr: String)

        var errorDescription: String? {
            switch self {
            case .noPythonBinary:
                return "Python binary not found; set BLINK_DEV_PYTHON or rebuild with bundled python-dist."
            case .noRunOnceScript:
                return "run_once.py not found in app bundle"
            case .noPrepareSourceScript:
                return "prepare_source.py not found in app bundle"
            case .invalidJSONOutput:
                return "Python returned invalid JSON"
            case .nonZeroExit(let status, let stderr):
                return "python exited \(status): \(stderr)"
            }
        }
    }

    static func prepareSourceSync(
        config: Config,
        sourcePNG: URL,
        runtimeJSON: URL,
        sourceTextJSON: URL?,
        settingsJSON: URL?
    ) throws -> PreparedSource {
        guard let python = Paths.pythonBinary(config: config) else {
            throw RunError.noPythonBinary
        }
        guard let prepareSource = Paths.prepareSourcePath else {
            throw RunError.noPrepareSourceScript
        }

        let process = Process()
        process.executableURL = python
        var args: [String] = [
            prepareSource.path,
            "--source", sourcePNG.path,
            "--runtime", runtimeJSON.path,
        ]
        if let sourceTextJSON {
            args += ["--source-text", sourceTextJSON.path]
        }
        if let settingsJSON {
            args += ["--settings", settingsJSON.path]
        }
        process.arguments = args
        process.environment = buildEnvironment(config: config)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(data: errData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw RunError.nonZeroExit(status: process.terminationStatus, stderr: stderrText)
        }
        guard let object = try JSONSerialization.jsonObject(with: outData) as? [String: Any] else {
            throw RunError.invalidJSONOutput
        }
        return PreparedSource(payload: object)
    }

    /// Spawn `run_once.py --wait-on-stdin`, wait up to 5 s for the `READY`
    /// line on stdout, and return a handle the coordinator can hand to a
    /// later ⌃⇧V. Returns nil if the worker fails to come up cleanly; the
    /// fresh-spawn path will pick up the slack.
    static func startWarmWorker(config: Config) -> WarmWorker? {
        guard let python = Paths.pythonBinary(config: config) else { return nil }
        guard let runOnce = Paths.runOncePath else { return nil }

        let process = Process()
        process.executableURL = python
        process.arguments = [runOnce.path, "--wait-on-stdin", "--silent-stderr"]
        process.environment = buildEnvironment(config: config)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            NSLog("[blink] warm worker spawn failed: %@", error.localizedDescription)
            return nil
        }

        let worker = WarmWorker(
            process: process,
            stdin: stdinPipe.fileHandleForWriting,
            stdout: stdoutPipe.fileHandleForReading,
            stderr: stderrPipe.fileHandleForReading
        )

        // Wait for "READY <pid>\n" with a 5 s deadline. The first chunk
        // typically holds the entire READY line; if not, keep reading until
        // we see a newline.
        let deadline = DispatchTime.now() + .seconds(5)
        let signaller = DispatchSemaphore(value: 0)
        var readyHolder: Bool = false

        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = Data()
            while DispatchTime.now() < deadline {
                let chunk = worker.stdout.availableData
                if chunk.isEmpty {
                    // EOF — process died.
                    break
                }
                buffer.append(chunk)
                if let newlineIdx = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.prefix(upTo: newlineIdx)
                    let lineString = String(data: line, encoding: .utf8) ?? ""
                    if lineString.hasPrefix("READY ") {
                        // Stash any bytes that arrived after the newline
                        // (none expected, but be defensive).
                        let remainder = buffer.suffix(from: buffer.index(after: newlineIdx))
                        if !remainder.isEmpty {
                            worker.stdoutBuffer.append(Data(remainder))
                        }
                        readyHolder = true
                    }
                    break
                }
            }
            signaller.signal()
        }

        let result = signaller.wait(timeout: deadline)
        if result == .timedOut || !readyHolder {
            worker.discard()
            return nil
        }
        return worker
    }

    static func runOnce(
        config: Config,
        sourcePNG: URL,
        targetPNG: URL,
        targetMetadataJSON: URL,
        caretJSON: URL?,
        geometryJSON: URL?,
        runtimeJSON: URL?,
        preparedSourceJSON: URL?,
        sourceTextJSON: URL?,
        settingsJSON: URL?,
        outputParent: URL,
        bundleId: String,
        extraEnvironment: [String: String] = [:],
        warmWorker: WarmWorker? = nil,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        if let warmWorker, warmWorker.tryConsume() {
            runOnceUsingWorker(
                worker: warmWorker,
                sourcePNG: sourcePNG,
                targetPNG: targetPNG,
                targetMetadataJSON: targetMetadataJSON,
                caretJSON: caretJSON,
                geometryJSON: geometryJSON,
                runtimeJSON: runtimeJSON,
                preparedSourceJSON: preparedSourceJSON,
                sourceTextJSON: sourceTextJSON,
                settingsJSON: settingsJSON,
                outputParent: outputParent,
                bundleId: bundleId,
                extraEnvironment: extraEnvironment
            ) { result in
                switch result {
                case .success(let text):
                    completion(.success(text))
                case .failure(let err):
                    NSLog("[blink] warm worker run failed (%@); falling back to fresh spawn", "\(err)")
                    // Wipe any partial bundle the warm worker may have
                    // started before crashing — the fresh-spawn path will
                    // re-create the directory from scratch.
                    let bundleDir = outputParent.appendingPathComponent(bundleId, isDirectory: true)
                    if FileManager.default.fileExists(atPath: bundleDir.path) {
                        try? FileManager.default.removeItem(at: bundleDir)
                    }
                    runOnceFresh(
                        config: config,
                        sourcePNG: sourcePNG,
                        targetPNG: targetPNG,
                        targetMetadataJSON: targetMetadataJSON,
                        caretJSON: caretJSON,
                        geometryJSON: geometryJSON,
                        runtimeJSON: runtimeJSON,
                        preparedSourceJSON: preparedSourceJSON,
                        sourceTextJSON: sourceTextJSON,
                        settingsJSON: settingsJSON,
                        outputParent: outputParent,
                        bundleId: bundleId,
                        extraEnvironment: extraEnvironment,
                        completion: completion
                    )
                }
            }
            return
        }

        runOnceFresh(
            config: config,
            sourcePNG: sourcePNG,
            targetPNG: targetPNG,
            targetMetadataJSON: targetMetadataJSON,
            caretJSON: caretJSON,
            geometryJSON: geometryJSON,
            runtimeJSON: runtimeJSON,
            preparedSourceJSON: preparedSourceJSON,
            sourceTextJSON: sourceTextJSON,
            settingsJSON: settingsJSON,
            outputParent: outputParent,
            bundleId: bundleId,
            extraEnvironment: extraEnvironment,
            completion: completion
        )
    }

    private static func runOnceFresh(
        config: Config,
        sourcePNG: URL,
        targetPNG: URL,
        targetMetadataJSON: URL,
        caretJSON: URL?,
        geometryJSON: URL?,
        runtimeJSON: URL?,
        preparedSourceJSON: URL?,
        sourceTextJSON: URL?,
        settingsJSON: URL?,
        outputParent: URL,
        bundleId: String,
        extraEnvironment: [String: String],
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
        if let geometryJSON {
            args += ["--geometry", geometryJSON.path]
        }
        if let runtimeJSON {
            args += ["--runtime", runtimeJSON.path]
        }
        if let preparedSourceJSON {
            args += ["--prepared-source", preparedSourceJSON.path]
        }
        if let sourceTextJSON {
            args += ["--source-text", sourceTextJSON.path]
        }
        if let settingsJSON {
            args += ["--settings", settingsJSON.path]
        }
        process.arguments = args
        var env = buildEnvironment(config: config)
        env["BLINK_SPAWN_NS"] = String(DispatchTime.now().uptimeNanoseconds)
        for (key, value) in extraEnvironment {
            env[key] = value
        }
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

            persistStderrIfNeeded(errData: errData, bundleDir: bundleDir)
            if process.terminationStatus != 0 {
                completion(.failure(RunError.nonZeroExit(
                    status: process.terminationStatus, stderr: stderrText)))
                return
            }
            let text = String(data: outData, encoding: .utf8) ?? ""
            completion(.success(text))
        }
    }

    /// Submit a JSON request to a warm worker over its stdin pipe and
    /// collect the rest of stdout as the pasted text.
    private static func runOnceUsingWorker(
        worker: WarmWorker,
        sourcePNG: URL,
        targetPNG: URL,
        targetMetadataJSON: URL,
        caretJSON: URL?,
        geometryJSON: URL?,
        runtimeJSON: URL?,
        preparedSourceJSON: URL?,
        sourceTextJSON: URL?,
        settingsJSON: URL?,
        outputParent: URL,
        bundleId: String,
        extraEnvironment: [String: String],
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        var payload: [String: Any] = [
            "source": sourcePNG.path,
            "target": targetPNG.path,
            "target_meta": targetMetadataJSON.path,
            "out_dir": outputParent.path,
            "bundle_id": bundleId,
            "silent_stderr": true,
        ]
        if let caretJSON { payload["caret"] = caretJSON.path }
        if let geometryJSON { payload["geometry"] = geometryJSON.path }
        if let runtimeJSON { payload["runtime"] = runtimeJSON.path }
        if let preparedSourceJSON { payload["prepared_source"] = preparedSourceJSON.path }
        if let sourceTextJSON { payload["source_text"] = sourceTextJSON.path }
        if let settingsJSON { payload["settings"] = settingsJSON.path }
        if !extraEnvironment.isEmpty {
            payload["env"] = extraEnvironment
        }

        guard var requestData = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(.failure(RunError.invalidJSONOutput))
            return
        }
        requestData.append(0x0A) // newline-terminated, the worker reads one line.

        let bundleDir = outputParent.appendingPathComponent(bundleId, isDirectory: true)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try worker.stdin.write(contentsOf: requestData)
                try worker.stdin.close()
            } catch {
                completion(.failure(error))
                return
            }

            // Drain any pre-buffered stdout bytes (collected during the
            // READY-wait phase), then read until EOF.
            var output = worker.stdoutBuffer.drain()
            output.append(worker.stdout.readDataToEndOfFile())
            let errData = worker.stderr.readDataToEndOfFile()
            worker.process.waitUntilExit()

            let stderrText = String(data: errData, encoding: .utf8) ?? ""
            persistStderrIfNeeded(errData: errData, bundleDir: bundleDir)

            if worker.process.terminationStatus != 0 {
                completion(.failure(RunError.nonZeroExit(
                    status: worker.process.terminationStatus, stderr: stderrText)))
                return
            }
            let text = String(data: output, encoding: .utf8) ?? ""
            completion(.success(text))
        }
    }

    private static func persistStderrIfNeeded(errData: Data, bundleDir: URL) {
        var bundleIsDir: ObjCBool = false
        if !errData.isEmpty,
           FileManager.default.fileExists(atPath: bundleDir.path, isDirectory: &bundleIsDir),
           bundleIsDir.boolValue {
            try? errData.write(to: bundleDir.appendingPathComponent("stderr.log"))
        }
    }

    private static func buildEnvironment(config: Config) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let url = config.proxyURL { env["BLINK_PROXY_URL"] = url }
        if let token = config.proxyToken { env["BLINK_PROXY_TOKEN"] = token }
        if let key = config.geminiApiKey { env["GEMINI_API_KEY"] = key }
        return env
    }
}
