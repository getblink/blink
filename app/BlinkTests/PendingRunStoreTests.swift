import Foundation
import XCTest
@testable import Blink

private final class MockEventClient: BlinkEventSending {
    var nextSuccess = false
    var sentRequestIDs: [String] = []

    func send(
        requestID: String,
        eventType: String,
        allowLogging: Bool,
        clientMetadata: [String: Any],
        details: [String: Any],
        completion: ((Bool) -> Void)?
    ) {
        sentRequestIDs.append(requestID)
        completion?(nextSuccess)
    }
}

final class PendingRunStoreTests: XCTestCase {
    func testSweepKeepsPendingFileWhenUploadFails() throws {
        let directory = try makeTempDirectory()
        let requestID = "req-failure"
        try PendingRunStore.create(
            requestID: requestID,
            payload: ["request_id": requestID, "last_phase": "capture_started"],
            directory: directory
        )

        let client = MockEventClient()
        client.nextSuccess = false
        PendingRunStore.sweepAbandonedRuns(
            eventClient: client,
            allowLogging: true,
            clientMetadata: [:],
            directory: directory
        )

        let fileURL = directory.appendingPathComponent("\(requestID).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let payload = JSONFiles.readObject(at: fileURL)
        XCTAssertEqual(payload?["abandoned_upload_retry_count"] as? Int, 1)
        XCTAssertNotNil(payload?["abandoned_upload_last_attempt_at"])
    }

    func testSweepDeletesPendingFileAfterSuccessfulUpload() throws {
        let directory = try makeTempDirectory()
        let requestID = "req-success"
        try PendingRunStore.create(
            requestID: requestID,
            payload: ["request_id": requestID, "last_phase": "capture_started"],
            directory: directory
        )

        let client = MockEventClient()
        client.nextSuccess = true
        PendingRunStore.sweepAbandonedRuns(
            eventClient: client,
            allowLogging: true,
            clientMetadata: [:],
            directory: directory
        )

        let fileURL = directory.appendingPathComponent("\(requestID).json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
