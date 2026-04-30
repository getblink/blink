import Foundation

enum PendingRunStore {
    static func create(
        requestID: String,
        payload: [String: Any],
        directory: URL = Paths.pendingDir
    ) throws {
        try JSONFiles.writeObject(payload, to: path(for: requestID, directory: directory))
    }

    static func update(
        requestID: String,
        directory: URL = Paths.pendingDir,
        mutate: (inout [String: Any]) -> Void
    ) {
        let url = path(for: requestID, directory: directory)
        guard var payload = JSONFiles.readObject(at: url) else { return }
        mutate(&payload)
        payload["updated_at"] = JSONFiles.isoString()
        try? JSONFiles.writeObject(payload, to: url)
    }

    static func finish(requestID: String, directory: URL = Paths.pendingDir) {
        try? FileManager.default.removeItem(at: path(for: requestID, directory: directory))
    }

    static func sweepAbandonedRuns(
        eventClient: TLDREventSending,
        allowLogging: Bool,
        clientMetadata: [String: Any],
        directory: URL = Paths.pendingDir
    ) {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }

        for item in items where item.pathExtension == "json" {
            guard let payload = JSONFiles.readObject(at: item),
                  let requestID = payload["request_id"] as? String else {
                try? FileManager.default.removeItem(at: item)
                continue
            }
            var details: [String: Any] = [
                "pending_record": payload,
            ]
            if let lastPhase = payload["last_phase"] {
                details["last_phase"] = lastPhase
            }
            eventClient.send(
                requestID: requestID,
                eventType: "previous_run_abandoned",
                allowLogging: allowLogging,
                clientMetadata: clientMetadata,
                details: details
            ) { success in
                if success {
                    try? FileManager.default.removeItem(at: item)
                    return
                }
                update(requestID: requestID, directory: directory) { payload in
                    payload["abandoned_upload_retry_count"] =
                        (payload["abandoned_upload_retry_count"] as? Int ?? 0) + 1
                    payload["abandoned_upload_last_attempt_at"] = JSONFiles.isoString()
                }
            }
        }
    }

    private static func path(for requestID: String, directory: URL) -> URL {
        directory.appendingPathComponent("\(requestID).json")
    }
}
