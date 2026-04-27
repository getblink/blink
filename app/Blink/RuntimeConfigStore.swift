import Combine
import Foundation

enum RequestMode: String, CaseIterable, Codable, Identifiable {
    case baselineFullImages = "baseline_full_images"
    case sourcePacketFullTargetImage = "source_packet_full_target_image"
    case sourcePacketTargetOCRPacket = "source_packet_target_ocr_packet"
    case sourcePacketTargetOCROrFullImage = "source_packet_target_ocr_or_full_image"
    case sourceOCRTargetTextOrFullImage = "source_ocr_target_text_or_full_image"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .baselineFullImages:
            return "Baseline: Full Source + Full Target"
        case .sourcePacketFullTargetImage:
            return "Source Packet + Full Target"
        case .sourcePacketTargetOCRPacket:
            return "Source Packet + Target OCR Packet"
        case .sourcePacketTargetOCROrFullImage:
            return "Auto: Source Packet + Target Context"
        case .sourceOCRTargetTextOrFullImage:
            return "Experimental: Fast Local Source OCR"
        }
    }

    var detail: String {
        switch self {
        case .baselineFullImages:
            return "Current two-image path."
        case .sourcePacketFullTargetImage:
            return "Precompute source packet, keep full target image at paste time."
        case .sourcePacketTargetOCRPacket:
            return "Precompute source packet, replace target image with local OCR packet."
        case .sourcePacketTargetOCROrFullImage:
            return "Default target path: use local target OCR/AX context when sufficient, otherwise fall back to full target image."
        case .sourceOCRTargetTextOrFullImage:
            return "Experimental source prep: use native OCR paragraphs, then the same target context and image fallback path as Auto."
        }
    }

    var requiresSourcePacket: Bool {
        switch self {
        case .baselineFullImages:
            return false
        case .sourcePacketFullTargetImage, .sourcePacketTargetOCRPacket, .sourcePacketTargetOCROrFullImage, .sourceOCRTargetTextOrFullImage:
            return true
        }
    }

    var requiresVisionInExtractor: Bool {
        switch self {
        case .sourceOCRTargetTextOrFullImage:
            return false
        case .baselineFullImages, .sourcePacketFullTargetImage, .sourcePacketTargetOCRPacket, .sourcePacketTargetOCROrFullImage:
            return true
        }
    }
}

struct ProviderModelOverride: Codable, Equatable {
    let supportsVision: Bool?

    enum CodingKeys: String, CodingKey {
        case supportsVision = "supports_vision"
    }

    var dictionaryRepresentation: [String: Any] {
        var payload: [String: Any] = [:]
        if let supportsVision {
            payload["supports_vision"] = supportsVision
        }
        return payload
    }
}

struct ProviderPreset: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let provider: String
    let apiKeyEnv: String
    let apiStyle: String
    let baseURL: String?
    let urlSubstitutions: [String]
    let defaultHeaders: [String: String]
    let extraHeaders: [String: String]
    let defaultModel: String
    let supportsVisionFlag: Bool?
    let suggestedModels: [String]
    let modelOverrides: [String: ProviderModelOverride]?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case provider
        case apiKeyEnv = "api_key_env"
        case apiStyle = "api_style"
        case baseURL = "base_url"
        case urlSubstitutions = "url_substitutions"
        case defaultHeaders = "default_headers"
        case extraHeaders = "extra_headers"
        case defaultModel = "default_model"
        case supportsVisionFlag = "supports_vision"
        case suggestedModels = "suggested_models"
        case modelOverrides = "model_overrides"
    }

    var defaultSupportsVision: Bool {
        supportsVisionFlag ?? true
    }

    func supportsVision(model: String) -> Bool {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = modelOverrides?[trimmed]?.supportsVision {
            return value
        }
        return defaultSupportsVision
    }

    var dictionaryRepresentation: [String: Any] {
        var payload: [String: Any] = [
            "id": id,
            "name": name,
            "provider": provider,
            "api_key_env": apiKeyEnv,
            "api_style": apiStyle,
            "base_url": baseURL as Any,
            "url_substitutions": urlSubstitutions,
            "default_headers": defaultHeaders,
            "extra_headers": extraHeaders,
            "default_model": defaultModel,
            "suggested_models": suggestedModels,
        ]
        if let supportsVisionFlag {
            payload["supports_vision"] = supportsVisionFlag
        }
        if let modelOverrides, !modelOverrides.isEmpty {
            payload["model_overrides"] = modelOverrides.mapValues { $0.dictionaryRepresentation }
        }
        return payload
    }
}

