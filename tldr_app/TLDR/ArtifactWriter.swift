import Foundation

/// Minimal file I/O helpers for the Swift side. `run_once.py` owns the bundle
/// dir under `runs/<bundleId>/`; Swift stages PNGs + metadata in a tmp dir and
/// passes those paths to Python.
enum ArtifactWriter {
    static func newBundleID() -> String {
        timestampID()
    }

    static func writeJSON(_ object: Any, to url: URL) throws {
        let safe = jsonSafe(object)
        let data = try JSONSerialization.data(
            withJSONObject: safe,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }

    private static func jsonSafe(_ value: Any) -> Any {
        if value is NSNull { return NSNull() }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n }
        if let b = value as? Bool { return b }
        if let dict = value as? [String: Any] {
            return dict.mapValues { jsonSafe($0) }
        }
        if let arr = value as? [Any] {
            return arr.map { jsonSafe($0) }
        }
        // Optional<Any> wrapped as Any — stringify or null.
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let unwrapped = mirror.children.first?.value else { return NSNull() }
            return jsonSafe(unwrapped)
        }
        return String(describing: value)
    }

    private static func timestampID() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter.string(from: Date())
    }
}
