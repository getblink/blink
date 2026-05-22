import SwiftUI

/// `Settings ▸ General` body. Hosted inside the AppKit `SettingsWindowController`
/// shell via `NSHostingView`, so the toolbar/window chrome stays AppKit while
/// the form layout uses SwiftUI's `Form { Section { LabeledContent } }` rhythm.
@available(macOS 14.0, *)
struct GeneralSettingsView: View {
    @ObservedObject var runtimeStore: RuntimeConfigStore
    let hotkeyDisplay: String

    var body: some View {
        Form {
            Section("Model") {
                LabeledContent("Model") {
                    Picker("Model", selection: $runtimeStore.model) {
                        ForEach(ModelChoices.optionsIncluding(current: runtimeStore.model), id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                }
                .help("Backend model used for summaries and replies.")

                LabeledContent("Reasoning") {
                    Picker("Reasoning", selection: reasoningTitleBinding) {
                        ForEach(ReasoningLevels.titles, id: \.self) { title in
                            Text(title).tag(title)
                        }
                    }
                    .labelsHidden()
                }
                .help("How much the model thinks before answering. Higher = slower, more careful.")
            }

            Section("Behavior") {
                Toggle("Play sounds", isOn: $runtimeStore.soundsEnabled)
                    .help("Subtle audio cues when a summary is ready or fails.")
                Toggle("Show nudges", isOn: $runtimeStore.nudgesEnabled)
                    .help("Briefly remind you to use Blink when you're shuttling between apps.")
            }

            Section("Hotkey") {
                LabeledContent("Hotkey") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(hotkeyDisplay)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.primary)
                        Text("Press anywhere to summarize the focused window.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// `runtimeStore.thinkingLevel` is `String?` ("off" / "low" / "medium" / "high" / nil).
    /// The picker works in human-readable titles ("Default" / "Off" / "Low" / "Medium" / "High");
    /// translate at the binding boundary. "Off" disables Gemini's thinking budget
    /// (server maps it to `thinking_budget=0`) for the fastest path; "Default" lets
    /// the server pick the per-model default (currently `low` for Gemini 3.x).
    private var reasoningTitleBinding: Binding<String> {
        Binding(
            get: { ReasoningLevels.title(for: runtimeStore.thinkingLevel) },
            set: { runtimeStore.thinkingLevel = ReasoningLevels.value(for: $0) }
        )
    }
}