struct ProviderModelSelection: Codable, Equatable {
    var providerPresetID: String
    var model: String

    enum CodingKeys: String, CodingKey {
        case providerPresetID = "provider_preset_id"
        case model
    }
}

struct RuntimeConfigFile: Codable {
    let version: Int
    var extractor: ProviderModelSelection
    var paste: ProviderModelSelection
    var requestMode: RequestMode

    enum CodingKeys: String, CodingKey {
        case version
        case extractor
        case paste
        case requestMode = "request_mode"
    }
}

struct PromptDescriptor: Identifiable {
    let key: String
    let label: String
    let path: URL
    let sourceDescription: String

    var id: String { key }
}

struct RuntimeRoleSelection {
    let preset: ProviderPreset
    let model: String

    var providerLabel: String { preset.name }

    var dictionaryRepresentation: [String: Any] {
        [
            "model": model,
            "provider_preset": preset.dictionaryRepresentation,
        ]
    }
}

struct RuntimeSelectionSnapshot {
    let extractor: RuntimeRoleSelection
    let paste: RuntimeRoleSelection
    let requestMode: RequestMode
    let settingsPath: URL?
    let baselinePromptPath: URL?
    let sourceExtractPromptPath: URL?
    let sourcePacketTargetPromptPath: URL?
    let targetOCRPromptPath: URL?

    /// Label for the model that runs at paste time (the user-visible "Calling …" line).
    var pasteProviderLabel: String { paste.providerLabel }

    var payload: [String: Any] {
        [
            "version": 2,
            "request_mode": requestMode.rawValue,
            "extractor": extractor.dictionaryRepresentation,
            "paste": paste.dictionaryRepresentation,
            "paths": [
                "settings": settingsPath?.path as Any,
                "baseline_prompt": baselinePromptPath?.path as Any,
                "source_extract_prompt": sourceExtractPromptPath?.path as Any,
                "source_packet_target_prompt": sourcePacketTargetPromptPath?.path as Any,
                "target_ocr_prompt": targetOCRPromptPath?.path as Any,
            ],
        ]
    }
}

final class RuntimeConfigStore: ObservableObject {
    @Published var extractor: ProviderModelSelection {
        didSet {
            // NOTE: do not use `inout` helpers here — Swift's modify
            // accessor unconditionally writes back, which re-fires
            // didSet and recurses until the stack explodes.
            if let corrected = reconciledModel(for: extractor, oldPresetID: oldValue.providerPresetID),
               corrected != extractor {
                extractor = corrected
            }
        }
    }
    @Published var paste: ProviderModelSelection {
        didSet {
            if let corrected = reconciledModel(for: paste, oldPresetID: oldValue.providerPresetID),
               corrected != paste {
                paste = corrected
            }
        }
    }
    @Published var requestMode: RequestMode

    let providerPresets: [ProviderPreset]

    private var cancellables: Set<AnyCancellable> = []

    init() {
        let presets = Self.loadProviderPresets()
        self.providerPresets = presets
        let config = Self.loadOrCreateConfig(presets: presets)
        self.extractor = config.extractor
        self.paste = config.paste
        self.requestMode = config.requestMode

        Publishers.CombineLatest3($extractor, $paste, $requestMode)
            .dropFirst()
            .sink { [weak self] _, _, _ in
                self?.save()
            }
            .store(in: &cancellables)
    }

    func extractorPreset() -> ProviderPreset {
        providerPreset(id: extractor.providerPresetID) ?? providerPresets.first ?? Self.fallbackPreset
    }

    func pastePreset() -> ProviderPreset {
        providerPreset(id: paste.providerPresetID) ?? providerPresets.first ?? Self.fallbackPreset
    }

