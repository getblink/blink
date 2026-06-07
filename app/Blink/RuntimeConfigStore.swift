import Combine
import Foundation

enum StyleKnob: String, CaseIterable {
    case incremental, balanced, agentic
    case casual, formal
    case terse, thorough
    case diplomatic, direct
    case neutral, mirror

    static let initiativeOptions: [StyleKnob] = [.incremental, .balanced, .agentic]
    static let toneOptions: [StyleKnob] = [.casual, .balanced, .formal]
    static let lengthOptions: [StyleKnob] = [.terse, .balanced, .thorough]
    static let directnessOptions: [StyleKnob] = [.diplomatic, .balanced, .direct]
    static let voiceMirrorOptions: [StyleKnob] = [.neutral, .balanced, .mirror]
}

struct StylePrefs: Codable, Equatable {
    var initiative: String
    var tone: String
    var length: String
    var directness: String
    var voiceMirror: String
    var aboutMe: String

    static let aboutMeMaxChars = 2000

    enum CodingKeys: String, CodingKey {
        case initiative
        case tone
        case length
        case directness
        case voiceMirror = "voice_mirror"
        case aboutMe = "about_me"
    }

    static let `default` = StylePrefs(
        initiative: "balanced",
        tone: "balanced",
        length: "balanced",
        directness: "balanced",
        voiceMirror: "balanced",
        aboutMe: ""
    )

    init(
        initiative: String = "balanced",
        tone: String = "balanced",
        length: String = "balanced",
        directness: String = "balanced",
        voiceMirror: String = "balanced",
        aboutMe: String = ""
    ) {
        self.initiative = initiative
        self.tone = tone
        self.length = length
        self.directness = directness
        self.voiceMirror = voiceMirror
        self.aboutMe = aboutMe
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        initiative = try container.decodeIfPresent(String.self, forKey: .initiative) ?? "balanced"
        tone = try container.decodeIfPresent(String.self, forKey: .tone) ?? "balanced"
        length = try container.decodeIfPresent(String.self, forKey: .length) ?? "balanced"
        directness = try container.decodeIfPresent(String.self, forKey: .directness) ?? "balanced"
        voiceMirror = try container.decodeIfPresent(String.self, forKey: .voiceMirror) ?? "balanced"
        aboutMe = try container.decodeIfPresent(String.self, forKey: .aboutMe) ?? ""
    }
}

struct RuntimeConfigFile: Codable {
    static let defaultLensAnimationSpeed = 1.25

    let version: Int
    var autoPaste: Bool
    var model: String
    var allowEventLogging: Bool
    var allowContentRetention: Bool
    var soundsEnabled: Bool
    var thinkingLevel: String?
    /// Per-app-surface reasoning overrides, keyed by source bundle id. When a
    /// capture comes from a bundle present here, this level wins over the
    /// global `thinkingLevel`. Toggled via the overlay's ⌘T cycle.
    var appThinkingLevels: [String: String]
    var outputFormat: String?
    var nudgesEnabled: Bool
    var lastNudgeAt: Date?
    var recentNudgeDismissals: [Date]
    var nudgeCooldownMinutes: Int
    var style: StylePrefs
    var annotateScreenshots: Bool
    /// Pace multiplier for the Liquid Glass capture-loading intro (drain → pill
    /// → smile). 1.0 = original timing; higher = snappier. Read fresh by the
    /// lens on each capture, so a Settings change applies on the next press.
    var lensAnimationSpeed: Double

    enum CodingKeys: String, CodingKey {
        case version
        case autoPaste = "auto_paste"
        case model
        case allowEventLogging = "allow_event_logging"
        case allowContentRetention = "allow_content_retention"
        case soundsEnabled = "sounds_enabled"
        case thinkingLevel = "thinking_level"
        case appThinkingLevels = "app_thinking_levels"
        case outputFormat = "output_format"
        case nudgesEnabled = "nudges_enabled"
        case lastNudgeAt = "last_nudge_at"
        case recentNudgeDismissals = "recent_nudge_dismissals"
        case nudgeCooldownMinutes = "nudge_cooldown_minutes"
        case style
        case annotateScreenshots = "annotate_screenshots"
        case lensAnimationSpeed = "lens_animation_speed"
    }

