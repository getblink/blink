import AppKit
import CoreGraphics

enum OverlayKeyCommand: Equatable {
    case choice(Int)
    case dismiss
    case insert
    case insertCustomInput
    case leaveCustomInput
    case reroll
    case moveSelectionUp
    case moveSelectionDown
    case togglePin
    case resumeLastChat
    case textEditing(TextEditingShortcut)
}

enum TextEditingShortcut: Equatable {
    case selectAll
    case copy
    case paste
    case cut
}

struct OverlayKeyRouter {
    private static let choiceKeyCodes: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3]
    private static let arrowKeyCodes: [UInt16: OverlayKeyCommand] = [
        126: .moveSelectionUp,
        125: .moveSelectionDown,
    ]
    private static let textEditingKeyCodes: [UInt16: TextEditingShortcut] = [
        0: .selectAll,
        8: .copy,
        9: .paste,
        7: .cut,
    ]
    private static let returnKeyCodes: Set<UInt16> = [36, 76]
    private static let escapeKeyCode: UInt16 = 53
    private static let rerollKeyCode: UInt16 = 15
    private static let pinKeyCode: UInt16 = 35
    private static let undoKeyCode: UInt16 = 6
    private static let blockingCGFlags: CGEventFlags = [
        .maskCommand, .maskControl, .maskAlternate, .maskShift,
    ]
    private static let blockingNSEventFlags: NSEvent.ModifierFlags = [
        .command, .control, .option, .shift,
    ]

    static func command(forCGKeyCode keyCode: CGKeyCode, flags: CGEventFlags, customInputActive: Bool) -> OverlayKeyCommand? {
        command(
            keyCode: UInt16(keyCode),
            hasCommandOnlyModifier: flags.intersection(blockingCGFlags) == .maskCommand,
            hasBlockingModifier: !flags.intersection(blockingCGFlags).isEmpty,
            customInputActive: customInputActive
        )
    }

    static func command(for event: NSEvent, customInputActive: Bool) -> OverlayKeyCommand? {
        command(
            keyCode: event.keyCode,
            hasCommandOnlyModifier: event.modifierFlags.intersection(blockingNSEventFlags) == .command,
            hasBlockingModifier: !event.modifierFlags.intersection(blockingNSEventFlags).isEmpty,
            customInputActive: customInputActive
        )
    }

    private static func command(
        keyCode: UInt16,
        hasCommandOnlyModifier: Bool,
        hasBlockingModifier: Bool,
        customInputActive: Bool
    ) -> OverlayKeyCommand? {
        if keyCode == rerollKeyCode, hasCommandOnlyModifier {
            return .reroll
        }
        if keyCode == pinKeyCode, hasCommandOnlyModifier {
            return .togglePin
        }
        // Cmd+Z is only meaningful when the custom input field doesn't
        // own undo. The HotkeyManager tap further gates `.resumeLastChat`
        // on `isCollectingActive()` so Cmd+Z falls through to the focused
        // app once suggestions are visible.
        if keyCode == undoKeyCode, hasCommandOnlyModifier, !customInputActive {
            return .resumeLastChat
        }

        if customInputActive {
            if hasCommandOnlyModifier, let shortcut = textEditingKeyCodes[keyCode] {
                return .textEditing(shortcut)
            }
            guard !hasBlockingModifier else { return nil }
            if keyCode == escapeKeyCode {
                return .leaveCustomInput
            }
            if returnKeyCodes.contains(keyCode) {
                return .insertCustomInput
            }
            return nil
        }

        guard !hasBlockingModifier else { return nil }

        if let arrowCommand = arrowKeyCodes[keyCode] {
            return arrowCommand
        }
        if let index = choiceKeyCodes[keyCode] {
            return .choice(index)
        }
        if keyCode == escapeKeyCode {
            return .dismiss
        }
        if returnKeyCodes.contains(keyCode) {
            return .insert
        }
        return nil
    }
}
