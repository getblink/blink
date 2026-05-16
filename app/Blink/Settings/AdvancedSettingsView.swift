import SwiftUI

@available(macOS 14.0, *)
struct AdvancedSettingsView: View {
    @ObservedObject var runtimeStore: RuntimeConfigStore
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

            Section("Capture") {
                Toggle(isOn: $runtimeStore.annotateScreenshots) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Annotate screenshots with focus markers")
                        Text("Adds a subtle outline around the focused element and small markers at the caret and mouse pointer. macOS screen capture omits both natively.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
