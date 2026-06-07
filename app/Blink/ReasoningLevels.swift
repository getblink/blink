import Foundation

/// Reasoning-level titles/values shared between Control window, Settings,
/// and the main menu's `View ▸ Reasoning` submenu so every surface reads
/// from the same source of truth.
enum ReasoningLevels {
    static let titles: [String] = ["Default", "Off", "Low", "Medium", "High"]

    /// Concrete levels the overlay ⌘T toggle cycles through. "Default" (nil)
    /// is deliberately excluded — a per-surface pick is itself the override.
    static let cycleValues: [String] = ["off", "low", "medium", "high"]

    /// Next level in the `Off → Low → Medium → High → Off` cycle. A nil or
    /// unrecognized current value (e.g. global "Default") enters at "off".
    static func next(after level: String?) -> String {
        guard let level = level?.lowercased(),
              let idx = cycleValues.firstIndex(of: level) else {
            return cycleValues[0]
        }
        return cycleValues[(idx + 1) % cycleValues.count]
    }

    static func title(for level: String?) -> String {
        switch level?.lowercased() {
        case "off": return "Off"
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        default: return "Default"
        }
    }

    static func value(for title: String) -> String? {
        switch title {
        case "Off": return "off"
        case "Low": return "low"
        case "Medium": return "medium"
        case "High": return "high"
        default: return nil
        }
    }
}
