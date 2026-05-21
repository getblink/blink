import Foundation

/// Allowed model identifiers exposed in Blink's UI surfaces (menubar, control
/// window). Kept here rather than on `MenubarController` so multiple surfaces
/// can share the list without one importing the other.
enum ModelChoices {
    static let allowed: [String] = [
        "gemini-3.5-flash",
        "gemini-3-flash-preview",
        "gemini-3.1-flash-lite-preview",
        "gemini-3.1-pro-preview",
        "gemma-4-26b-a4b-it",
    ]

    /// Standard list, but with the user's current selection guaranteed to be
    /// at the front if it isn't already in the list. Lets us surface custom
    /// model strings the user has set via `~/.blink/runtime-config.json`.
    static func optionsIncluding(current: String) -> [String] {
        var options = allowed
        if !options.contains(current) {
            options.insert(current, at: 0)
        }
        return options
    }
}
