import Carbon.HIToolbox
import CoreGraphics
import Foundation
import IOKit.hid

final class HotkeyManager {
    private final class CallbackContext {
        weak var manager: HotkeyManager?
        let generation: UInt64
        private let lock = NSLock()
        private var active = true
        private var tap: CFMachPort?

        init(manager: HotkeyManager, generation: UInt64) {
            self.manager = manager
            self.generation = generation
        }

        func setTap(_ tap: CFMachPort) {
            lock.lock()
            self.tap = tap
            lock.unlock()
        }

        func invalidate() {
            lock.lock()
            active = false
            tap = nil
            lock.unlock()
        }

        var isActive: Bool {
            lock.lock()
            defer { lock.unlock() }
            return active
        }

        func reenableTapIfActive() {
            lock.lock()
            let activeTap = active ? tap : nil
            lock.unlock()
            if let activeTap {
                CGEvent.tapEnable(tap: activeTap, enable: true)
            }
        }
    }

    private final class TapThreadHandoff {
        let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var succeeded = false

        func signal(success: Bool) {
            lock.lock()
            succeeded = succeeded || success
            lock.unlock()
            semaphore.signal()
        }

        var wasSuccessful: Bool {
            lock.lock()
            defer { lock.unlock() }
            return succeeded
        }
    }

    private let isOverlayActive: () -> Bool
    private let isCustomInputActive: () -> Bool
    private let isCollectingActive: () -> Bool
    private let onSummarize: (DispatchTime) -> Void
    private let onSummaryHotkeyWhileOverlay: (DispatchTime) -> Void
    private let onSubmitCollecting: () -> Void
    private let onCancelCollecting: () -> Void
    private let onChoicePreflight: (Int) -> Void
    private let onChoice: (Int) -> Void
    private let shouldConsumeInsert: () -> Bool
    private let onInsert: () -> Void
    private let onCustomInsert: () -> Void
    private let onLeaveCustomInput: () -> Void
    private let onTextEditing: (TextEditingShortcut) -> Void
    private let onReroll: () -> Void
    private let onTogglePin: () -> Void
    private let onArrowNav: (OverlayArrowDirection) -> Void
    private let onDismiss: () -> Void
    private let tapStateLock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var tapThread: Thread?
    private var tapGeneration: UInt64 = 0
    private var callbackContext: CallbackContext?

    private let summaryKeyCode: CGKeyCode
    private let summaryFlags: CGEventFlags
    private let returnKeyCode: CGKeyCode = 36
    private let escapeKeyCode: CGKeyCode = 53
    private let relevantFlags: CGEventFlags = [
        .maskCommand, .maskControl, .maskAlternate, .maskShift,
        .maskSecondaryFn, .maskNumericPad, .maskHelp, .maskAlphaShift,
    ]

    init(
        summaryHotkey: Hotkey,
        isOverlayActive: @escaping () -> Bool,
        isCustomInputActive: @escaping () -> Bool,
        isCollectingActive: @escaping () -> Bool,
        onSummarize: @escaping (DispatchTime) -> Void,
        onSummaryHotkeyWhileOverlay: @escaping (DispatchTime) -> Void,
        onSubmitCollecting: @escaping () -> Void,
        onCancelCollecting: @escaping () -> Void,
        onChoicePreflight: @escaping (Int) -> Void,
        onChoice: @escaping (Int) -> Void,
        shouldConsumeInsert: @escaping () -> Bool,
        onInsert: @escaping () -> Void,
        onCustomInsert: @escaping () -> Void,
        onLeaveCustomInput: @escaping () -> Void,
        onTextEditing: @escaping (TextEditingShortcut) -> Void,
        onReroll: @escaping () -> Void,
        onTogglePin: @escaping () -> Void,
        onArrowNav: @escaping (OverlayArrowDirection) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.summaryKeyCode = summaryHotkey.keyCode
        self.summaryFlags = summaryHotkey.flags
        self.isOverlayActive = isOverlayActive
        self.isCustomInputActive = isCustomInputActive
        self.isCollectingActive = isCollectingActive
        self.onSummarize = onSummarize
        self.onSummaryHotkeyWhileOverlay = onSummaryHotkeyWhileOverlay
        self.onSubmitCollecting = onSubmitCollecting
        self.onCancelCollecting = onCancelCollecting
        self.onChoicePreflight = onChoicePreflight
        self.onChoice = onChoice
        self.shouldConsumeInsert = shouldConsumeInsert
        self.onInsert = onInsert
        self.onCustomInsert = onCustomInsert
        self.onLeaveCustomInput = onLeaveCustomInput
        self.onTextEditing = onTextEditing
        self.onReroll = onReroll
        self.onTogglePin = onTogglePin
        self.onArrowNav = onArrowNav
        self.onDismiss = onDismiss
    }

