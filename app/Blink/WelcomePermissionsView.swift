import SwiftUI

/// The brand blue used across the welcome flow (matches the cursor accent in
/// `WelcomeCanvasView`). Defined here — a file the preview harness also
/// compiles — so both the landing hero and the permissions CTA can share it.
extension Color {
    static let blinkAccent = Color(red: 0.36, green: 0.45, blue: 0.85)
}

/// The three macOS permissions Blink needs to run its loop. A pure-UI enum
/// with no `PermissionFlow` dependency, so the SwiftUI permissions step renders
/// in the preview harness; `PermissionsModel` maps these onto `PermissionFlowPane`.
enum WelcomePermissionKind: String, CaseIterable, Identifiable {
    case screenRecording
    case accessibility
    case inputMonitoring

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .screenRecording: return "macwindow"
        case .accessibility: return "accessibility"
        case .inputMonitoring: return "keyboard"
        }
    }

    var name: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        }
    }

    var detail: String {
        switch self {
        case .screenRecording: return "Sees the window to summarize it"
        case .accessibility: return "Reads the field and types your reply"
        case .inputMonitoring: return "Listens for your hotkey"
        }
    }
}

/// The middle content for the welcome flow's permissions step: a grouped
/// checklist of the three required permissions, each anchored by an icon chip
/// with a single trailing control that flips from "Open Settings" to a green
/// "Granted" once the user grants it. A "Get Started" CTA lights up when all
/// three are in. If the post-grant hotkey start fails, it swaps to a "Relaunch
/// Blink" sub-state.
///
/// Intentionally model-free — it takes plain granted flags and callbacks so the
/// preview harness (and Xcode canvas) can render it with a forced status.
/// `PermissionsModel` owns the live probing, telemetry, auto-chain, and relaunch
/// logic and feeds this view.
struct WelcomePermissionsView: View {
    /// Granted status per permission. Missing keys read as not granted.
    let granted: [WelcomePermissionKind: Bool]
    let allGranted: Bool
    /// Relaunch sub-state: the in-process hotkey start failed after the grants
    /// landed, so Blink needs a relaunch before it can listen.
    let needsRelaunch: Bool
    /// "Launch Blink at login" preference (default-on).
    let launchAtLogin: Bool
    let onOpenSettings: (WelcomePermissionKind) -> Void
    let onSetLaunchAtLogin: (Bool) -> Void
    let onGetStarted: () -> Void
    let onRelaunch: () -> Void

    /// Fixed display order — also the order the model auto-chains through.
    static let order: [WelcomePermissionKind] = [
        .screenRecording, .accessibility, .inputMonitoring,
    ]

    /// Keeps the trailing control's footprint constant so the row doesn't
    /// reflow when "Open Settings" flips to "Granted".
    private static let trailingWidth: CGFloat = 106
    /// Fixed-width left icon column so names/dividers align.
    private static let iconColumnWidth: CGFloat = 24

    var body: some View {
        if needsRelaunch {
            relaunchBody
        } else {
            checklistBody
        }
    }

    private var checklistBody: some View {
        VStack(spacing: 18) {
            rowsCard
            Toggle(isOn: Binding(get: { launchAtLogin }, set: onSetLaunchAtLogin)) {
                Text("Launch Blink at login")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            Button(action: onGetStarted) {
                Text("Get Started")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(minWidth: 120)
                    .padding(.vertical, 4)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.blinkAccent)
            .disabled(!allGranted)
        }
        // Centered in the (canvas-height) middle slot. The card is now tall
        // enough to nearly fill it, so centering keeps the margins balanced —
        // top-pinning instead left a void at the bottom that pulled the whole
        // stack up and squeezed the header's top padding.
        .frame(maxWidth: .infinity)
    }

    private var rowsCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(Self.order.enumerated()), id: \.element) { index, kind in
                if index > 0 {
                    // Inset under the text (past the icon column) — grouped-list style.
                    Divider().padding(.leading, 14 + Self.iconColumnWidth + 12)
                }
                permissionRow(kind)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.09), lineWidth: 0.5)
        )
        .frame(maxWidth: 460)
    }

    private func permissionRow(_ kind: WelcomePermissionKind) -> some View {
        let isGranted = granted[kind] ?? false
        return HStack(spacing: 12) {
            Image(systemName: kind.icon)
                .font(.system(size: 18))
                .foregroundColor(.secondary)
                .frame(width: Self.iconColumnWidth, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(kind.detail)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailingControl(kind, granted: isGranted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// One trailing control per row: an "Open Settings" button while ungranted,
    /// flipping to a green "Granted" badge once done. Fixed width so the flip
    /// doesn't shift the row.
    @ViewBuilder
    private func trailingControl(_ kind: WelcomePermissionKind, granted: Bool) -> some View {
        if granted {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                Text("Granted")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.green)
            .frame(width: Self.trailingWidth, alignment: .trailing)
        } else {
            HStack {
                Spacer(minLength: 0)
                Button("Open Settings") { onOpenSettings(kind) }
                    .controlSize(.small)
            }
            .frame(width: Self.trailingWidth)
        }
    }

    private var relaunchBody: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 40))
                .foregroundColor(.blinkAccent)
            Text("Blink needs a quick relaunch to start listening for your hotkey.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button(action: onRelaunch) {
                Text("Relaunch Blink")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(minWidth: 120)
                    .padding(.vertical, 4)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.blinkAccent)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview("Permissions — partial") {
    WelcomePermissionsView(
        granted: [.screenRecording: true],
        allGranted: false,
        needsRelaunch: false,
        launchAtLogin: true,
        onOpenSettings: { _ in },
        onSetLaunchAtLogin: { _ in },
        onGetStarted: {},
        onRelaunch: {}
    )
    .frame(width: 620, height: 360)
    .padding()
}

#Preview("Permissions — all granted") {
    WelcomePermissionsView(
        granted: [.screenRecording: true, .accessibility: true, .inputMonitoring: true],
        allGranted: true,
        needsRelaunch: false,
        launchAtLogin: true,
        onOpenSettings: { _ in },
        onSetLaunchAtLogin: { _ in },
        onGetStarted: {},
        onRelaunch: {}
    )
    .frame(width: 620, height: 360)
    .padding()
}
