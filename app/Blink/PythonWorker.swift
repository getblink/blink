import Foundation

/// One decoded line of the worker's stdout. A pure value type produced by
/// `WorkerLineDecoder` with no I/O, so the parsing + routing rules can be unit
/// tested directly from string inputs (which is the only way to test the hot
/// path without launching Python or the full app).
enum WorkerEvent {
    case ready
    case runStarted(seq: Int?, bundleDir: String?)
    case phase(seq: Int?, message: String)
    case partialSummary(seq: Int?, text: String)
    case partialSuggestions(seq: Int?, suggestions: [String])
    case final(seq: Int?, payload: PythonRunner.ResultPayload)
    case error(seq: Int?, message: String)
    case done(seq: Int?)
    /// Blank line, unknown event, or malformed JSON. The worker tolerates these
    /// (the spawn path treated unknown lines as a hard error; for a long-lived
    /// worker, ignoring a stray diagnostic line is safer than failing a
    /// capture). Terminal correctness still rests on `final`/`error`/`done`.
    case ignored
}

/// Pure mapping from a raw stdout line to a `WorkerEvent`. Mirrors the field
/// handling of `PythonRunner.runOnceStreaming`'s inline parser (empty partials
/// are dropped, `phase` falls back through `message`/`phase`/default), and adds
/// the worker-only framing events (`worker_ready`, `worker_done`) plus `seq`.
enum WorkerLineDecoder {
    static func decode(_ rawLine: String) -> WorkerEvent {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = object["event"] as? String else {
            return .ignored
        }
        let seq = object["seq"] as? Int
        switch event {
        case "worker_ready":
            return .ready
        case "worker_done":
            return .done(seq: seq)
        case "run_started":
            let dir = (object["bundle_dir"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return .runStarted(seq: seq, bundleDir: dir)
        case "phase":
            let message = (object["message"] as? String) ?? (object["phase"] as? String) ?? "Working..."
            return .phase(seq: seq, message: message)
        case "partial_tldr":
            guard let text = object["tldr"] as? String, !text.isEmpty else { return .ignored }
            return .partialSummary(seq: seq, text: text)
        case "partial_suggestions":
            guard let list = object["suggestions"] as? [String], !list.isEmpty else { return .ignored }
            return .partialSuggestions(seq: seq, suggestions: list)
        case "final":
            guard let payload = resultPayload(from: object) else { return .ignored }
            return .final(seq: seq, payload: payload)
        case "error":
            let message = (object["message"] as? String) ?? line
            return .error(seq: seq, message: message)
        default:
            return .ignored
        }
    }

    /// Build a `ResultPayload` from a `final` event object, reusing
    /// `PythonRunner.decodeSuggestionDetails` so worker and spawn paths produce
    /// identical suggestion/tag/attachment shapes.
    static func resultPayload(from object: [String: Any]) -> PythonRunner.ResultPayload? {
        guard let status = object["status"] as? String,
              let bundleDir = object["bundle_dir"] as? String,
              let tldr = object["tldr"] as? String,
              let suggestions = object["suggestions"] as? [String] else {
            return nil
        }
        let details = PythonRunner.decodeSuggestionDetails(from: object, fallbackSuggestions: suggestions)
        return PythonRunner.ResultPayload(
            status: status,
            bundleDir: bundleDir,
            tldr: tldr,
            suggestions: suggestions,
            suggestionDetails: details,
            requestID: object["request_id"] as? String,
            durationMS: object["duration_ms"] as? Int,
            warnings: object["warnings"] as? [String] ?? [],
            model: object["model"] as? String,
            stderr: ""
        )
    }
}

/// Long-lived `blink_once.py --serve` process. Captures are serialized (one in
/// flight at a time, which matches the coordinator's single-`currentStreamingRun`
/// model); each is dispatched as a `{seq, argv}` line over stdin and its events
/// are routed back by `seq`. Any failure — crash, hang, cancel, or a bad
/// hand-off — degrades to "fail this capture, respawn for the next," so an
/// unhealthy worker behaves exactly like the spawn-per-capture path it replaces.
final class PythonWorker {
    enum WorkerError: Error, LocalizedError, Equatable {
        case unavailable        // could not launch the worker (caller falls back to spawn path)
        case died               // worker exited mid-capture
        case timedOut           // no terminal event within the watchdog window
        case cancelled          // capture was cancelled via StreamingRun.terminate()
        case failed(String)     // worker emitted an `error` event for this capture

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Persistent worker could not be launched."
            case .died: return "Persistent worker exited before completing the request."
            case .timedOut: return "Persistent worker did not respond in time."
            case .cancelled: return "Request was cancelled."
            case .failed(let message): return message
            }
        }
    }

