import XCTest
@testable import Blink

/// Tests for the persistent-worker stdout decoder. This is the pure,
/// deterministic core of the `--serve` integration: every event the worker
/// streams is classified here, including the `seq` correlation and the
/// framing events (`worker_ready` / `worker_done`) the host uses to bound a
/// capture. The process supervision itself is validated end-to-end by
/// `scratchpad/worker_latency.py`; this covers the parsing rules in isolation.
final class PythonWorkerTests: XCTestCase {
    private func decode(_ line: String) -> WorkerEvent {
        WorkerLineDecoder.decode(line)
    }

    // MARK: - Framing events

    func testWorkerReady() {
        guard case .ready = decode(#"{"event":"worker_ready"}"#) else {
            return XCTFail("expected .ready")
        }
    }

    func testWorkerDoneCarriesSeq() {
        guard case .done(let seq) = decode(#"{"event":"worker_done","seq":7}"#) else {
            return XCTFail("expected .done")
        }
        XCTAssertEqual(seq, 7)
    }

    func testWorkerDoneWithoutSeq() {
        guard case .done(let seq) = decode(#"{"event":"worker_done"}"#) else {
            return XCTFail("expected .done")
        }
        XCTAssertNil(seq)
    }

    // MARK: - run_started

    func testRunStartedWithBundleDir() {
        guard case .runStarted(let seq, let dir) = decode(#"{"event":"run_started","bundle_dir":"/runs/abc","seq":2}"#) else {
            return XCTFail("expected .runStarted")
        }
        XCTAssertEqual(seq, 2)
        XCTAssertEqual(dir, "/runs/abc")
    }

    func testRunStartedEmptyBundleDirBecomesNil() {
        guard case .runStarted(_, let dir) = decode(#"{"event":"run_started","bundle_dir":"","seq":2}"#) else {
            return XCTFail("expected .runStarted")
        }
        XCTAssertNil(dir)
    }

    // MARK: - phase

    func testPhasePrefersMessage() {
        guard case .phase(let seq, let message) = decode(#"{"event":"phase","message":"Reading this screen...","phase":"model_started","seq":1}"#) else {
            return XCTFail("expected .phase")
        }
        XCTAssertEqual(seq, 1)
        XCTAssertEqual(message, "Reading this screen...")
    }

    func testPhaseFallsBackToPhaseField() {
        guard case .phase(_, let message) = decode(#"{"event":"phase","phase":"model_started"}"#) else {
            return XCTFail("expected .phase")
        }
        XCTAssertEqual(message, "model_started")
    }

    func testPhaseDefaultMessage() {
        guard case .phase(_, let message) = decode(#"{"event":"phase"}"#) else {
            return XCTFail("expected .phase")
        }
        XCTAssertEqual(message, "Working...")
    }

    // MARK: - partial events

    func testPartialTldr() {
        guard case .partialSummary(let seq, let text) = decode(#"{"event":"partial_tldr","tldr":"You left this mid-edit.","seq":4}"#) else {
            return XCTFail("expected .partialSummary")
        }
        XCTAssertEqual(seq, 4)
        XCTAssertEqual(text, "You left this mid-edit.")
    }

    func testEmptyPartialTldrIgnored() {
        guard case .ignored = decode(#"{"event":"partial_tldr","tldr":"","seq":4}"#) else {
            return XCTFail("expected .ignored for empty tldr")
        }
    }

    func testPartialSuggestions() {
        guard case .partialSuggestions(let seq, let list) = decode(#"{"event":"partial_suggestions","suggestions":["A","B"],"seq":5}"#) else {
            return XCTFail("expected .partialSuggestions")
        }
        XCTAssertEqual(seq, 5)
        XCTAssertEqual(list, ["A", "B"])
    }

    func testEmptyPartialSuggestionsIgnored() {
        guard case .ignored = decode(#"{"event":"partial_suggestions","suggestions":[],"seq":5}"#) else {
            return XCTFail("expected .ignored for empty suggestions")
        }
    }

    // MARK: - final

