import AppKit
import Carbon.HIToolbox
import IOKit.hid

/// Global hotkey manager using `CGEventTap`. Default bindings:
///   ⌃⇧C → onSetSource
///   ⌃⇧V → onRunTarget
///
/// Intercepts the events (returns nil from the tap callback) so they don't
/// reach the frontmost app. Requires Input Monitoring + Accessibility.
final class HotkeyManager {
    private let onSetSource: () -> Void
    private let onRunTarget: () -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Cocoa C keyCode = 8, V = 9. ctrl+shift = .maskControl | .maskShift.
    private let sourceKeyCode: CGKeyCode = 8
    private let targetKeyCode: CGKeyCode = 9
    private let requiredFlags: CGEventFlags = [.maskControl, .maskShift]
    private let ignoredFlags: CGEventFlags = [
        .maskAlphaShift, .maskCommand, .maskAlternate, .maskSecondaryFn,
        .maskNumericPad, .maskHelp,
    ]

    init(onSetSource: @escaping () -> Void, onRunTarget: @escaping () -> Void) {
        self.onSetSource = onSetSource
        self.onRunTarget = onRunTarget
    }

    /// Returns true if tap installed successfully; false if the OS denied us
    /// (usually Input Monitoring/Accessibility not granted).
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
        guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
        let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = manager.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        guard flags.contains(manager.requiredFlags) else {
            return Unmanaged.passUnretained(event)
        }
        // Reject if any disallowed modifier is also held (e.g. Cmd).
        if flags.intersection(manager.ignoredFlags).intersection([.maskCommand, .maskAlternate]) != [] {
            return Unmanaged.passUnretained(event)
        }

        if keyCode == manager.sourceKeyCode {
            DispatchQueue.main.async { manager.onSetSource() }
            return nil
        }
        if keyCode == manager.targetKeyCode {
            DispatchQueue.main.async { manager.onRunTarget() }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
}
