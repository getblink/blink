import SwiftUI

/// Specification for one Style knob: which `StylePrefs` field it edits and how
/// the three segments are labelled / valued. Mirrors `StylePaneController.KnobSpec`
/// from the prior AppKit version, but lifted to a top-level constant so the
/// SwiftUI view can iterate over it directly.
struct StyleKnobSpec: Identifiable {
    enum Field {
        case initiative, tone, length, directness, voiceMirror
    }

    let id: String
    let field: Field
    let label: String
    let leftTitle: String
    let leftValue: String
    let rightTitle: String
    let rightValue: String
    let hint: String
}

let styleKnobs: [StyleKnobSpec] = [
    StyleKnobSpec(
        id: "initiative",
        field: .initiative,
        label: "Initiative",
        leftTitle: "Incremental", leftValue: "incremental",
        rightTitle: "Agentic", rightValue: "agentic",
        hint: "Small nudges vs full drafts."
    ),
    StyleKnobSpec(
        id: "tone",
        field: .tone,
        label: "Tone",
        leftTitle: "Casual", leftValue: "casual",
        rightTitle: "Formal", rightValue: "formal",
        hint: "Contractions vs polished register."
    ),
    StyleKnobSpec(
        id: "length",
        field: .length,
        label: "Length",
        leftTitle: "Terse", leftValue: "terse",
        rightTitle: "Thorough", rightValue: "thorough",
        hint: "One-liners vs a few sentences."
    ),
    StyleKnobSpec(
        id: "directness",
        field: .directness,
        label: "Directness",
        leftTitle: "Diplomatic", leftValue: "diplomatic",
        rightTitle: "Direct", rightValue: "direct",
        hint: "Hedge vs name the real issue."
    ),
    StyleKnobSpec(
        id: "voiceMirror",
        field: .voiceMirror,
        label: "Voice mirror",
        leftTitle: "Neutral", leftValue: "neutral",
        rightTitle: "Mirror me", rightValue: "mirror",
        hint: "Clean register vs imitate my voice samples."
    ),
]

@available(macOS 14.0, *)
struct StyleSettingsView: View {
    @ObservedObject var runtimeStore: RuntimeConfigStore

    var body: some View {
        Form {
            Section {
                Text("Tweak how Blink writes for you. Defaults are balanced; changes apply to the next summary.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Voice knobs") {
                ForEach(styleKnobs) { spec in
                    knobRow(spec)
                }
            }

            Section("About me") {
                aboutMeSection
            }

            Section {
                presetRow
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Knob row

    @ViewBuilder
    private func knobRow(_ spec: StyleKnobSpec) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(spec.label)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(spec.hint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            SegmentedKnob(
                selection: knobBinding(spec),
                segments: [
                    .init(title: spec.leftTitle,  value: spec.leftValue),
                    .init(title: "Balanced",      value: "balanced"),
                    .init(title: spec.rightTitle, value: spec.rightValue),
                ]
            )
            .frame(width: 360)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .help(spec.hint)
    }

    // MARK: - About me

    @ViewBuilder
    private var aboutMeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Anything Blink should always know: name, role, recurring context.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            AboutMeTextEditor(text: aboutMeBinding, maxChars: StylePrefs.aboutMeMaxChars)
                .frame(minHeight: 100, idealHeight: 110, maxHeight: 160)
            HStack {
                Spacer()
                let counter = Text("\(aboutMeCount) / \(StylePrefs.aboutMeMaxChars)")
                    .font(.caption2)
                    .monospacedDigit()
                if aboutMeCount > StylePrefs.aboutMeMaxChars {
                    counter.foregroundStyle(Color.orange)
                } else {
                    counter.foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var aboutMeCount: Int {
        runtimeStore.style.aboutMe.unicodeScalars.count
    }

    // MARK: - Preset row

    @ViewBuilder
    private var presetRow: some View {
        HStack(spacing: 8) {
            Button("Default") { applyDefaultPreset() }
                .help("Reset all knobs to balanced defaults.")
            Button("Professional") { applyProfessionalPreset() }
                .help("Formal tone preset.")
            Button("Bold") { applyBoldPreset() }
                .help("Agentic, direct, terse preset.")
            Spacer()
            Button("Reset") { resetPreservingAboutMe() }
                .help("Restore knobs without clearing About me.")
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
    }

    // MARK: - Bindings

    private func knobBinding(_ spec: StyleKnobSpec) -> Binding<String> {
        Binding(
            get: { value(for: spec.field) },
            set: { newValue in
                var style = runtimeStore.style
                set(field: spec.field, to: newValue, on: &style)
                runtimeStore.style = style
            }
        )
    }

    private var aboutMeBinding: Binding<String> {
        Binding(
            get: { runtimeStore.style.aboutMe },
            set: { newValue in
                var style = runtimeStore.style
                if style.aboutMe != newValue {
                    style.aboutMe = newValue
                    runtimeStore.style = style
                }
            }
        )
    }

    private func value(for field: StyleKnobSpec.Field) -> String {
        let style = runtimeStore.style
        switch field {
        case .initiative: return style.initiative
        case .tone: return style.tone
        case .length: return style.length
        case .directness: return style.directness
        case .voiceMirror: return style.voiceMirror
        }
    }

    private func set(field: StyleKnobSpec.Field, to value: String, on style: inout StylePrefs) {
        switch field {
        case .initiative: style.initiative = value
        case .tone: style.tone = value
        case .length: style.length = value
        case .directness: style.directness = value
        case .voiceMirror: style.voiceMirror = value
        }
    }

    // MARK: - Presets

    private func applyDefaultPreset() {
        runtimeStore.style = .default
    }

    private func applyProfessionalPreset() {
        var style = runtimeStore.style
        style.initiative = "balanced"
        style.tone = "formal"
        style.length = "balanced"
        style.directness = "balanced"
        style.voiceMirror = "balanced"
        runtimeStore.style = style
    }

    private func applyBoldPreset() {
        var style = runtimeStore.style
        style.initiative = "agentic"
        style.tone = "casual"
        style.length = "terse"
        style.directness = "direct"
        style.voiceMirror = "mirror"
        runtimeStore.style = style
    }

    private func resetPreservingAboutMe() {
        var style = StylePrefs.default
        // About me is typed prose, not a knob — preserve across reset.
        style.aboutMe = runtimeStore.style.aboutMe
        runtimeStore.style = style
    }
}
