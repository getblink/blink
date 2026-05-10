import Foundation

enum JSONFiles {
    static func readObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return payload
    }

    static func readArray(at url: URL) -> [Any]? {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return nil
        }
        return payload
    }

    static func writeObject(_ object: Any, to url: URL) throws {
        try ArtifactWriter.writeJSON(object, to: url)
    }

    static func jsonSafe(_ value: Any) -> Any {
        if value is NSNull { return NSNull() }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number }
        if let bool = value as? Bool { return bool }
        if let dict = value as? [String: Any] {
            return dict.mapValues { jsonSafe($0) }
        }
        if let array = value as? [Any] {
            return array.map { jsonSafe($0) }
        }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let unwrapped = mirror.children.first?.value else { return NSNull() }
            return jsonSafe(unwrapped)
        }
        return String(describing: value)
    }

    static func isoString(_ date: Date = Date()) -> String {
        isoFormatter.string(from: date)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()
}