    @discardableResult
    func start() -> Bool {
        stop()
        TCCDiagnostics.log("hotkey_event_tap_create_attempt")
        let generation = nextTapGeneration()
        let context = CallbackContext(manager: self, generation: generation)
        let mask = (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(context).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: HotkeyManager.tapCallback,
            userInfo: refcon
        ) else {
            TCCDiagnostics.log("hotkey_event_tap_create_failed")
            return false
        }
        context.setTap(tap)
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let handoff = TapThreadHandoff()

        let thread = Thread { [weak self, context, source, tap] in
            guard let self else {
                context.invalidate()
                handoff.signal(success: false)
                return
            }
            let runLoop = CFRunLoopGetCurrent()
            var shouldRun = false
            self.tapStateLock.lock()
            if self.tapGeneration == generation && self.callbackContext === context {
                self.tapRunLoop = runLoop
                self.runLoopSource = source
                shouldRun = true
            }
            self.tapStateLock.unlock()

            guard shouldRun, context.isActive else {
                context.invalidate()
                handoff.signal(success: false)
                return
            }

            CFRunLoopAddSource(runLoop, source, .commonModes)
            guard context.isActive else {
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
                handoff.signal(success: false)
                return
            }
            CGEvent.tapEnable(tap: tap, enable: true)
            guard context.isActive else {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
                handoff.signal(success: false)
                return
            }
            handoff.signal(success: true)

            CFRunLoopRun()

            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            context.invalidate()

            self.tapStateLock.lock()
            if self.tapGeneration == generation && self.callbackContext === context {
                self.eventTap = nil
                self.runLoopSource = nil
                self.tapRunLoop = nil
                self.tapThread = nil
                self.callbackContext = nil
            }
            self.tapStateLock.unlock()
        }
        thread.name = "com.blink.hotkey-tap"
        thread.qualityOfService = .userInteractive

        tapStateLock.lock()
        eventTap = tap
        runLoopSource = source
        tapThread = thread
        callbackContext = context
        tapStateLock.unlock()

        thread.start()

        guard handoff.semaphore.wait(timeout: .now() + .milliseconds(500)) == .success,
              handoff.wasSuccessful
        else {
            TCCDiagnostics.log("hotkey_event_tap_thread_handoff_timeout")
            context.invalidate()
            tapStateLock.lock()
            let runLoop = tapRunLoop
            if callbackContext === context {
                eventTap = nil
                runLoopSource = nil
                tapRunLoop = nil
                tapThread = nil
                callbackContext = nil
                tapGeneration &+= 1
            }
            tapStateLock.unlock()
            CGEvent.tapEnable(tap: tap, enable: false)
            if let runLoop {
                CFRunLoopStop(runLoop)
            }
            return false
        }

        TCCDiagnostics.log("hotkey_event_tap_create_succeeded")
        return true
    }

    static func inputMonitoringGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    func stop() {
        tapStateLock.lock()
        tapGeneration &+= 1
        let tap = eventTap
        let runLoop = tapRunLoop
        let context = callbackContext
        eventTap = nil
        runLoopSource = nil
        tapRunLoop = nil
        tapThread = nil
        callbackContext = nil
        tapStateLock.unlock()

        context?.invalidate()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
    }

    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let context = Unmanaged<CallbackContext>.fromOpaque(refcon).takeUnretainedValue()
        guard context.isActive,
              let manager = context.manager
        else {
            return Unmanaged.passUnretained(event)
        }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            context.reenableTapIfActive()
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.intersection(manager.relevantFlags)

        if manager.isCollectingActive() {
            if keyCode == manager.summaryKeyCode && flags == manager.summaryFlags {
                let pressedAt = DispatchTime.now()
                DispatchQueue.main.async { manager.onSummarize(pressedAt) }
                return nil
            }
            if keyCode == manager.returnKeyCode && flags.isEmpty {
                DispatchQueue.main.async { manager.onSubmitCollecting() }
                return nil
            }
            if keyCode == manager.escapeKeyCode && flags.isEmpty {
                DispatchQueue.main.async { manager.onCancelCollecting() }
                return nil
            }
        }

        if manager.isOverlayActive(),
           keyCode == manager.summaryKeyCode,
           flags == manager.summaryFlags {
            // While the overlay is visible, the configured summary hotkey intentionally rerolls instead of starting a fresh capture; Cmd-R maps here too.
            let pressedAt = DispatchTime.now()
            DispatchQueue.main.async {
                manager.onSummaryHotkeyWhileOverlay(pressedAt)
                manager.onReroll()
            }
            return nil
        }

        if manager.isOverlayActive(),
           let command = OverlayKeyRouter.command(
            forCGKeyCode: keyCode,
            flags: event.flags,
            customInputActive: manager.isCustomInputActive()
           ) {
            switch command {
            case .choice(let index):
                manager.onChoicePreflight(index)
                DispatchQueue.main.async { manager.onChoice(index) }
                return nil
            case .dismiss:
                DispatchQueue.main.async { manager.onDismiss() }
                return nil
            case .insert:
                guard manager.shouldConsumeInsert() else {
                    return Unmanaged.passUnretained(event)
                }
                DispatchQueue.main.async { manager.onInsert() }
                return nil
            case .insertCustomInput:
                DispatchQueue.main.async { manager.onCustomInsert() }
                return nil
            case .leaveCustomInput:
                DispatchQueue.main.async { manager.onLeaveCustomInput() }
                return nil
            case .reroll:
                DispatchQueue.main.async { manager.onReroll() }
                return nil
            case .togglePin:
                DispatchQueue.main.async { manager.onTogglePin() }
                return nil
            case .moveSelectionUp:
                DispatchQueue.main.async { manager.onArrowNav(.up) }
                return nil
            case .moveSelectionDown:
                DispatchQueue.main.async { manager.onArrowNav(.down) }
                return nil
            case .textEditing(let shortcut):
                DispatchQueue.main.async { manager.onTextEditing(shortcut) }
                return nil
            }
        }

        if keyCode == manager.summaryKeyCode && flags == manager.summaryFlags {
            let pressedAt = DispatchTime.now()
            DispatchQueue.main.async { manager.onSummarize(pressedAt) }
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private func nextTapGeneration() -> UInt64 {
        tapStateLock.lock()
        tapGeneration &+= 1
        let generation = tapGeneration
        tapStateLock.unlock()
        return generation
    }
}
