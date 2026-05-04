import AppKit
import CoreGraphics

enum OverlayKeyCommand: Equatable {
    case choice(Int)
    case dismiss
    case insert
}

struct OverlayKeyRouter {
    private static let choiceKeyCodes: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3]
    private static let returnKeyCodes: Set<UInt16> = [36, 76]
    private static let escapeKeyCode: UInt16 = 53
    private static let blockingCGFlags: CGEventFlags = [
        .maskCommand, .maskControl, .maskAlternate, .maskShift,
    ]
    private static let blockingNSEventFlags: NSEvent.ModifierFlags = [
        .command, .control, .option, .shift,
    ]

    static func command(forCGKeyCode keyCode: CGKeyCode, flags: CGEventFlags, customInputActive: Bool) -> OverlayKeyCommand? {
        command(
            keyCode: UInt16(keyCode),
            hasBlockingModifier: !flags.intersection(blockingCGFlags).isEmpty,
            customInputActive: customInputActive
        )
    }

    static func command(for event: NSEvent, customInputActive: Bool) -> OverlayKeyCommand? {
        command(
            keyCode: event.keyCode,
            hasBlockingModifier: !event.modifierFlags.intersection(blockingNSEventFlags).isEmpty,
            customInputActive: customInputActive
        )
    }

    private static func command(keyCode: UInt16, hasBlockingModifier: Bool, customInputActive: Bool) -> OverlayKeyCommand? {
        guard !hasBlockingModifier else { return nil }

        if customInputActive {
            return keyCode == escapeKeyCode ? .dismiss : nil
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
