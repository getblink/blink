import AppKit
import Foundation

enum NudgeReason {
    case appSwitchOscillation(bundleID: String)
}

@MainActor
final class BackgroundActivityMonitor {
    private struct Activation {
        let bundleID: String
        let at: Date
    }

    private let windowSeconds: TimeInterval = 60
    private let minReturnCount = 3
    private let bufferCap = 16

    private let nudgesEnabled: @MainActor () -> Bool
    private let shouldSuppress: @MainActor () -> Bool
    private let lastNudgeAt: @MainActor () -> Date?
    private let cooldownMinutes: @MainActor () -> Int
    private let onTrigger: @MainActor (NudgeReason) -> Void

    private var observer: NSObjectProtocol?
    private var buffer: [Activation] = []
    private var lastNudgedBundleID: String?
    private var lastNudgeFiredAt: Date?

    private let ownBundleID = Bundle.main.bundleIdentifier

    init(
        nudgesEnabled: @MainActor @escaping () -> Bool,
        shouldSuppress: @MainActor @escaping () -> Bool,
        lastNudgeAt: @MainActor @escaping () -> Date?,
        cooldownMinutes: @MainActor @escaping () -> Int,
        onTrigger: @MainActor @escaping (NudgeReason) -> Void
    ) {
        self.nudgesEnabled = nudgesEnabled
        self.shouldSuppress = shouldSuppress
        self.lastNudgeAt = lastNudgeAt
        self.cooldownMinutes = cooldownMinutes
        self.onTrigger = onTrigger
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                self?.handleActivation(bundleID: bundleID)
            }
        }
    }

    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
        buffer.removeAll(keepingCapacity: false)
    }

    func noteTriggered(bundleID: String) {
        lastNudgedBundleID = bundleID
        lastNudgeFiredAt = Date()
        buffer.removeAll(keepingCapacity: true)
    }

    private func handleActivation(bundleID: String?) {
        guard let bundleID, !bundleID.isEmpty else { return }
        if bundleID == ownBundleID { return }

        let now = Date()
        buffer.append(Activation(bundleID: bundleID, at: now))
        let cutoff = now.addingTimeInterval(-windowSeconds)
        buffer.removeAll { $0.at < cutoff }
        if buffer.count > bufferCap {
            buffer.removeFirst(buffer.count - bufferCap)
        }

        guard nudgesEnabled() else { return }
        guard !shouldSuppress() else { return }
        guard cooldownElapsed(now: now) else { return }
        guard !sameAsLastNudge(bundleID: bundleID, now: now) else { return }

        let returnsToBundle = buffer.reduce(into: 0) { $0 += ($1.bundleID == bundleID ? 1 : 0) }
        guard returnsToBundle >= minReturnCount else { return }

        let hasOtherApp = buffer.contains { $0.bundleID != bundleID }
        guard hasOtherApp else { return }

        onTrigger(.appSwitchOscillation(bundleID: bundleID))
    }

    private func cooldownElapsed(now: Date) -> Bool {
        let minutes = max(1, cooldownMinutes())
        let cooldown = TimeInterval(minutes) * 60
        if let lastFired = lastNudgeFiredAt, now.timeIntervalSince(lastFired) < cooldown {
            return false
        }
        if let persisted = lastNudgeAt(), now.timeIntervalSince(persisted) < cooldown {
            return false
        }
        return true
    }

    private func sameAsLastNudge(bundleID: String, now: Date) -> Bool {
        guard let last = lastNudgedBundleID, last == bundleID else { return false }
        let minutes = max(1, cooldownMinutes())
        let cooldown = TimeInterval(minutes) * 60
        if let lastFired = lastNudgeFiredAt {
            return now.timeIntervalSince(lastFired) < cooldown
        }
        return true
    }
}
