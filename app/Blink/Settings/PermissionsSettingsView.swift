import SwiftUI

@available(macOS 14.0, *)
struct PermissionsSettingsView: View {
    let onShowPermissions: () -> Void
    let onResetPermissions: () -> Void

    @State private var snapshot: PermissionsSnapshot = PermissionsActions.currentSnapshot()

    var body: some View {
        Form {
            Section {
                Text("Blink relies on three macOS permissions. Re-run setup if a row says \"Not granted\".")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Status") {
                permissionRow(title: "Accessibility", granted: snapshot.accessibility)
                permissionRow(title: "Input Monitoring", granted: snapshot.inputMonitoring)
                permissionRow(title: "Screen Recording", granted: snapshot.screenRecording)
            }

            Section {
                HStack(spacing: 8) {
                    Button("Re-run setup…") { onShowPermissions() }
                        .help("Open the first-run permission wizard.")
                    Button("Reset Permissions…") { onResetPermissions() }
                        .help("Clear every TCC grant for Blink (requires relaunch).")
                    Spacer()
                }
                .controlSize(.regular)
            }
        }
        .formStyle(.grouped)
        // `.task` auto-cancels when the view disappears, so the polling
        // loop stops as soon as the user swaps panes or closes the window —
        // no zombie timer keeping the snapshot fresh on a hidden pane.
        .task {
            while !Task.isCancelled {
                snapshot = PermissionsActions.currentSnapshot()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    @ViewBuilder
    private func permissionRow(title: String, granted: Bool) -> some View {
        LabeledContent(title) {
            Text(granted ? "Granted" : "Not granted")
                .font(.callout.weight(.semibold))
                .foregroundStyle(granted ? .green : .secondary)
        }
    }
}
