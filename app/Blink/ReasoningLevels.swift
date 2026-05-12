import Foundation

/// Reasoning-level titles/values shared between Control window, Settings,
/// and the main menu's `View ▸ Reasoning` submenu so every surface reads
/// from the same source of truth.
enum ReasoningLevels {
    static let titles: [String] = ["Default", "Low", "Medium", "High"]

    static func title(for level: String?) -> String {
        switch level?.lowercased() {
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        default: return "Default"
        }
    }

    static func value(for title: String) -> String? {
        switch title {
        case "Low": return "low"
        case "Medium": return "medium"
        case "High": return "high"
        default: return nil
        }
    }
}