    final class Capture {
        let seq: Int
        let onEvent: (PythonRunner.StreamEvent) -> Void
        var run: PythonRunner.StreamingRun?
        let done = DispatchSemaphore(value: 0)
        var result: PythonRunner.ResultPayload?
        var error: WorkerError?
        var finished = false

        init(seq: Int, onEvent: @escaping (PythonRunner.StreamEvent) -> Void) {
            self.seq = seq
            self.onEvent = onEvent
        }
    }

    private let config: Config
    private let captureLock = NSLock()   // serializes captures (one in flight)
    private let stateLock = NSLock()     // guards process/stdin/buffer/active/needsRespawn/pendingReady

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readBuffer = Data()
    private var seqCounter = 0
    private var active: Capture?
    private var needsRespawn = false
    private var pendingReady: DispatchSemaphore?

    /// Watchdog: kill the worker if a single capture produces no terminal event
    /// within this window. The proxy itself times out at 120s, so this only
    /// fires for a genuinely wedged process — generous on purpose.
    private let captureTimeout: TimeInterval = 150
    private let readyTimeout: TimeInterval = 10

    init(config: Config) {
        self.config = config
    }

    // MARK: - Public capture entry point

    /// Run one capture on the persistent worker. Blocking, mirroring
    /// `PythonRunner.runOnceStreaming`'s contract: fires `onRunStarted` once,
    /// streams `onEvent`, and returns the final payload (or throws). Throws
    /// `.unavailable` only when the worker can't launch — `PythonRunner` treats
    /// that as the signal to fall back to spawning for this capture.
    func capture(
        perRequestArgs: [String],
        onRunStarted: (PythonRunner.StreamingRun) -> Void,
        onEvent: @escaping (PythonRunner.StreamEvent) -> Void
    ) throws -> PythonRunner.ResultPayload {
        captureLock.lock()
        defer { captureLock.unlock() }

        try ensureRunning()

        let ctx: Capture = {
            stateLock.lock(); defer { stateLock.unlock() }
            seqCounter += 1
            let capture = Capture(seq: seqCounter, onEvent: onEvent)
            active = capture
            return capture
        }()

        let run = PythonRunner.StreamingRun(
            isRunning: { [weak self] in self?.isCaptureLive(ctx) ?? false },
            terminate: { [weak self] in self?.cancel(ctx) }
        )
        ctx.run = run
        onRunStarted(run)

        // Hand the request to the worker.
        guard let line = try? jsonLine(["seq": ctx.seq, "argv": perRequestArgs]),
              writeToStdin(line) else {
            clearActive(ctx)
            markForRespawn()
            throw WorkerError.died
        }

        // Block until the worker signals the request boundary (`worker_done`),
        // the process dies (termination handler), or the watchdog fires.
        let outcome = ctx.done.wait(timeout: .now() + captureTimeout)
        clearActive(ctx)
        if outcome == .timedOut {
            markForRespawn()
            killProcess()
            throw WorkerError.timedOut
        }
        stateLock.lock()
        let capturedError = ctx.error
        let capturedResult = ctx.result
        stateLock.unlock()
        return try Self.resolve(result: capturedResult, error: capturedError)
    }

    // MARK: - Lifecycle

