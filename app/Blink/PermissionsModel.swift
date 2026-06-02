import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import PermissionFlow

/// Drives the welcome flow's in-window permissions step. Ports the grant logic
/// from `PermissionsWindowController` — preflight probing on a 0.5s timer, the
/// floating PermissionFlow helper, grant auto-chaining, telemetry, and the
/// hotkey-start / relaunch fallback — but exposes it as observable state for
/// SwiftUI (`WelcomePermissionsView`) instead of owning an AppKit window.
///
/// First-run only. The separate `PermissionsWindowController` still backs the
/// Settings/menu "Permissions" entry points and the onboarded-but-revoked path.
@MainActor
final class PermissionsModel: ObservableObject {
    /// Live granted status per permission. Published so the checklist flips to
    /// "Granted" as the user toggles each one in System Settings.
    @Published private(set) var granted: [WelcomePermissionKind: Bool] = [:]
    /// Relaunch sub-state: the in-process hotkey start failed after the grants
    /// landed, so the view swaps to "Relaunch Blink".
    @Published private(set) var needsRelaunch: Bool = false
    /// "Launch Blink at login" intent. Default-on; applied (registered) when the
    /// user commits via Get Started, so abandoners don't leave a login item.
    @Published var launchAtLogin: Bool = true

    var allGranted: Bool {
        WelcomePermissionKind.allCases.allSatisfy { granted[$0] ?? false }
    }

    // MARK: Dependencies

    private let eventClient: BlinkEventClient?
    private let allowLogging: () -> Bool
    private let clientMetadata: () -> [String: Any]
    private let attemptHotkeyStart: () -> Bool
    /// Fired once, on a successful grant + hotkey start. The window controller
    /// uses it to close the welcome window and hand off to the demo card.
    private let onComplete: () -> Void

    // MARK: State

    private var refreshTimer: Timer?
    private var shownAt: Date?
    private var didShow = false
    private var didComplete = false
    private var inRelaunchFallback = false
    /// Set once the user clicks Get Started, so a second click during the
    /// hotkey-start retry window can't re-enter `finish()`.
    private var isCommitting = false
    private var lastSnapshot: [WelcomePermissionKind: Bool] = [:]
    private var grantMS: [WelcomePermissionKind: Int] = [:]
    private var autoChainWorkItem: DispatchWorkItem?
    private var hotkeyStartRetryWorkItem: DispatchWorkItem?

    /// Owns System Settings navigation and the floating drag-to-authorize
    /// panel. Same configuration as the AppKit wizard.
    private lazy var controller: PermissionFlowController = {
        PermissionFlow.makeController(
            configuration: .init(
                requiredAppURLs: [Bundle.main.bundleURL],
                promptForAccessibilityTrust: false
            )
        )
    }()

    init(
        eventClient: BlinkEventClient?,
        allowLogging: @escaping () -> Bool,
        clientMetadata: @escaping () -> [String: Any],
        attemptHotkeyStart: @escaping () -> Bool,
        onComplete: @escaping () -> Void
    ) {
        self.eventClient = eventClient
        self.allowLogging = allowLogging
        self.clientMetadata = clientMetadata
        self.attemptHotkeyStart = attemptHotkeyStart
        self.onComplete = onComplete
    }

    // MARK: Lifecycle (called by WelcomePreview as the step enters/leaves)

