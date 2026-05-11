import Foundation

protocol BlinkEventSending {
    func send(
        requestID: String,
        eventType: String,
        allowLogging: Bool,
        clientMetadata: [String: Any],
        details: [String: Any],
        completion: ((Bool) -> Void)?
    )
}

final class BlinkEventClient: BlinkEventSending {
    private let proxyConfig: ProxyConfig?
    private let session: URLSession

    init(proxyConfig: ProxyConfig?) {
        self.proxyConfig = proxyConfig
        self.session = URLSession(configuration: .ephemeral)
    }

    var isConfigured: Bool {
        proxyConfig != nil
    }

    func send(
        requestID: String,
        eventType: String,
        allowLogging: Bool,
        clientMetadata: [String: Any],
        details: [String: Any] = [:],
        completion: ((Bool) -> Void)? = nil
    ) {
        send(
            requestID: requestID,
            eventType: eventType,
            allowLogging: allowLogging,
            clientMetadata: clientMetadata,
            details: details,
            createdAt: nil,
            completion: completion
        )
    }

    func send(
        requestID: String,
        eventType: String,
        allowLogging: Bool,
        clientMetadata: [String: Any],
        details: [String: Any] = [:],
        createdAt: String?,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard allowLogging, let proxyConfig else {
            completion?(false)
            return
        }

        var body: [String: Any] = [
            "schema_version": 1,
            "request_id": requestID,
            "event_type": eventType,
            "created_at": createdAt ?? JSONFiles.isoString(),
            "client": clientMetadata,
        ]
        if !details.isEmpty {
            body["details"] = details
        }

        guard JSONSerialization.isValidJSONObject(JSONFiles.jsonSafe(body)) else {
            completion?(false)
            return
        }
        var request = URLRequest(url: proxyConfig.baseURL.appendingPathComponent("v1/tldr/events"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(proxyConfig.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: JSONFiles.jsonSafe(body))
        session.dataTask(with: request) { data, response, error in
            completion?(Self.deliverySucceeded(data: data, response: response, error: error))
        }.resume()
    }

    static func deliverySucceeded(data: Data?, response: URLResponse?, error: Error?) -> Bool {
        guard error == nil,
              let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode),
              let data,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stored = payload["stored"] as? Bool else {
            return false
        }
        return stored
    }
}
