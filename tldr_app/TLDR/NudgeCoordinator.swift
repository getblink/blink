import AppKit
import Foundation

@MainActor
final class NudgeCoordinator {
    private let runtimeStore: RuntimeConfigStore
    private let eventClient: TLDREventClient
    private let hotkeyDisplay: String
    private let menubarFrame: () -> NSRect?
    private let pulseMenubar: () -> Void
    private let isCoordinatorBusy: () -> Bool

    private let overlay = NudgeOverlay()
    private var monitor: BackgroundActivityMonitor!
    private var pendingNudge: PendingNudge?
    private var hitWindowTimer: Timer?

    private let hitWindowSeconds: TimeInterval = 30
    private let dismissWindowDays: TimeInterval = 7
    private let autoDisableThreshold = 3

    private struct PendingNudge {
        let requestID: String
        let bundleID: String
        let firedAt: Date
        let reasonString: String
    }

    init(
        runtimeStore: RuntimeConfigStore,
        eventClient: TLDREventClient,
        hotkeyDisplay: String,
        menubarFrame: @escaping () -> NSRect?,
        pulseMenubar: @escaping () -> Void,
        isCoordinatorBusy: @escaping () -> Bool
    ) {
        self.runtimeStore = runtimeStore
        self.eventClient = eventClient
        self.hotkeyDisplay = hotkeyDisplay
        self.menubarFrame = menubarFrame
        self.pulseMenubar = pulseMenubar
        self.isCoordinatorBusy = isCoordinatorBusy

        let nudgesEnabledClosure: @MainActor () -> Bool = { [weak self] in
            self?.runtimeStore.nudgesEnabled ?? false
        }
        let shouldSuppressClosure: @MainActor () -> Bool = { [weak self] in
            guard let self else { return true }
            if self.isCoordinatorBusy() { return true }
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier {
                return true
            }
            return false
        }
        let lastNudgeAtClosure: @MainActor () -> Date? = { [weak self] in
            self?.runtimeStore.lastNudgeAt
        }
        let cooldownMinutesClosure: @MainActor () -> Int = { [weak self] in
            self?.runtimeStore.nudgeCooldownMinutes ?? 30
        }
        let onTriggerClosure: @MainActor (NudgeReason) -> Void = { [weak self] reason in
            self?.fireNudge(reason: reason)
        }
        self.monitor = BackgroundActivityMonitor(
            nudgesEnabled: nudgesEnabledClosure,
            shouldSuppress: shouldSuppressClosure,
            lastNudgeAt: lastNudgeAtClosure,
            cooldownMinutes: cooldownMinutesClosure,
            onTrigger: onTriggerClosure
        )
    }

    func start() { monitor.start() }
    func stop() {
        monitor.stop()
        hitWindowTimer?.invalidate()
        hitWindowTimer = nil
        overlay.close(userClicked: false, animated: false)
        pendingNudge = nil
    }

    /// Called from the hotkey path. If a nudge is currently pending within the
    /// hit window, record it as a successful follow-through.
    func noteHotkeyInvoked() {
        guard let pending = pendingNudge else { return }
        guard Date().timeIntervalSince(pending.firedAt) <= hitWindowSeconds else {
            clearPending()
            return
        }
        emit(
            requestID: pending.requestID,
            type: "nudge_followed_by_invoke",
            details: [
                "nudge_reason": pending.reasonString,
                "trigger_bundle_id": pending.bundleID,
                "elapsed_ms": Int(Date().timeIntervalSince(pending.firedAt) * 1000),
            ]
        )
        runtimeStore.recentNudgeDismissals = []
        clearPending()
    }

    private func fireNudge(reason: NudgeReason) {
        guard let frame = menubarFrame() else { return }
        let bundleID: String
        let reasonString: String
        switch reason {
        case .appSwitchOscillation(let id):
            bundleID = id
            reasonString = "app_switch_oscillation"
        }

        let requestID = UUID().uuidString.lowercased()
        let firedAt = Date()
        pendingNudge = PendingNudge(
            requestID: requestID,
            bundleID: bundleID,
            firedAt: firedAt,
            reasonString: reasonString
        )
        runtimeStore.lastNudgeAt = firedAt
        monitor.noteTriggered(bundleID: bundleID)

        pulseMenubar()
        overlay.show(
            text: "Reply with TLDR — \(hotkeyDisplay)",
            anchor: frame,
            autoDismissAfter: 4.0
        ) { _ in
            // The visible-card lifecycle is independent of the hit-tracking
            // window. We do not record a dismissal here — the 30s timer is the
            // source of truth for hit-vs-miss.
        }

        emit(
            requestID: requestID,
            type: "nudge_shown",
            details: [
                "nudge_reason": reasonString,
                "trigger_bundle_id": bundleID,
            ]
        )

        hitWindowTimer?.invalidate()
        let timer = Timer(timeInterval: hitWindowSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.expirePendingAsDismissal()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hitWindowTimer = timer
    }

    private func expirePendingAsDismissal() {
        guard let pending = pendingNudge else { return }
        // If the user disabled Nudges between fire and expiry, don't penalize
        // them with a dismissal that could trip the auto-disable threshold on
        // the next re-enable.
        if runtimeStore.nudgesEnabled {
            recordDismissal()
        }
        emit(
            requestID: pending.requestID,
            type: "nudge_dismissed",
            details: [
                "nudge_reason": pending.reasonString,
                "trigger_bundle_id": pending.bundleID,
            ]
        )
        clearPending()
    }

    private func recordDismissal() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-dismissWindowDays * 24 * 3600)
        var dismissals = runtimeStore.recentNudgeDismissals.filter { $0 >= cutoff }
        dismissals.append(now)
        runtimeStore.recentNudgeDismissals = dismissals
        if dismissals.count >= autoDisableThreshold {
            runtimeStore.nudgesEnabled = false
        }
    }

    private func clearPending() {
        pendingNudge = nil
        hitWindowTimer?.invalidate()
        hitWindowTimer = nil
    }

    private func emit(requestID: String, type: String, details: [String: Any]) {
        eventClient.send(
            requestID: requestID,
            eventType: type,
            allowLogging: runtimeStore.allowEventLogging,
            clientMetadata: TLDRCoordinator.clientMetadata(),
            details: details,
            completion: nil
        )
    }
}
