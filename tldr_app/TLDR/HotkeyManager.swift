import Carbon.HIToolbox
import CoreGraphics
import IOKit.hid

final class HotkeyManager {
    private let isOverlayActive: () -> Bool
    private let onSummarize: () -> Void
    private let onChoice: (Int) -> Void
    private let onInsert: () -> Bool
    private let onDismiss: () -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private let summaryKeyCode: CGKeyCode = 17
    private let choiceKeyCodes: [CGKeyCode: Int] = [18: 0, 19: 1, 20: 2]
    private let returnKeyCodes: Set<CGKeyCode> = [36, 76]
    private let escapeKeyCode: CGKeyCode = 53
    private let summaryFlags: CGEventFlags = [.maskControl, .maskShift]
    private let relevantFlags: CGEventFlags = [
        .maskCommand, .maskControl, .maskAlternate, .maskShift,
        .maskSecondaryFn, .maskNumericPad, .maskHelp, .maskAlphaShift,
    ]

    init(
        isOverlayActive: @escaping () -> Bool,
        onSummarize: @escaping () -> Void,
        onChoice: @escaping (Int) -> Void,
        onInsert: @escaping () -> Bool,
        onDismiss: @escaping () -> Void
    ) {
        self.isOverlayActive = isOverlayActive
        self.onSummarize = onSummarize
        self.onChoice = onChoice
        self.onInsert = onInsert
        self.onDismiss = onDismiss
    }

    @discardableResult
    func start() -> Bool {
        stop()
        let mask = (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: HotkeyManager.tapCallback,
            userInfo: refcon
        ) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.eventTap = tap
        self.runLoopSource = source
        return true
    }

    static func inputMonitoringGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = manager.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.intersection(manager.relevantFlags)

        if manager.isOverlayActive(), flags.isEmpty {
            if let index = manager.choiceKeyCodes[keyCode] {
                DispatchQueue.main.async { manager.onChoice(index) }
                return nil
            }
            if keyCode == manager.escapeKeyCode {
                DispatchQueue.main.async { manager.onDismiss() }
                return nil
            }
            if manager.returnKeyCodes.contains(keyCode) {
                return manager.onInsert() ? nil : Unmanaged.passUnretained(event)
            }
        }

        if keyCode == manager.summaryKeyCode && flags == manager.summaryFlags {
            DispatchQueue.main.async { manager.onSummarize() }
            return nil
        }

        return Unmanaged.passUnretained(event)
    }
}