    init(
        version: Int,
        autoPaste: Bool,
        model: String,
        allowEventLogging: Bool,
        allowContentRetention: Bool,
        soundsEnabled: Bool,
        thinkingLevel: String?,
        appThinkingLevels: [String: String] = [:],
        outputFormat: String? = nil,
        nudgesEnabled: Bool,
        lastNudgeAt: Date?,
        recentNudgeDismissals: [Date],
        nudgeCooldownMinutes: Int,
        style: StylePrefs = .default,
        annotateScreenshots: Bool = true,
        lensAnimationSpeed: Double = RuntimeConfigFile.defaultLensAnimationSpeed
    ) {
        self.version = version
        self.autoPaste = autoPaste
        self.model = model
        self.allowEventLogging = allowEventLogging
        self.allowContentRetention = allowContentRetention
        self.soundsEnabled = soundsEnabled
        self.thinkingLevel = thinkingLevel
        self.appThinkingLevels = appThinkingLevels
        self.outputFormat = outputFormat
        self.nudgesEnabled = nudgesEnabled
        self.lastNudgeAt = lastNudgeAt
        self.recentNudgeDismissals = recentNudgeDismissals
        self.nudgeCooldownMinutes = nudgeCooldownMinutes
        self.style = style
        self.annotateScreenshots = annotateScreenshots
        self.lensAnimationSpeed = lensAnimationSpeed
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
        appThinkingLevels = try container.decodeIfPresent([String: String].self, forKey: .appThinkingLevels) ?? [:]
        outputFormat = try container.decodeIfPresent(String.self, forKey: .outputFormat)
        nudgesEnabled = try container.decodeIfPresent(Bool.self, forKey: .nudgesEnabled) ?? true
        lastNudgeAt = try container.decodeIfPresent(Date.self, forKey: .lastNudgeAt)
        recentNudgeDismissals = try container.decodeIfPresent([Date].self, forKey: .recentNudgeDismissals) ?? []
        nudgeCooldownMinutes = try container.decodeIfPresent(Int.self, forKey: .nudgeCooldownMinutes) ?? 30
        style = try container.decodeIfPresent(StylePrefs.self, forKey: .style) ?? .default
        annotateScreenshots = try container.decodeIfPresent(Bool.self, forKey: .annotateScreenshots) ?? true
        lensAnimationSpeed = try container.decodeIfPresent(Double.self, forKey: .lensAnimationSpeed)
            ?? Self.defaultLensAnimationSpeed
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
    @Published var appThinkingLevels: [String: String] {
        didSet { save() }
    }
    @Published var outputFormat: String? {
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
    @Published var style: StylePrefs {
        didSet { save() }
    }
    @Published var annotateScreenshots: Bool {
        didSet { save() }
    }
    @Published var lensAnimationSpeed: Double {
        didSet { save() }
    }

    /// Bounds for `lensAnimationSpeed`, shared by the Settings slider and the
    /// lens (which clamps defensively in case the config file is hand-edited).
    static let lensAnimationSpeedRange: ClosedRange<Double> = 1.0...3.0

    private var isSaving = false

    init() {
        let config = Self.loadOrCreateConfig()
        self.autoPaste = config.autoPaste
        self.model = config.model
        self.allowEventLogging = config.allowEventLogging
        self.allowContentRetention = config.allowContentRetention
        self.soundsEnabled = config.soundsEnabled
        self.thinkingLevel = config.thinkingLevel
        self.appThinkingLevels = config.appThinkingLevels
        self.outputFormat = config.outputFormat
        self.nudgesEnabled = config.nudgesEnabled
        self.lastNudgeAt = config.lastNudgeAt
        self.recentNudgeDismissals = config.recentNudgeDismissals
        self.nudgeCooldownMinutes = config.nudgeCooldownMinutes
        self.style = config.style
        self.annotateScreenshots = config.annotateScreenshots
        self.lensAnimationSpeed = config.lensAnimationSpeed
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
            appThinkingLevels: appThinkingLevels,
            outputFormat: outputFormat,
            nudgesEnabled: nudgesEnabled,
            lastNudgeAt: lastNudgeAt,
            recentNudgeDismissals: recentNudgeDismissals,
            nudgeCooldownMinutes: nudgeCooldownMinutes,
            style: style,
            annotateScreenshots: annotateScreenshots,
            lensAnimationSpeed: lensAnimationSpeed
        )
    }

    /// The reasoning level a capture from `bundleID` should use: the per-app
    /// override when one exists, otherwise the global default. A nil bundle id
    /// (unknown source) falls back to the global level.
    func resolvedThinkingLevel(forBundle bundleID: String?) -> String? {
        if let bundleID, let level = appThinkingLevels[bundleID] {
            return level
        }
        return thinkingLevel
    }

    /// Advance the per-app reasoning override for `bundleID` one step along the
    /// `Off → Low → Medium → High → Off` cycle and persist it. Returns the new
    /// level. The starting point is the app's current resolved level.
    @discardableResult
    func cycleThinkingLevel(forBundle bundleID: String) -> String {
        let next = ReasoningLevels.next(after: appThinkingLevels[bundleID] ?? thinkingLevel)
        appThinkingLevels[bundleID] = next
        return next
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
            outputFormat: nil,
            nudgesEnabled: true,
            lastNudgeAt: nil,
            recentNudgeDismissals: [],
            nudgeCooldownMinutes: 30,
            style: .default,
            annotateScreenshots: true,
            lensAnimationSpeed: RuntimeConfigFile.defaultLensAnimationSpeed
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