    func refreshFromDisk() {
        let config = Self.loadOrCreateConfig(presets: providerPresets)
        extractor = config.extractor
        paste = config.paste
        requestMode = config.requestMode
    }

    func currentSnapshot() -> RuntimeSelectionSnapshot {
        save()
        return RuntimeSelectionSnapshot(
            extractor: resolvedRole(from: extractor),
            paste: resolvedRole(from: paste),
            requestMode: requestMode,
            settingsPath: Paths.settingsPath,
            baselinePromptPath: Paths.activePromptPath(named: "prompt.txt"),
            sourceExtractPromptPath: Paths.activePromptPath(named: "source_packet_extract_prompt_v3_ocr.txt"),
            sourcePacketTargetPromptPath: Paths.activePromptPath(named: "source_packet_target_prompt_v3_ocr.txt"),
            targetOCRPromptPath: Paths.activePromptPath(named: "target_context_prompt_ocr.txt")
        )
    }

    var promptDescriptors: [PromptDescriptor] {
        [
            ("baseline_prompt", "Baseline Prompt", "prompt.txt"),
            ("source_extract_prompt", "Source Packet Extract Prompt", "source_packet_extract_prompt_v3_ocr.txt"),
            ("source_packet_target_prompt", "Source Packet + Full Target Prompt", "source_packet_target_prompt_v3_ocr.txt"),
            ("target_ocr_prompt", "Target OCR Prompt", "target_context_prompt_ocr.txt"),
        ].compactMap { key, label, filename in
            guard let path = Paths.activePromptPath(named: filename) else { return nil }
            let overridePath = Paths.runtimePromptsDir.appendingPathComponent(filename)
            let sourceDescription = FileManager.default.fileExists(atPath: overridePath.path)
                ? "override"
                : "bundled"
            return PromptDescriptor(
                key: key,
                label: label,
                path: path,
                sourceDescription: sourceDescription
            )
        }
    }

    func suggestedModels(for selection: ProviderModelSelection) -> [String] {
        providerPreset(id: selection.providerPresetID)?.suggestedModels ?? []
    }

    private func resolvedRole(from selection: ProviderModelSelection) -> RuntimeRoleSelection {
        let preset = providerPreset(id: selection.providerPresetID) ?? providerPresets.first ?? Self.fallbackPreset
        let trimmed = selection.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return RuntimeRoleSelection(
            preset: preset,
            model: trimmed.isEmpty ? preset.defaultModel : trimmed
        )
    }

    /// Returns a corrected selection if the model field needs to be swapped to
    /// the new preset's default (because the old value was empty or the old
    /// preset's default). Returns nil when no change is needed — the caller
    /// must skip the assignment in that case to avoid retriggering didSet.
    private func reconciledModel(
        for selection: ProviderModelSelection,
        oldPresetID: String
    ) -> ProviderModelSelection? {
        guard selection.providerPresetID != oldPresetID else { return nil }
        let trimmed = selection.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldPreset = providerPreset(id: oldPresetID)
        guard trimmed.isEmpty || trimmed == oldPreset?.defaultModel else { return nil }
        let newPreset = providerPreset(id: selection.providerPresetID) ?? Self.fallbackPreset
        var corrected = selection
        corrected.model = newPreset.defaultModel
        return corrected
    }

    private func providerPreset(id: String) -> ProviderPreset? {
        providerPresets.first(where: { $0.id == id })
    }

    private func save() {
        let config = RuntimeConfigFile(
            version: 2,
            extractor: trimmed(extractor),
            paste: trimmed(paste),
            requestMode: requestMode
        )
        do {
            let data = try JSONEncoder.pretty.encode(config)
            try data.write(to: Paths.runtimeConfigPath, options: .atomic)
        } catch {
            NSLog("[blink] failed to save runtime config: %@", error.localizedDescription)
        }
    }

    private func trimmed(_ selection: ProviderModelSelection) -> ProviderModelSelection {
        let preset = providerPreset(id: selection.providerPresetID) ?? Self.fallbackPreset
        let model = selection.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProviderModelSelection(
            providerPresetID: preset.id,
            model: model.isEmpty ? preset.defaultModel : model
        )
    }