    /// Enter the permissions step: seed status on first show, fire
    /// `onboarding_shown` once, and begin polling. Idempotent — re-entering
    /// (after Back) restarts the timer and picks up any grants made while
    /// paused, without reseeding the baseline (so `permission_granted` and
    /// `grants_ms` still fire for those).
    func start() {
        guard refreshTimer == nil, !didComplete, !inRelaunchFallback else { return }
        if !didShow {
            didShow = true
            shownAt = Date()
            // Default-on, but respect a prior explicit opt-out on re-onboarding.
            launchAtLogin = LoginItem.onboardingDefault
            let snap = snapshot()
            lastSnapshot = snap
            granted = snap
            // Seed grant timestamps for already-granted perms so `grants_ms`
            // is complete in `onboarding_completed`.
            for (kind, isGranted) in snap where isGranted { grantMS[kind] = 0 }
            // Persist that onboarding reached this step, so a mid-grant relaunch
            // (e.g. macOS "Quit & Reopen" after Screen Recording) resumes here
            // instead of replaying the landing + tour.
            Paths.markReachedOnboardingPermissions()
            emit("onboarding_shown", details: [
                "initial_granted": snap.filter { $0.value }.map { $0.key.rawValue },
            ])
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Catch up immediately against the preserved baseline so a grant made
        // while the timer was paused (Back excursion) still registers.
        refresh()
    }

    /// Leave the step without finishing (Back). Stop polling and dismiss the
    /// floating helper; keep accumulated state so re-entry resumes cleanly.
    func pause() {
        invalidateTimers()
        controller.closePanel()
    }

    /// The welcome window closed. Tear everything down and, if the user never
    /// finished, record an abandon.
    func handleWindowClosed() {
        invalidateTimers()
        controller.closePanel()
        if didShow && !didComplete {
            emit("onboarding_abandoned", details: [
                "granted": lastSnapshot.filter { $0.value }.map { $0.key.rawValue },
            ])
        }
    }

    // MARK: User actions

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin = enabled
        emit("onboarding_launch_at_login_toggled", details: ["enabled": enabled])
    }

    func openSettings(for kind: WelcomePermissionKind) {
        emit("onboarding_open_settings_clicked", details: ["permission": kind.rawValue])
        // Pass nil source frame: drop the button→Settings fly-in for the
        // in-window flow (avoids SwiftUI→screen-coordinate conversion). The
        // floating helper still appears.
        controller.authorize(
            pane: Self.pane(for: kind),
            suggestedAppURLs: [Bundle.main.bundleURL],
            sourceFrameInScreen: nil
        )
    }

