import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` for the "Launch Blink at login"
/// preference. The system service status is the single source of truth — we
/// never cache it — so the onboarding checkbox and the menu toggle always agree.
///
/// `register()` can fail on unsigned dev builds, or when the user has turned the
/// item off in System Settings › General › Login Items (status
/// `.requiresApproval`); in those cases we log and leave the prior state rather
/// than fighting the user's choice.
enum LoginItem {
    /// Whether Blink is currently registered to launch at login.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// The default for the onboarding checkbox: on for a clean slate, but
    /// reflect an existing choice so re-onboarding (after a reset) doesn't
    /// silently override an explicit opt-out — notably `.requiresApproval`,
    /// which means the user turned it off in System Settings › Login Items.
    static var onboardingDefault: Bool {
        switch SMAppService.mainApp.status {
        case .enabled: return true
        case .requiresApproval: return false
        default: return true  // .notRegistered / .notFound → clean slate, default on
        }
    }

    /// Register or unregister the login item. Returns the resulting state.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else if service.status == .enabled {
                try service.unregister()
            }
        } catch {
            NSLog(
                "Blink: launch-at-login %@ failed: %@",
                enabled ? "register" : "unregister",
                error.localizedDescription
            )
        }
        return isEnabled
    }
}
