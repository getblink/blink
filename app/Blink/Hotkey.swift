import Carbon.HIToolbox
import CoreGraphics
import Foundation

struct Hotkey: Equatable {
    let keyCode: CGKeyCode
    let flags: CGEventFlags

    static let `default` = Hotkey(
        keyCode: CGKeyCode(kVK_Space),
        flags: [.maskControl, .maskAlternate]
    )

    static func parse(_ raw: String) -> Hotkey? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let tokens = trimmed
            .split(whereSeparator: { $0 == "+" || $0 == "-" || $0 == " " })
            .flatMap(Self.expandCompactGlyphToken)
        guard !tokens.isEmpty else { return nil }
        var flags: CGEventFlags = []
        var keyToken: String? = nil
        for token in tokens {
            if let modifier = Self.modifierFlag(for: token) {
                if flags.contains(modifier) { return nil }
                flags.insert(modifier)
                continue
            }
            if keyToken != nil { return nil }
            keyToken = token
        }
        guard let keyToken,
              let keyCode = Self.keyCode(for: keyToken),
              !flags.isEmpty
        else { return nil }
        return Hotkey(keyCode: keyCode, flags: flags)
    }

    static func loadFromSettings(at url: URL?) -> Hotkey {
        guard let url,
              let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let dict = parsed as? [String: Any],
              let raw = dict["hotkey"] as? String
        else { return .default }
        if let hotkey = parse(raw) {
            return hotkey
        }
        NSLog("Blink: invalid hotkey '%@' in settings.json; using default", raw)
        return .default
    }

    var displayString: String {
        var parts: [String] = []
        if flags.contains(.maskControl) { parts.append("⌃") }
        if flags.contains(.maskAlternate) { parts.append("⌥") }
        if flags.contains(.maskShift) { parts.append("⇧") }
        if flags.contains(.maskCommand) { parts.append("⌘") }
        if flags.contains(.maskSecondaryFn) { parts.append("fn+") }
        parts.append(Self.displayKey(for: keyCode))
        return parts.joined()
    }

    /// One token per key/modifier, in canonical order — for surfaces that
    /// want to render each part as its own keycap badge rather than a single
    /// concatenated string. Example: `["⌃", "⌥", "Space"]`.
    var displayParts: [String] {
        var parts: [String] = []
        if flags.contains(.maskControl) { parts.append("⌃") }
        if flags.contains(.maskAlternate) { parts.append("⌥") }
        if flags.contains(.maskShift) { parts.append("⇧") }
        if flags.contains(.maskCommand) { parts.append("⌘") }
        if flags.contains(.maskSecondaryFn) { parts.append("fn") }
        parts.append(Self.displayKey(for: keyCode))
        return parts
    }

    private static func modifierFlag(for token: String) -> CGEventFlags? {
        switch token {
        case "cmd", "command", "⌘": return .maskCommand
        case "ctrl", "control", "⌃": return .maskControl
        case "opt", "option", "alt", "⌥": return .maskAlternate
        case "shift", "⇧": return .maskShift
        case "fn": return .maskSecondaryFn
        default: return nil
        }
    }

    private static func expandCompactGlyphToken(_ token: Substring) -> [String] {
        var parts: [String] = []
        var remainder = token[...]
        while let first = remainder.first, ["⌘", "⌃", "⌥", "⇧"].contains(first) {
            parts.append(String(first))
            remainder = remainder.dropFirst()
        }
        if !remainder.isEmpty {
            parts.append(String(remainder))
        }
        return parts
    }

    private static let keyCodeMap: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "space": kVK_Space,
        "tab": kVK_Tab,
    ]

    private static func keyCode(for token: String) -> CGKeyCode? {
        keyCodeMap[token].map(CGKeyCode.init)
    }

    private static func displayKey(for keyCode: CGKeyCode) -> String {
        let target = Int(keyCode)
        if let entry = keyCodeMap.first(where: { $0.value == target }) {
            switch entry.key {
            case "space": return "Space"
            case "tab": return "⇥"
            default: return entry.key.uppercased()
            }
        }
        return "?"
    }
}