    private static func loadProviderPresets() -> [ProviderPreset] {
        guard let path = Paths.providerPresetsPath,
              let data = try? Data(contentsOf: path),
              let presets = try? JSONDecoder().decode([ProviderPreset].self, from: data),
              !presets.isEmpty else {
            return [fallbackPreset]
        }
        return presets
    }

    private static func loadOrCreateConfig(presets: [ProviderPreset]) -> RuntimeConfigFile {
        if let data = try? Data(contentsOf: Paths.runtimeConfigPath),
           let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let version = (raw["version"] as? Int) ?? 1
            if version >= 2 {
                if var decoded = try? JSONDecoder().decode(RuntimeConfigFile.self, from: data) {
                    // Soft repair: if a row references a preset that's gone,
                    // swap only that row to the first available preset.
                    // Keeping the other row preserves the user's deliberate
                    // split (the common case is one provider going stale).
                    let fallbackPresetID = presets.first?.id ?? Self.fallbackPreset.id
                    if !presets.contains(where: { $0.id == decoded.extractor.providerPresetID }) {
                        decoded.extractor = ProviderModelSelection(
                            providerPresetID: fallbackPresetID,
                            model: presets.first?.defaultModel ?? Self.fallbackPreset.defaultModel
                        )
                    }
                    if !presets.contains(where: { $0.id == decoded.paste.providerPresetID }) {
                        decoded.paste = ProviderModelSelection(
                            providerPresetID: fallbackPresetID,
                            model: presets.first?.defaultModel ?? Self.fallbackPreset.defaultModel
                        )
                    }
                    return decoded
                }
            } else if let migrated = migrateLegacyConfig(raw: raw, presets: presets) {
                return migrated
            }
        }

        let defaultPreset = presets.first ?? fallbackPreset
        let defaultSelection = ProviderModelSelection(
            providerPresetID: defaultPreset.id,
            model: defaultPreset.defaultModel
        )
        let fallback = RuntimeConfigFile(
            version: 2,
            extractor: defaultSelection,
            paste: defaultSelection,
            requestMode: .baselineFullImages
        )
        do {
            let data = try JSONEncoder.pretty.encode(fallback)
            try data.write(to: Paths.runtimeConfigPath, options: .atomic)
        } catch {
            NSLog("[blink] failed to seed runtime config: %@", error.localizedDescription)
        }
        return fallback
    }

    private static func migrateLegacyConfig(
        raw: [String: Any],
        presets: [ProviderPreset]
    ) -> RuntimeConfigFile? {
        guard let presetID = raw["selected_provider_preset_id"] as? String,
              let preset = presets.first(where: { $0.id == presetID }) else {
            return nil
        }
        let model = (raw["model"] as? String) ?? preset.defaultModel
        let requestModeRaw = (raw["request_mode"] as? String) ?? RequestMode.baselineFullImages.rawValue
        let requestMode = RequestMode(rawValue: requestModeRaw) ?? .baselineFullImages
        let selection = ProviderModelSelection(providerPresetID: preset.id, model: model)
        return RuntimeConfigFile(
            version: 2,
            extractor: selection,
            paste: selection,
            requestMode: requestMode
        )
    }

    /// Last-resort preset used only when `provider_presets.json` failed to
    /// load. If we ever ship a fallback that includes a text-only model, the
    /// vision warning will silently never trip — extend `modelOverrides`
    /// alongside any such addition.
    private static let fallbackPreset = ProviderPreset(
        id: "gemini-direct",
        name: "Gemini Direct",
        provider: "gemini",
        apiKeyEnv: "GEMINI_API_KEY",
        apiStyle: "native",
        baseURL: nil,
        urlSubstitutions: [],
        defaultHeaders: [:],
        extraHeaders: [:],
        defaultModel: "gemini-3.1-flash-lite-preview",
        supportsVisionFlag: true,
        suggestedModels: ["gemini-3.1-flash-lite-preview"],
        modelOverrides: nil
    )
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
