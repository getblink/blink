import AppKit
import Foundation
import SwiftUI

struct RunBundleSummary: Identifiable {
    let id: String
    let url: URL
    let status: String
}

struct TextArtifact: Identifiable {
    let name: String
    let content: String
    let url: URL

    var id: String { name }
}

struct ImageArtifact: Identifiable {
    let name: String
    let url: URL

    var id: String { name }
}

struct RunBundleDetail {
    let summary: RunBundleSummary
    let bundleURL: URL
    let summaryLines: [String]
    let textArtifacts: [TextArtifact]
    let imageArtifacts: [ImageArtifact]
}

@MainActor
final class RunInspectorStore: ObservableObject {
    @Published var runs: [RunBundleSummary] = []
    @Published var selectedRunID: String? {
        didSet { loadSelectedRun() }
    }
    @Published var selectedTextArtifactName: String?
    @Published var selectedRunDetail: RunBundleDetail?

    init() {
        refresh()
    }

    var selectedTextArtifact: TextArtifact? {
        guard let name = selectedTextArtifactName else { return nil }
        return selectedRunDetail?.textArtifacts.first(where: { $0.name == name })
    }

    func refresh() {
        let fileManager = FileManager.default
        let bundleURLs = (try? fileManager.contentsOfDirectory(
            at: Paths.runsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let directories = bundleURLs.filter { url in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }.sorted { $0.lastPathComponent > $1.lastPathComponent }

        runs = directories.map { url in
            let status = Self.readStatus(bundleURL: url) ?? "unknown"
            return RunBundleSummary(id: url.lastPathComponent, url: url, status: status)
        }

        if runs.isEmpty {
            selectedRunID = nil
            selectedRunDetail = nil
            selectedTextArtifactName = nil
            return
        }

        if let selectedRunID,
           runs.contains(where: { $0.id == selectedRunID }) {
            loadSelectedRun()
        } else {
            selectedRunID = runs.first?.id
        }
    }

    func revealSelectedRun() {
        guard let detail = selectedRunDetail else { return }
        NSWorkspace.shared.activateFileViewerSelecting([detail.bundleURL])
    }

    private func loadSelectedRun() {
        guard let selectedRunID,
              let summary = runs.first(where: { $0.id == selectedRunID }) else {
            selectedRunDetail = nil
            selectedTextArtifactName = nil
            return
        }

        selectedRunDetail = Self.loadDetail(for: summary)
        if let current = selectedTextArtifactName,
           selectedRunDetail?.textArtifacts.contains(where: { $0.name == current }) == true {
            return
        }
        if summary.status != "ok",
           selectedRunDetail?.textArtifacts.contains(where: { $0.name == "stderr.log" }) == true {
            selectedTextArtifactName = "stderr.log"
            return
        }
        selectedTextArtifactName = selectedRunDetail?.textArtifacts.first?.name
    }

    private static func readStatus(bundleURL: URL) -> String? {
        guard let payload = readJSON(url: bundleURL.appendingPathComponent("run.json")) else { return nil }
        return payload["status"] as? String
    }

    private static func loadDetail(for summary: RunBundleSummary) -> RunBundleDetail {
        let fileManager = FileManager.default
        let contents: [URL] = (try? fileManager.contentsOfDirectory(
            at: summary.url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        let textArtifacts: [TextArtifact] = contents
            .filter { ["txt", "json", "log"].contains($0.pathExtension.lowercased()) }
            .sorted(by: artifactSortOrder)
            .compactMap { url in
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return TextArtifact(name: url.lastPathComponent, content: content, url: url)
            }

        let imageArtifacts: [ImageArtifact] = contents
            .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted(by: artifactSortOrder)
            .map { ImageArtifact(name: $0.lastPathComponent, url: $0) }

        let runJSON = readJSON(url: summary.url.appendingPathComponent("run.json")) ?? [:]
        let summaryLines = buildSummaryLines(summary: summary, runJSON: runJSON)

        return RunBundleDetail(
            summary: summary,
            bundleURL: summary.url,
            summaryLines: summaryLines,
            textArtifacts: textArtifacts,
            imageArtifacts: imageArtifacts
        )
    }

    private static func buildSummaryLines(
        summary: RunBundleSummary,
        runJSON: [String: Any]
    ) -> [String] {
        let runtime = nestedDictionary(in: runJSON, key: "runtime")
        let timings = nestedDictionary(in: runJSON, key: "timings")
        let request = nestedDictionary(in: runJSON, key: "request")
        let targetContext = nestedDictionary(in: runJSON, key: "target_context")

        var lines = [
            "Run: \(summary.id)",
            "Status: \((runJSON["status"] as? String) ?? summary.status)",
            "Mode: \((runtime["request_mode"] as? String) ?? "unknown")",
        ]

        let extractor = nestedDictionary(in: runtime, key: "extractor")
        let paste = nestedDictionary(in: runtime, key: "paste")
        if !extractor.isEmpty || !paste.isEmpty {
            if let model = extractor["model"] as? String {
                lines.append("Extractor: \(model) (\(extractor["provider_preset_id"] as? String ?? "?"))")
            }
            if let model = paste["model"] as? String {
                lines.append("Paste: \(model) (\(paste["provider_preset_id"] as? String ?? "?"))")
            }
        } else {
            lines.append("Provider: \((runtime["provider"] as? String) ?? "unknown")")
            lines.append("Model: \((runtime["model"] as? String) ?? "unknown")")
            if let providerPresetID = runtime["provider_preset_id"] as? String {
                lines.append("Preset: \(providerPresetID)")
            }
        }
        if let outputLength = nestedDictionary(in: runJSON, key: "response")["output_text_length"] {
            lines.append("Output chars: \(outputLength)")
        }
        if let endToEnd = formattedMS(timings["end_to_end_ms"]) {
            lines.append("Python end-to-end: \(endToEnd)")
        }
        if let ttft = formattedMS(timings["ttft_ms"]) {
            lines.append("TTFT: \(ttft)")
        }
        if let latency = formattedMS(timings["model_latency_ms"]) {
            lines.append("Model latency: \(latency)")
        }
        if let build = formattedMS(timings["request_build_ms"]) {
            lines.append("Request build: \(build)")
        }
        if let sourcePrep = formattedMS(timings["source_image_prepare_ms"]) {
            lines.append("Source image prep: \(sourcePrep)")
        }
        if let targetPrep = formattedMS(timings["target_image_prepare_ms"]) {
            lines.append("Target image prep: \(targetPrep)")
        }
        if let targetOCR = formattedMS(timings["target_ocr_ms"]) {
            lines.append("Target OCR: \(targetOCR)")
        }
        if let sourceCapture = formattedMS(timings["host_source_capture_ms"]) {
            lines.append("Host source capture: \(sourceCapture)")
        }
        if let sourceTextCapture = formattedMS(timings["host_source_text_capture_ms"]) {
            lines.append("Host source text: \(sourceTextCapture)")
        }
        if let sourcePacketPrep = formattedMS(timings["host_source_prepare_source_packet_ms"]) {
            lines.append("Host source packet prep: \(sourcePacketPrep)")
        }
        if let metadataCapture = formattedMS(timings["host_target_metadata_capture_ms"]) {
            lines.append("Host target metadata: \(metadataCapture)")
        }
        if let screenshotCapture = formattedMS(timings["host_target_screenshot_capture_ms"]) {
            lines.append("Host target screenshot: \(screenshotCapture)")
        }
        if let artifactPrep = formattedMS(timings["host_artifact_prep_ms"]) {
            lines.append("Host artifact prep: \(artifactPrep)")
        }
        if let prePython = formattedMS(timings["host_pre_python_ms"]) {
            lines.append("Host pre-Python: \(prePython)")
        }
        if let pythonWall = formattedMS(timings["host_python_wall_ms"]) {
            lines.append("Host Python wall: \(pythonWall)")
        }
        if let insert = formattedMS(timings["host_insert_ms"]) {
            lines.append("Host insert: \(insert)")
        }
        if let hostTotal = formattedMS(timings["host_run_target_total_ms"]) {
            lines.append("Host run-target total: \(hostTotal)")
        }
        if let mode = request["mode"] as? String {
            lines.append("Request mode: \(mode)")
        }
        if let targetMode = targetContext["mode"] as? String {
            lines.append("Target path: \(targetMode)")
        }
        if let fallbackReason = targetContext["fallback_reason"] as? String {
            lines.append("Fallback reason: \(fallbackReason)")
        }
        if let errors = runJSON["errors"] as? [String], !errors.isEmpty {
            lines.append("Errors:")
            lines.append(contentsOf: errors.prefix(3).map { "  \($0)" })
        }
        if let warnings = runJSON["warnings"] as? [String], !warnings.isEmpty {
            lines.append("Warnings:")
            lines.append(contentsOf: warnings.prefix(3).map { "  \($0)" })
        }
        return lines
    }

    private static func formattedMS(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let double = value as? Double {
            return String(format: "%.2f ms", double)
        }
        if let number = value as? NSNumber {
            return String(format: "%.2f ms", number.doubleValue)
        }
        return nil
    }

    private static func nestedDictionary(
        in payload: [String: Any],
        key: String
    ) -> [String: Any] {
        payload[key] as? [String: Any] ?? [:]
    }

    private static func readJSON(url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func artifactSortOrder(lhs: URL, rhs: URL) -> Bool {
        func priority(for name: String) -> Int {
            switch name {
            case "output.txt": return 0
            case "generation.request.txt": return 1
            case "generation.prompt.txt": return 2
            case "target_metadata.prompt.json": return 3
            case "source_packet.txt": return 4
            case "source_text.json": return 5
            case "target_ocr_packet.txt": return 6
            case "target_ocr_text.txt": return 7
            case "run.json": return 8
            case "host_profile.json": return 9
            case "stderr.log": return 10
            case "source.png": return 11
            case "target.png": return 12
            default: return 20
            }
        }

        let leftPriority = priority(for: lhs.lastPathComponent)
        let rightPriority = priority(for: rhs.lastPathComponent)
        if leftPriority == rightPriority {
            return lhs.lastPathComponent < rhs.lastPathComponent
        }
        return leftPriority < rightPriority
    }
}

@MainActor
final class ControlCenterWindowController {
    private let runtimeStore: RuntimeConfigStore
    private let runStore: RunInspectorStore
    private var window: NSWindow?

    init(runtimeStore: RuntimeConfigStore, runStore: RunInspectorStore) {
        self.runtimeStore = runtimeStore
        self.runStore = runStore
    }

    func show() {
        if window == nil {
            let rootView = ControlCenterRootView(runtimeStore: runtimeStore, runStore: runStore)
            let hosting = NSHostingController(rootView: rootView)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Blink Control Center"
            window.setContentSize(NSSize(width: 1220, height: 860))
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            self.window = window
        }

        runtimeStore.refreshFromDisk()
        runStore.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct ControlCenterRootView: View {
    @ObservedObject var runtimeStore: RuntimeConfigStore
    @ObservedObject var runStore: RunInspectorStore

    var body: some View {
        TabView {
            RuntimeControlsView(runtimeStore: runtimeStore, runStore: runStore)
                .tabItem { Text("Runtime") }
            RunInspectorView(runStore: runStore)
                .tabItem { Text("Runs") }
        }
        .padding(12)
        .frame(minWidth: 1100, minHeight: 780)
    }
}

private struct RuntimeControlsView: View {
    @ObservedObject var runtimeStore: RuntimeConfigStore
    @ObservedObject var runStore: RunInspectorStore

    var body: some View {
        Form {
            Section("Source packet extractor") {
                ProviderModelRow(
                    selection: $runtimeStore.extractor,
                    suggestedModels: runtimeStore.suggestedModels(for: runtimeStore.extractor),
                    presets: runtimeStore.providerPresets,
                    warningText: extractorVisionWarning
                )
                Text("Used to extract a text packet from the source screenshot — needs to handle images.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Paste-time model") {
                ProviderModelRow(
                    selection: $runtimeStore.paste,
                    suggestedModels: runtimeStore.suggestedModels(for: runtimeStore.paste),
                    presets: runtimeStore.providerPresets,
                    warningText: nil
                )
                Text("Used at paste time to produce the final text — pick a low-latency provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Request Mode") {
                Picker("Request Mode", selection: $runtimeStore.requestMode) {
                    ForEach(RequestMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text(runtimeStore.requestMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Artifacts") {
                HStack {
                    Button("Open ~/.blink") {
                        NSWorkspace.shared.open(Paths.runtimeDir)
                    }
                    Button("Open Runs Folder") {
                        NSWorkspace.shared.open(Paths.runsDir)
                    }
                    Button("Refresh Runs") {
                        runStore.refresh()
                    }
                }

                if let settingsPath = Paths.settingsPath {
                    LabeledContent("Settings Path") {
                        Text(settingsPath.path)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(2)
                    }
                }

                ForEach(runtimeStore.promptDescriptors) { descriptor in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(descriptor.label)
                            Spacer()
                            Text(descriptor.sourceDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(descriptor.path.path)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Notes") {
                Text("Credentials are loaded by the Python runtime from `~/.blink/.env` and `~/.blink/.env.local` when present.")
                Text("Prompt overrides are picked up automatically from `~/.blink/prompts/<filename>` when a matching file exists.")
            }
        }
        .formStyle(.grouped)
    }

    private var extractorVisionWarning: String? {
        guard runtimeStore.requestMode.requiresVisionInExtractor else { return nil }
        let preset = runtimeStore.extractorPreset()
        let model = runtimeStore.extractor.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = model.isEmpty ? preset.defaultModel : model
        guard !preset.supportsVision(model: resolvedModel) else { return nil }
        return "This model is text-only and will fail at source-packet extraction. Pick a vision-capable model for the extractor row."
    }
}

private struct RunInspectorView: View {
    @ObservedObject var runStore: RunInspectorStore

    var body: some View {
        HStack(spacing: 16) {
            List(runStore.runs, selection: $runStore.selectedRunID) { run in
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.id)
                        .font(.system(.body, design: .monospaced))
                    Text(run.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 300, maxWidth: 340)

            if let detail = runStore.selectedRunDetail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Button("Reveal Bundle") { runStore.revealSelectedRun() }
                            Button("Refresh") { runStore.refresh() }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(detail.summaryLines, id: \.self) { line in
                                Text(line)
                                    .font(.system(.body, design: .monospaced))
                            }
                        }

                        if !detail.imageArtifacts.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Images")
                                    .font(.headline)
                                ScrollView(.horizontal) {
                                    HStack(alignment: .top, spacing: 12) {
                                        ForEach(detail.imageArtifacts) { artifact in
                                            ImageArtifactCard(artifact: artifact)
                                        }
                                    }
                                }
                            }
                        }

                        if !detail.textArtifacts.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Text Artifacts")
                                    .font(.headline)
                                Picker("Artifact", selection: $runStore.selectedTextArtifactName) {
                                    ForEach(detail.textArtifacts) { artifact in
                                        Text(artifact.name).tag(Optional(artifact.name))
                                    }
                                }
                                if let selected = runStore.selectedTextArtifact {
                                    TextEditor(text: .constant(selected.content))
                                        .font(.system(.body, design: .monospaced))
                                        .frame(minHeight: 420)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                        )
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 20)
                }
            } else {
                ContentUnavailableView("No Runs", systemImage: "tray", description: Text("Run Blink once to populate debug artifacts here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct ProviderModelRow: View {
    @Binding var selection: ProviderModelSelection
    let suggestedModels: [String]
    let presets: [ProviderPreset]
    let warningText: String?

    var body: some View {
        Picker("Provider Preset", selection: $selection.providerPresetID) {
            ForEach(presets) { preset in
                Text(preset.name).tag(preset.id)
            }
        }

        HStack {
            TextField("Model", text: $selection.model)
            Menu("Suggested Models") {
                ForEach(suggestedModels, id: \.self) { model in
                    Button(model) { selection.model = model }
                }
            }
        }

        if let warningText {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(warningText)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct ImageArtifactCard: View {
    let artifact: ImageArtifact

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(artifact.name)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let image = NSImage(contentsOf: artifact.url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 360, maxHeight: 220)
                    .background(Color.black.opacity(0.06))
                    .cornerRadius(8)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 240, height: 160)
                    .overlay(Text("Unavailable").foregroundStyle(.secondary))
            }
        }
        .frame(width: 380, alignment: .leading)
    }
}