    func testFinalDecodesCoreFields() {
        let line = #"""
        {"event":"final","seq":6,"status":"ok","bundle_dir":"/runs/xyz","tldr":"Summary.","suggestions":["One","Two","Three"],"request_id":"req-1","duration_ms":2500,"model":"gemini-3-flash-preview","warnings":["w1"]}
        """#
        guard case .final(let seq, let payload) = decode(line) else {
            return XCTFail("expected .final")
        }
        XCTAssertEqual(seq, 6)
        XCTAssertEqual(payload.status, "ok")
        XCTAssertEqual(payload.bundleDir, "/runs/xyz")
        XCTAssertEqual(payload.tldr, "Summary.")
        XCTAssertEqual(payload.suggestions, ["One", "Two", "Three"])
        XCTAssertEqual(payload.requestID, "req-1")
        XCTAssertEqual(payload.durationMS, 2500)
        XCTAssertEqual(payload.model, "gemini-3-flash-preview")
        XCTAssertEqual(payload.warnings, ["w1"])
        XCTAssertEqual(payload.stderr, "")
    }

    func testFinalDecodesSuggestionDetails() {
        let line = #"""
        {"event":"final","seq":1,"status":"ok","bundle_dir":"/r","tldr":"t","suggestions":["Reply now"],"suggestion_details":[{"text":"Reply now","tags":["Reply","Quick"],"attachments":[{"id":"a1","reason":"the spec"}]}]}
        """#
        guard case .final(_, let payload) = decode(line) else {
            return XCTFail("expected .final")
        }
        XCTAssertEqual(payload.suggestionDetails.count, 1)
        let detail = payload.suggestionDetails[0]
        XCTAssertEqual(detail.text, "Reply now")
        XCTAssertEqual(detail.tags, ["Reply", "Quick"])
        XCTAssertEqual(detail.attachments.count, 1)
        XCTAssertEqual(detail.attachments.first?.id, "a1")
    }

    func testFinalMissingRequiredFieldsIgnored() {
        // No `tldr`/`suggestions` -> not a usable final payload.
        guard case .ignored = decode(#"{"event":"final","status":"ok","bundle_dir":"/r"}"#) else {
            return XCTFail("expected .ignored for incomplete final")
        }
    }

    // MARK: - error

    func testErrorEventWithMessage() {
        guard case .error(let seq, let message) = decode(#"{"event":"error","message":"worker: boom","seq":9}"#) else {
            return XCTFail("expected .error")
        }
        XCTAssertEqual(seq, 9)
        XCTAssertEqual(message, "worker: boom")
    }

    // MARK: - malformed / unknown

    func testMalformedJsonIgnored() {
        guard case .ignored = decode("this is not json") else {
            return XCTFail("expected .ignored")
        }
    }

    func testBlankLineIgnored() {
        guard case .ignored = decode("   ") else {
            return XCTFail("expected .ignored")
        }
    }

    func testUnknownEventIgnored() {
        guard case .ignored = decode(#"{"event":"telemetry","value":1}"#) else {
            return XCTFail("expected .ignored")
        }
    }

    func testMissingEventFieldIgnored() {
        guard case .ignored = decode(#"{"tldr":"hi"}"#) else {
            return XCTFail("expected .ignored")
        }
    }

    // MARK: - seq is optional (one-shot CLI lines carry no seq)

    func testSeqAbsentParsesAsNil() {
        guard case .partialSummary(let seq, _) = decode(#"{"event":"partial_tldr","tldr":"hi"}"#) else {
            return XCTFail("expected .partialSummary")
        }
        XCTAssertNil(seq)
    }

    // MARK: - Supervision (routing / completion invariants)
    //
    // These drive `PythonWorker`'s private routing + completion directly via the
    // DEBUG test seam, so the concurrency-safety invariants are covered without
    // launching a real `--serve` subprocess (which would make the races
    // nondeterministic). They assert the rules the live supervision relies on:
    // `seq` correlation, error-once, `complete` idempotency (including under real
    // thread contention), and final-wins-over-error resolution.

    private func makeWorker() -> PythonWorker {
        PythonWorker(config: Config(geminiApiKey: nil, devPythonPath: nil))
    }

    private func finalLine(seq: Int) -> String {
        #"{"event":"final","seq":\#(seq),"status":"ok","bundle_dir":"/runs/test","tldr":"Summary.","suggestions":["A","B","C"]}"#
    }

    private func samplePayload(seq: Int = 1) -> PythonRunner.ResultPayload {
        guard case .final(_, let payload) = WorkerLineDecoder.decode(finalLine(seq: seq)) else {
            fatalError("sample final line did not decode")
        }
        return payload
    }

    // resolve()

    func testResolveReturnsResultWhenOnlyResult() throws {
        let resolved = try PythonWorker.resolve(result: samplePayload(), error: nil)
        XCTAssertEqual(resolved.tldr, "Summary.")
    }

    func testResolveThrowsErrorWhenOnlyError() {
        XCTAssertThrowsError(try PythonWorker.resolve(result: nil, error: .died)) {
            XCTAssertEqual($0 as? PythonWorker.WorkerError, .died)
        }
    }

    func testResolvePrefersResultOverError() throws {
        // final-then-error on the same seq: the valid payload must win.
        let resolved = try PythonWorker.resolve(result: samplePayload(), error: .failed("late duplicate"))
        XCTAssertEqual(resolved.tldr, "Summary.")
    }

    func testResolveThrowsWhenNeither() {
        XCTAssertThrowsError(try PythonWorker.resolve(result: nil, error: nil)) {
            guard case PythonWorker.WorkerError.failed = $0 else {
                return XCTFail("expected .failed, got \($0)")
            }
        }
    }

    // route() seq correlation

    func testRouteAppliesFinalForMatchingSeq() {
        let worker = makeWorker()
        let ctx = worker.test_makeCapture(seq: 3)
        worker.test_route(.final(seq: 3, payload: samplePayload(seq: 3)), ctx: ctx)
        XCTAssertNotNil(ctx.result)
        XCTAssertNil(ctx.error)
    }

    func testRouteDropsMismatchedSeq() {
        let worker = makeWorker()
        let ctx = worker.test_makeCapture(seq: 3)
        worker.test_route(.final(seq: 99, payload: samplePayload(seq: 99)), ctx: ctx)
        worker.test_route(.error(seq: 99, message: "stale"), ctx: ctx)
        XCTAssertNil(ctx.result, "a final from another seq must not set the result")
        XCTAssertNil(ctx.error, "an error from another seq must not set the error")
    }

    func testRouteErrorThenCompleteKeepsFirstError() {
        let worker = makeWorker()
        let ctx = worker.test_makeCapture(seq: 1)
        worker.test_route(.error(seq: 1, message: "boom"), ctx: ctx)
        worker.test_complete(ctx, error: .died)   // completion error must not overwrite the routed one
        XCTAssertEqual(ctx.error, .failed("boom"))
    }

    // complete() idempotency

    func testCompleteIsIdempotent() {
        let worker = makeWorker()
        let ctx = worker.test_makeCapture(seq: 1)
        worker.test_complete(ctx, error: nil)     // success
        worker.test_complete(ctx, error: .died)   // late death — must be ignored
        XCTAssertTrue(ctx.finished)
        XCTAssertNil(ctx.error, "a completed capture must not absorb a later error")
        // `done` was signaled exactly once: the first wait drains it, the second times out.
        XCTAssertEqual(ctx.done.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(ctx.done.wait(timeout: .now() + 0.1), .timedOut)
    }

    func testCompleteIdempotentUnderConcurrency() {
        let worker = makeWorker()
        let ctx = worker.test_makeCapture(seq: 1)
        let group = DispatchGroup()
        let gate = DispatchSemaphore(value: 0)
        for i in 0..<50 {
            DispatchQueue.global().async(group: group) {
                gate.wait()
                worker.test_complete(ctx, error: i == 0 ? nil : .died)
            }
        }
        for _ in 0..<50 { gate.signal() }   // release all at once to maximize contention
        group.wait()
        XCTAssertTrue(ctx.finished)
        // Regardless of interleaving, the `finished` guard means exactly one signal.
        XCTAssertEqual(ctx.done.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(ctx.done.wait(timeout: .now() + 0.2), .timedOut)
    }

    // End-to-end ordering through route()

    func testFinalThenErrorThenDoneResolvesToSuccess() throws {
        let worker = makeWorker()
        let ctx = worker.test_makeCapture(seq: 4)
        worker.test_route(.final(seq: 4, payload: samplePayload(seq: 4)), ctx: ctx)
        worker.test_route(.error(seq: 4, message: "late duplicate"), ctx: ctx)
        worker.test_route(.done(seq: 4), ctx: ctx)
        XCTAssertTrue(ctx.finished)
        let resolved = try PythonWorker.resolve(result: ctx.result, error: ctx.error)
        XCTAssertEqual(resolved.tldr, "Summary.", "a delivered final must survive a trailing error")
    }

    func testFinalThenDeathStillResolvesToResult() throws {
        let worker = makeWorker()
        let ctx = worker.test_makeCapture(seq: 2)
        worker.test_route(.final(seq: 2, payload: samplePayload(seq: 2)), ctx: ctx)
        worker.test_complete(ctx, error: .died)   // process died after delivering final
        let resolved = try PythonWorker.resolve(result: ctx.result, error: ctx.error)
        XCTAssertEqual(resolved.tldr, "Summary.")
    }

    // handleData() framing + routing

    func testHandleDataBuffersPartialLines() {
        let worker = makeWorker()
        let ctx = worker.test_makeCapture(seq: 7)
        worker.test_setActive(ctx)
        let bytes = Array((finalLine(seq: 7) + "\n").utf8)
        let split = bytes.count / 2
        worker.test_handleData(Data(bytes[..<split]))
        XCTAssertNil(ctx.result, "a partial line must not resolve yet")
        worker.test_handleData(Data(bytes[split...]))
        XCTAssertNotNil(ctx.result, "the completed line must route the final payload")
    }

    func testHandleDataDropsMismatchedSeqLine() {
        let worker = makeWorker()
        let ctx = worker.test_makeCapture(seq: 7)
        worker.test_setActive(ctx)
        worker.test_handleData(Data((finalLine(seq: 8) + "\n").utf8))
        XCTAssertNil(ctx.result, "a final for a different seq must be ignored")
    }
}
