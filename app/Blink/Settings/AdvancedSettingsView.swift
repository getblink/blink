import SwiftUI

@available(macOS 14.0, *)
struct AdvancedSettingsView: View {
    let onOpenRuns: () -> Void
    let onOpenRuntime: () -> Void
    let onCheckForUpdates: (() -> Void)?

    var body: some View {
        Form {
            Section("Files") {
                HStack(spacing: 8) {
                    Button("Open runs folder") { onOpenRuns() }
                        .help("Recent capture bundles (screenshots, prompts, responses).")
                    Button("Open ~/.blink") { onOpenRuntime() }
                        .help("Local config, prompts, runtime state.")
                    Spacer()
                }
            }

            if let onCheckForUpdates {
                Section("Updates") {
                    HStack {
                        Button("Check for Updates…") { onCheckForUpdates() }
                        Spacer()
                    }
                }
            }

            Section {
                Text("Summaries and suggestions are stored to improve Blink; screenshots are not retained.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}