    /// "Get Started" CTA. Commits onboarding and attempts to start the hotkey
    /// listener in-process; on failure, retries once then falls back to a
    /// relaunch sub-state.
    func finish() {
        guard !didComplete, !inRelaunchFallback, !isCommitting else { return }
        isCommitting = true
        emit("onboarding_get_started_clicked", details: [:])
        autoChainWorkItem?.cancel()
        autoChainWorkItem = nil
        // Commit the moment the user clicks Get Started; granting alone (no
        // click) shouldn't count as onboarded.
        markOnboardedOnce()
        // Apply the launch-at-login choice now that the user has committed.
        LoginItem.setEnabled(launchAtLogin)
        if attemptHotkeyStart() {
            completeSuccess()
            return
        }
        TCCDiagnostics.log("hotkeys_start_after_onboarding first_attempt_failed=true")
        let retry = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.attemptHotkeyStart() {
                    TCCDiagnostics.log("hotkeys_start_after_onboarding retry_succeeded=true")
                    self.completeSuccess()
                } else {
                    TCCDiagnostics.log("hotkeys_start_after_onboarding retry_failed=true")
                    self.enterRelaunchFallback()
                }
            }
        }
        hotkeyStartRetryWorkItem = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: retry)
    }

    /// "Relaunch Blink" CTA (relaunch fallback only).
    func relaunch() {
        guard !didComplete else { return }
        didComplete = true
        emitCompleted(relaunchRequired: true)
        markOnboardedOnce()
        controller.closePanel()
        relaunchSelf()
    }

    // MARK: Internal

    private func completeSuccess() {
        guard !didComplete else { return }
        didComplete = true
        emitCompleted(relaunchRequired: false)
        invalidateTimers()
        controller.closePanel()
        onComplete()
    }

    private func enterRelaunchFallback() {
        guard !inRelaunchFallback, !didComplete else { return }
        inRelaunchFallback = true
        invalidateTimers()
        controller.closePanel()
        needsRelaunch = true
    }

    private func refresh() {
        let snap = snapshot()
        var newlyGranted: WelcomePermissionKind?
        for kind in WelcomePermissionKind.allCases {
            let was = lastSnapshot[kind] ?? false
            let now = snap[kind] ?? false
            guard was != now else { continue }
            if now {
                let elapsed = Int(Date().timeIntervalSince(shownAt ?? Date()) * 1000)
                grantMS[kind] = elapsed
                emit("permission_granted", details: [
                    "permission": kind.rawValue,
                    "ms_since_shown": elapsed,
                ])
                if newlyGranted == nil { newlyGranted = kind }
            }
        }
        lastSnapshot = snap
        granted = snap

        let all = WelcomePermissionKind.allCases.allSatisfy { snap[$0] ?? false }
        // Auto-chain: after one grant, queue the next ungranted pane so System
        // Settings hops to it without another click. The short delay lets the
        // green flip register before the helper repositions.
        if let just = newlyGranted, !all, !inRelaunchFallback {
            scheduleAutoChainAfter(just)
        }
    }

    private func scheduleAutoChainAfter(_ justGranted: WelcomePermissionKind) {
        autoChainWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.autoChainAfter(justGranted) }
        }
        autoChainWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func autoChainAfter(_ justGranted: WelcomePermissionKind) {
        autoChainWorkItem = nil
        guard !inRelaunchFallback, !didComplete else { return }
        // Next ungranted row after the one just dealt with, wrapping to the
        // top so out-of-order grants don't dead-end on the last row.
        let order = WelcomePermissionsView.order
        guard let pivot = order.firstIndex(of: justGranted) else { return }
        let rotated = Array(order[(pivot + 1)...]) + Array(order[..<pivot])
        guard let next = rotated.first(where: { (lastSnapshot[$0] ?? false) == false }) else {
            return
        }
        emit("onboarding_auto_chain", details: ["permission": next.rawValue])
        controller.authorize(
            pane: Self.pane(for: next),
            suggestedAppURLs: [Bundle.main.bundleURL],
            sourceFrameInScreen: nil
        )
    }

    private func invalidateTimers() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        autoChainWorkItem?.cancel()
        autoChainWorkItem = nil
        hotkeyStartRetryWorkItem?.cancel()
        hotkeyStartRetryWorkItem = nil
    }

    private func markOnboardedOnce() {
        Paths.markOnboarded()
        // Onboarding is committed; the resume-at-permissions marker has served
        // its purpose, so a future reset starts cleanly at the landing.
        Paths.clearReachedOnboardingPermissions()
    }

    private func emitCompleted(relaunchRequired: Bool) {
        let duration = Int(Date().timeIntervalSince(shownAt ?? Date()) * 1000)
        let grants = Dictionary(uniqueKeysWithValues: grantMS.map { ($0.key.rawValue, $0.value) })
        emit("onboarding_completed", details: [
            "relaunch_required": relaunchRequired,
            "duration_ms": duration,
            "grants_ms": grants,
            "launch_at_login": launchAtLogin,
        ])
    }

    private func relaunchSelf() {
        let bundleURL = Bundle.main.bundleURL
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [bundleURL.path]
            do {
                try process.run()
            } catch {
                NSLog("Blink: relaunch failed: %@", error.localizedDescription)
            }
            NSApp.terminate(nil)
        }
    }

    private func snapshot() -> [WelcomePermissionKind: Bool] {
        var snap: [WelcomePermissionKind: Bool] = [:]
        for kind in WelcomePermissionKind.allCases {
            snap[kind] = Self.isGranted(kind)
        }
        return snap
    }

    private func emit(_ type: String, details: [String: Any]) {
        eventClient?.send(
            requestID: "onboarding-\(Paths.loadOrCreateInstallID())",
            eventType: type,
            allowLogging: allowLogging(),
            clientMetadata: clientMetadata(),
            details: details
        )
    }

    // MARK: Probes / mapping

    static func isGranted(_ kind: WelcomePermissionKind) -> Bool {
        switch kind {
        case .accessibility: return AXIsProcessTrusted()
        case .inputMonitoring: return HotkeyManager.inputMonitoringGranted()
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        }
    }

    private static func pane(for kind: WelcomePermissionKind) -> PermissionFlowPane {
        switch kind {
        case .accessibility: return .accessibility
        case .inputMonitoring: return .inputMonitoring
        case .screenRecording: return .screenRecording
        }
    }
}
