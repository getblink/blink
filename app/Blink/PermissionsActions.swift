import AppKit
import ApplicationServices

/// Snapshot of the three permission states the app cares about, exposed
/// so non-onboarding surfaces (the Settings ▸ Permissions pane, the
/// menubar) can read the same probes the wizard uses.
struct PermissionsSnapshot {
    let accessibility: Bool
    let inputMonitoring: Bool
    let screenRecording: Bool

    var allGranted: Bool { accessibility && inputMonitoring && screenRecording }
}

@MainActor
enum PermissionsActions {
    static func currentSnapshot() -> PermissionsSnapshot {
        PermissionsSnapshot(
            accessibility: AXIsProcessTrusted(),
            inputMonitoring: HotkeyManager.inputMonitoringGranted(),
            screenRecording: CGPreflightScreenCaptureAccess()
        )
    }

    /// Mirror of `app/scripts/reset_tcc.sh` — clears every TCC service
    /// the app touches so the next launch re-triggers the system prompts.
    /// In-process resets don't apply to the currently-running process, so
    /// we offer to quit on success.
    static func resetPermissions() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.henryz2004.blink"

        let confirm = NSAlert()
        confirm.messageText = "Reset Blink permissions?"
        confirm.informativeText = """
            This clears Accessibility, Screen Recording, Input Monitoring, \
            and related grants for \(bundleID). You'll be re-prompted on \
            next launch. Blink should be quit and relaunched for the reset \
            to take effect.
            """
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Reset")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let services = [
            "Accessibility",
            "ListenEvent",
            "PostEvent",
            "ScreenCapture",
            "SystemPolicyAllFiles",
            "AppleEvents",
        ]
        var failures: [String] = []
        for service in services {
            let proc = Process()
            proc.launchPath = "/usr/bin/tccutil"
            proc.arguments = ["reset", service, bundleID]
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            do {
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus != 0 {
                    failures.append(service)
                }
            } catch {
                failures.append(service)
            }
        }

        let result = NSAlert()
        if failures.isEmpty {
            result.messageText = "Permissions reset"
            result.informativeText = "Quit Blink now and relaunch to re-grant permissions."
            result.alertStyle = .informational
        } else {
            result.messageText = "Reset finished with errors"
            result.informativeText = "tccutil failed for: \(failures.joined(separator: ", "))."
            result.alertStyle = .warning
        }
        result.addButton(withTitle: "Quit Blink")
        result.addButton(withTitle: "Later")
        if result.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
    }
}
