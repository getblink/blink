import Combine
import Foundation

struct RuntimeConfigFile: Codable {
    let version: Int
    var autoPaste: Bool
    var model: String
    var allowEventLogging: Bool
    var allowContentRetention: Bool
    var soundsEnabled: Bool
    var thinkingLevel: String?
    var nudgesEnabled: Bool
    var lastNudgeAt: Date?
    var recentNudgeDismissals: [Date]
    var nudgeCooldownMinutes: Int

    enum CodingKeys: String, CodingKey {
        case version
        case autoPaste = "auto_paste"
        case model
        case allowEventLogging = "allow_event_logging"
        case allowContentRetention = "allow_content_retention"
        case soundsEnabled = "sounds_enabled"
        case thinkingLevel = "thinking_level"
        case nudgesEnabled = "nudges_enabled"
        case lastNudgeAt = "last_nudge_at"
        case recentNudgeDismissals = "recent_nudge_dismissals"
        case nudgeCooldownMinutes = "nudge_cooldown_minutes"
    }

    init(
        version: Int,
        autoPaste: Bool,
        model: String,
        allowEventLogging: Bool,
        allowContentRetention: Bool,
        soundsEnabled: Bool,
        thinkingLevel: String?,
        nudgesEnabled: Bool,
        lastNudgeAt: Date?,
        recentNudgeDismissals: [Date],
        nudgeCooldownMinutes: Int
    ) {
        self.version = version
        self.autoPaste = autoPaste
        self.model = model
        self.allowEventLogging = allowEventLogging
        self.allowContentRetention = allowContentRetention
        self.soundsEnabled = soundsEnabled
        self.thinkingLevel = thinkingLevel
        self.nudgesEnabled = nudgesEnabled
        self.lastNudgeAt = lastNudgeAt
        self.recentNudgeDismissals = recentNudgeDismissals
        self.nudgeCooldownMinutes = nudgeCooldownMinutes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        autoPaste = try container.decodeIfPresent(Bool.self, forKey: .autoPaste) ?? true
        model = try container.decodeIfPresent(String.self, forKey: .model)
            ?? "gemini-3-flash-preview"
        allowEventLogging = try container.decodeIfPresent(Bool.self, forKey: .allowEventLogging) ?? true
        allowContentRetention = try container.decodeIfPresent(Bool.self, forKey: .allowContentRetention)
            ?? false
        soundsEnabled = try container.decodeIfPresent(Bool.self, forKey: .soundsEnabled) ?? true
        thinkingLevel = try container.decodeIfPresent(String.self, forKey: .thinkingLevel)
        nudgesEnabled = try container.decodeIfPresent(Bool.self, forKey: .nudgesEnabled) ?? true
        lastNudgeAt = try container.decodeIfPresent(Date.self, forKey: .lastNudgeAt)
        recentNudgeDismissals = try container.decodeIfPresent([Date].self, forKey: .recentNudgeDismissals) ?? []
        nudgeCooldownMinutes = try container.decodeIfPresent(Int.self, forKey: .nudgeCooldownMinutes) ?? 30
    }
}

@MainActor
final class RuntimeConfigStore: ObservableObject {
    @Published var autoPaste: Bool {
        didSet { save() }
    }
    @Published var model: String {
        didSet { save() }
    }
    @Published var allowEventLogging: Bool {
        didSet { save() }
    }
    @Published var allowContentRetention: Bool {
        didSet { save() }
    }
    @Published var soundsEnabled: Bool {
        didSet { save() }
    }
    @Published var thinkingLevel: String? {
        didSet { save() }
    }
    @Published var nudgesEnabled: Bool {
        didSet { save() }
    }
    @Published var lastNudgeAt: Date? {
        didSet { save() }
    }
    @Published var recentNudgeDismissals: [Date] {
        didSet { save() }
    }
    @Published var nudgeCooldownMinutes: Int {
        didSet { save() }
    }

    private var isSaving = false

    init() {
        let config = Self.loadOrCreateConfig()
        self.autoPaste = config.autoPaste
        self.model = config.model
        self.allowEventLogging = config.allowEventLogging
        self.allowContentRetention = config.allowContentRetention
        self.soundsEnabled = config.soundsEnabled
        self.thinkingLevel = config.thinkingLevel
        self.nudgesEnabled = config.nudgesEnabled
        self.lastNudgeAt = config.lastNudgeAt
        self.recentNudgeDismissals = config.recentNudgeDismissals
        self.nudgeCooldownMinutes = config.nudgeCooldownMinutes
    }

    var snapshot: RuntimeConfigFile {
        RuntimeConfigFile(
            version: 1,
            autoPaste: autoPaste,
            model: model,
            allowEventLogging: allowEventLogging,
            allowContentRetention: allowContentRetention,
            soundsEnabled: soundsEnabled,
            thinkingLevel: thinkingLevel,
            nudgesEnabled: nudgesEnabled,
            lastNudgeAt: lastNudgeAt,
            recentNudgeDismissals: recentNudgeDismissals,
            nudgeCooldownMinutes: nudgeCooldownMinutes
        )
    }

    private static func loadOrCreateConfig() -> RuntimeConfigFile {
        let path = Paths.runtimeConfigPath
        if let data = try? Data(contentsOf: path),
           let config = try? JSONDecoder().decode(RuntimeConfigFile.self, from: data) {
            return config
        }
        let config = RuntimeConfigFile(
            version: 1,
            autoPaste: true,
            model: "gemini-3-flash-preview",
            allowEventLogging: true,
            allowContentRetention: false,
            soundsEnabled: true,
            thinkingLevel: nil,
            nudgesEnabled: true,
            lastNudgeAt: nil,
            recentNudgeDismissals: [],
            nudgeCooldownMinutes: 30
        )
        write(config)
        return config
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Self.write(snapshot)
        isSaving = false
    }

    private static func write(_ config: RuntimeConfigFile) {
        guard let data = try? JSONEncoder.prettyPrinted.encode(config) else { return }
        try? data.write(to: Paths.runtimeConfigPath, options: .atomic)
    }
}

private extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
