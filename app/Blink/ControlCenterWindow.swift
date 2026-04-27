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

struct OverlayRect: Identifiable {
    let id: String
    let rect: CGRect
    let label: String
    let role: String
}

struct ImageOverlayData {
    let imageName: String
    let imageURL: URL
    let textTitle: String
    let textContent: String
    let ocrRects: [OverlayRect]
    let focusRect: OverlayRect?
    let caretRect: OverlayRect?
}

struct RunOverlayData {
    let source: ImageOverlayData?
    let target: ImageOverlayData?
}

struct RunBundleDetail {
    let summary: RunBundleSummary
    let bundleURL: URL
    let summaryLines: [String]
    let textArtifacts: [TextArtifact]
    let imageArtifacts: [ImageArtifact]
    let overlayData: RunOverlayData
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
        let overlayData = loadOverlayData(bundleURL: summary.url)

        return RunBundleDetail(
            summary: summary,
            bundleURL: summary.url,
            summaryLines: summaryLines,
            textArtifacts: textArtifacts,
            imageArtifacts: imageArtifacts,
            overlayData: overlayData
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
        if let completeness = targetContext["completeness"] as? String {
            lines.append("Target completeness: \(completeness)")
        }
        if let focusedLabel = targetContext["focused_label_hint"] as? String {
            lines.append("Focused label: \(focusedLabel)")
        }
        if let fallbackReason = targetContext["fallback_reason"] as? String {
            lines.append("Fallback reason: \(fallbackReason)")
        }
        if let fallbackReasons = targetContext["fallback_reasons"] as? [String], !fallbackReasons.isEmpty {
            lines.append("Fallback reasons: \(fallbackReasons.joined(separator: ", "))")
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

    private static func loadOverlayData(bundleURL: URL) -> RunOverlayData {
        let sourceImageURL = bundleURL.appendingPathComponent("source.png")
        let targetImageURL = bundleURL.appendingPathComponent("target.png")
        let preparedSource = readJSON(url: bundleURL.appendingPathComponent("prepared_source.json")) ?? [:]
        let sourceBuildLog = nestedDictionary(in: preparedSource, key: "build_log")
        let targetBuildLog = readJSON(url: bundleURL.appendingPathComponent("target_ocr_packet.build.json")) ?? [:]

        let sourceText = readText(url: bundleURL.appendingPathComponent("source_packet.txt"))
        let targetText = readText(url: bundleURL.appendingPathComponent("target_ocr_packet.txt"))

        let source = FileManager.default.fileExists(atPath: sourceImageURL.path)
            ? ImageOverlayData(
                imageName: "source.png",
                imageURL: sourceImageURL,
                textTitle: "source_packet.txt",
                textContent: sourceText,
                ocrRects: ocrOverlayRects(from: sourceBuildLog, prefix: "source"),
                focusRect: nil,
                caretRect: nil
            )
            : nil
        let target = FileManager.default.fileExists(atPath: targetImageURL.path)
            ? ImageOverlayData(
                imageName: "target.png",
                imageURL: targetImageURL,
                textTitle: "target_ocr_packet.txt",
                textContent: targetText,
                ocrRects: ocrOverlayRects(from: targetBuildLog, prefix: "target"),
                focusRect: overlayRect(
                    from: nestedDictionary(in: targetBuildLog, key: "focus_rect_local_pixels"),
                    id: "target-focus",
                    label: "focus band",
                    role: "focus"
                ),
                caretRect: overlayRect(
                    from: nestedDictionary(
                        in: nestedDictionary(in: targetBuildLog, key: "focus_debug"),
                        key: "local_line_rect"
                    ),
                    id: "target-caret",
                    label: "caret line",
                    role: "caret"
                )
            )
            : nil
        return RunOverlayData(source: source, target: target)
    }

    private static func readText(url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private static func ocrOverlayRects(from buildLog: [String: Any], prefix: String) -> [OverlayRect] {
        guard let blocks = buildLog["ocr_blocks"] as? [[String: Any]] else { return [] }
        return blocks.enumerated().compactMap { index, block in
            let bbox = nestedDictionary(in: block, key: "bbox")
            let label = (block["text"] as? String) ?? "OCR"
            return overlayRect(
                from: bbox,
                id: "\(prefix)-ocr-\(index)",
                label: label,
                role: (block["kept_for_processing"] as? Bool) == false ? "ocr-muted" : "ocr"
            )
        }
    }

    private static func overlayRect(
        from payload: [String: Any],
        id: String,
        label: String,
        role: String
    ) -> OverlayRect? {
        guard let x = number(payload["x"]),
              let y = number(payload["y"]),
              let width = number(payload["width"]),
              let height = number(payload["height"]),
              width > 0,
              height > 0 else {
            return nil
        }
        return OverlayRect(
            id: id,
            rect: CGRect(x: x, y: y, width: width, height: height),
            label: label,
            role: role
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
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
            case "target_ocr_packet.txt": return 5
            case "target_ocr_packet.build.json": return 6
            case "run.json": return 7
            case "host_profile.json": return 8
            case "stderr.log": return 9
            case "source.png": return 10
            case "target.png": return 11
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

                        RunOCRVisualizerView(detail: detail)

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

private enum VisualizerImageChoice: String, CaseIterable, Identifiable {
    case target = "Target"
    case source = "Source"

    var id: String { rawValue }
}

private struct RunOCRVisualizerView: View {
    let detail: RunBundleDetail
    @State private var selectedImage: VisualizerImageChoice = .target
    @State private var showOCRBoxes = true
    @State private var showOCRText = false
    @State private var showFocus = true

    private var selectedData: ImageOverlayData? {
        switch selectedImage {
        case .source:
            return detail.overlayData.source
        case .target:
            return detail.overlayData.target
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("OCR Visualizer")
                    .font(.headline)
                Spacer()
                Picker("Image", selection: $selectedImage) {
                    ForEach(VisualizerImageChoice.allCases) { choice in
                        Text(choice.rawValue).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }

            HStack(spacing: 14) {
                Toggle("OCR boxes", isOn: $showOCRBoxes)
                Toggle("Text labels", isOn: $showOCRText)
                Toggle("Focus/caret", isOn: $showFocus)
            }
            .font(.caption)

            if let selectedData {
                HStack(alignment: .top, spacing: 12) {
                    OverlayImageView(
                        data: selectedData,
                        showOCRBoxes: showOCRBoxes,
                        showOCRText: showOCRText,
                        showFocus: showFocus
                    )
                    .frame(minWidth: 520, maxWidth: .infinity, minHeight: 420, maxHeight: 520)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(selectedData.textTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: .constant(selectedData.textContent))
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 360)
                            .frame(minHeight: 420)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                            )
                    }
                }
            } else {
                ContentUnavailableView("No visualizer data", systemImage: "rectangle.dashed", description: Text("This run does not include the selected image artifact."))
                    .frame(minHeight: 220)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct OverlayImageView: View {
    let data: ImageOverlayData
    let showOCRBoxes: Bool
    let showOCRText: Bool
    let showFocus: Bool

    var body: some View {
        GeometryReader { geometry in
            if let image = NSImage(contentsOf: data.imageURL) {
                let imageSize = pixelSize(for: image)
                let fitted = fittedRect(imageSize: imageSize, in: geometry.size)
                ZStack(alignment: .topLeading) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)

                    if showOCRBoxes {
                        ForEach(data.ocrRects) { rect in
                            overlayRectangle(rect, fitted: fitted, imageSize: imageSize)
                        }
                    }

                    if showFocus {
                        if let focusRect = data.focusRect {
                            overlayRectangle(focusRect, fitted: fitted, imageSize: imageSize)
                        }
                        if let caretRect = data.caretRect {
                            overlayRectangle(caretRect, fitted: fitted, imageSize: imageSize)
                        }
                    }

                    if showOCRText {
                        ForEach(data.ocrRects.prefix(80)) { rect in
                            overlayLabel(rect, fitted: fitted, imageSize: imageSize)
                        }
                    }
                }
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.15))
                    .overlay(Text("Image unavailable").foregroundStyle(.secondary))
            }
        }
        .background(Color.black.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func overlayRectangle(
        _ overlay: OverlayRect,
        fitted: CGRect,
        imageSize: CGSize
    ) -> some View {
        let rect = displayRect(for: overlay.rect, fitted: fitted, imageSize: imageSize)
        return Rectangle()
            .stroke(color(for: overlay.role), lineWidth: overlay.role == "caret" ? 2 : 1.5)
            .background(color(for: overlay.role).opacity(overlay.role == "focus" ? 0.10 : 0.03))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }

    private func overlayLabel(
        _ overlay: OverlayRect,
        fitted: CGRect,
        imageSize: CGSize
    ) -> some View {
        let rect = displayRect(for: overlay.rect, fitted: fitted, imageSize: imageSize)
        return Text(overlay.label)
            .font(.system(size: 10, weight: .medium, design: .default))
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(color(for: overlay.role).opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .position(x: min(max(rect.minX + 48, fitted.minX + 48), fitted.maxX - 48), y: max(rect.minY - 8, fitted.minY + 8))
    }

    private func color(for role: String) -> Color {
        switch role {
        case "focus":
            return .green
        case "caret":
            return .orange
        case "ocr-muted":
            return .gray
        default:
            return .cyan
        }
    }

    private func displayRect(for rect: CGRect, fitted: CGRect, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scaleX = fitted.width / imageSize.width
        let scaleY = fitted.height / imageSize.height
        return CGRect(
            x: fitted.minX + rect.minX * scaleX,
            y: fitted.minY + rect.minY * scaleY,
            width: rect.width * scaleX,
            height: max(1.0, rect.height * scaleY)
        )
    }

    private func fittedRect(imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(
            x: (containerSize.width - width) / 2.0,
            y: (containerSize.height - height) / 2.0,
            width: width,
            height: height
        )
    }

    private func pixelSize(for image: NSImage) -> CGSize {
        if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image.size
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
