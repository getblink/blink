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

            // The Liquid Glass capture-loading lens is env-gated (BLINK_GLASS_LOADING),
            // so only surface its speed control when that path is actually active —
            // otherwise the slider would tune an animation the user never sees.
            if RuntimeEnvironment.glassLoadingEnabled() {
                Section("Loading animation") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Speed")
                            Spacer()
                            Text(String(format: "%g×", runtimeStore.lensAnimationSpeed))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: $runtimeStore.lensAnimationSpeed,
                            in: RuntimeConfigStore.lensAnimationSpeedRange,
                            step: 0.25
                        ) {
                            Text("Loading animation speed")
                        } minimumValueLabel: {
                            Text("Slower").font(.caption2).foregroundStyle(.tertiary)
                        } maximumValueLabel: {
                            Text("Faster").font(.caption2).foregroundStyle(.tertiary)
                        }
                        Text("Pace of the Liquid Glass capture-loading animation (drain → pill → smile). Applies on the next capture.")
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