    private func ensureRunning() throws {
        stateLock.lock()
        let healthy = process?.isRunning == true && !needsRespawn
        stateLock.unlock()
        if healthy { return }
        try spawn()
    }

    private func spawn() throws {
        teardown()
        guard let python = Paths.pythonBinary(config: config),
              let script = Paths.blinkOncePath else {
            throw WorkerError.unavailable
        }
        let proc = Process()
        proc.executableURL = python
        proc.arguments = [script.path, "--serve"]
        proc.environment = PythonRunner.buildEnvironment(config: config)

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.handleData(handle.availableData)
        }
        // Drain stderr so a full pipe buffer can never block the worker.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        proc.terminationHandler = { [weak self] terminated in
            self?.onProcessTerminated(terminated)
        }

        let ready = DispatchSemaphore(value: 0)
        stateLock.lock()
        process = proc
        stdinHandle = stdin.fileHandleForWriting
        readBuffer.removeAll()
        needsRespawn = false
        pendingReady = ready
        stateLock.unlock()

        do {
            try proc.run()
        } catch {
            teardown()
            throw WorkerError.unavailable
        }

        let signaled = ready.wait(timeout: .now() + readyTimeout)
        stateLock.lock()
        if pendingReady === ready { pendingReady = nil }
        let alive = process === proc && proc.isRunning
        stateLock.unlock()
        if signaled == .timedOut || !alive {
            teardown()
            throw WorkerError.unavailable
        }
    }

    /// Tear down the current process unconditionally (used before a respawn).
    /// Only ever called with no capture in flight (capture serialization), so
    /// it never needs to fail an active request.
    private func teardown() {
        stateLock.lock()
        let proc = process
        let stdin = stdinHandle
        process = nil
        stdinHandle = nil
        readBuffer.removeAll()
        stateLock.unlock()
        if proc?.isRunning == true { proc?.terminate() }
        try? stdin?.close()
    }

    private func killProcess() {
        stateLock.lock(); let proc = process; stateLock.unlock()
        if proc?.isRunning == true { proc?.terminate() }
    }

    private func onProcessTerminated(_ proc: Process) {
        stateLock.lock()
        // Ignore stale handlers from a process we've already replaced.
        guard process === proc else { stateLock.unlock(); return }
        let ctx = active
        let ready = pendingReady
        needsRespawn = true
        stateLock.unlock()
        ready?.signal()                         // unblock spawn() if it died during startup
        if let ctx { complete(ctx, error: .died) }
    }

    // MARK: - Cancellation

    /// Cancel maps to kill+respawn: abandon the in-flight server request and let
    /// the next capture spawn a fresh worker. The single warm connection is
    /// forfeited only for the capture that follows a cancel — no worse than the
    /// spawn-per-capture baseline, which also paid a handshake every time.
    private func cancel(_ ctx: Capture) {
        markForRespawn()
        complete(ctx, error: .cancelled)
        killProcess()
    }

    // MARK: - Reader

    private func handleData(_ data: Data) {
        guard !data.isEmpty else { return }     // EOF is handled by the termination handler
        var decoded: [WorkerEvent] = []
        stateLock.lock()
        readBuffer.append(data)
        while let newline = readBuffer.firstIndex(of: 0x0A) {
            let lineData = readBuffer[..<newline]
            readBuffer.removeSubrange(...newline)
            if let line = String(data: lineData, encoding: .utf8) {
                decoded.append(WorkerLineDecoder.decode(line))
            }
        }
        let ctx = active
        let ready = pendingReady
        stateLock.unlock()
        for event in decoded { route(event, ctx: ctx, ready: ready) }
    }

    private func route(_ event: WorkerEvent, ctx: Capture?, ready: DispatchSemaphore?) {
        switch event {
        case .ready:
            ready?.signal()
        case .runStarted(let seq, let bundleDir):
            guard let ctx, seq == ctx.seq else { return }
            if let bundleDir { ctx.run?.setBundleDir(bundleDir) }
        case .phase(let seq, let message):
            guard let ctx, seq == ctx.seq else { return }
            ctx.onEvent(.phase(message))
        case .partialSummary(let seq, let text):
            guard let ctx, seq == ctx.seq else { return }
            ctx.run?.markFirstToken(Date())
            ctx.onEvent(.partialSummary(text))
        case .partialSuggestions(let seq, let list):
            guard let ctx, seq == ctx.seq else { return }
            ctx.run?.markFirstToken(Date())
            ctx.onEvent(.partialSuggestions(list))
        case .final(let seq, let payload):
            guard let ctx, seq == ctx.seq else { return }
            ctx.run?.markFinalReceived()
            stateLock.lock(); ctx.result = payload; stateLock.unlock()
        case .error(let seq, let message):
            guard let ctx, seq == ctx.seq else { return }
            stateLock.lock(); if ctx.error == nil { ctx.error = .failed(message) }; stateLock.unlock()
        case .done(let seq):
            guard let ctx, seq == ctx.seq else { return }
            complete(ctx, error: nil)
        case .ignored:
            break
        }
    }

    // MARK: - State helpers

    private func complete(_ ctx: Capture, error: WorkerError?) {
        stateLock.lock()
        if ctx.finished { stateLock.unlock(); return }
        ctx.finished = true
        if let error, ctx.error == nil { ctx.error = error }
        stateLock.unlock()
        ctx.done.signal()
    }

    /// Resolve a finished capture's outcome. A delivered `final` result wins
    /// over an error on the same seq: once the worker has emitted `final` the
    /// request succeeded, so a trailing `error` (a duplicate emitted during
    /// teardown, or a raise between `final` and `worker_done`) must not discard
    /// the valid payload. An error surfaces only when no result arrived.
    static func resolve(
        result: PythonRunner.ResultPayload?,
        error: WorkerError?
    ) throws -> PythonRunner.ResultPayload {
        if let result { return result }
        if let error { throw error }
        throw WorkerError.failed("worker produced no final event")
    }

    private func isCaptureLive(_ ctx: Capture) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return active === ctx && !ctx.finished && process?.isRunning == true
    }

    private func clearActive(_ ctx: Capture) {
        stateLock.lock(); defer { stateLock.unlock() }
        if active === ctx { active = nil }
    }

    private func markForRespawn() {
        stateLock.lock(); needsRespawn = true; stateLock.unlock()
    }

    private func writeToStdin(_ data: Data) -> Bool {
        stateLock.lock(); let handle = stdinHandle; stateLock.unlock()
        guard let handle else { return false }
        do {
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    private func jsonLine(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [])
        data.append(0x0A)
        return data
    }
}

#if DEBUG
extension PythonWorker {
    /// Test seam. This extension lives in the same file, so it can reach the
    /// private supervision internals; it lets `PythonWorkerTests` drive routing
    /// and completion deterministically — without launching a live `--serve`
    /// subprocess — to cover the invariants the real concurrency relies on:
    /// `seq` correlation, error-once, `complete` idempotency, and the
    /// final-wins-over-error resolution (`resolve` is already `internal`).
    func test_makeCapture(seq: Int) -> Capture {
        Capture(seq: seq, onEvent: { _ in })
    }

    func test_route(_ event: WorkerEvent, ctx: Capture) {
        route(event, ctx: ctx, ready: nil)
    }

    func test_complete(_ ctx: Capture, error: WorkerError?) {
        complete(ctx, error: error)
    }

    /// Install `ctx` as the active capture so `test_handleData` routes to it,
    /// mirroring what `capture()` does after dispatching a request.
    func test_setActive(_ ctx: Capture) {
        stateLock.lock(); active = ctx; stateLock.unlock()
    }

    /// Feed raw bytes through the stdout framing + decode + route path, exactly
    /// as the process reader does (newline framing, partial-line buffering).
    func test_handleData(_ data: Data) {
        handleData(data)
    }
}
#endif
