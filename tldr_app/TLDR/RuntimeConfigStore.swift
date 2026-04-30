import Combine
import Foundation

struct RuntimeConfigFile: Codable {
    let version: Int
    var autoPaste: Bool
    var model: String
    var allowEventLogging: Bool
    var allowContentRetention: Bool

    enum CodingKeys: String, CodingKey {
        case version
        case autoPaste = "auto_paste"
        case model
        case allowEventLogging = "allow_event_logging"
        case allowContentRetention = "allow_content_retention"
    }

    init(
        version: Int,
        autoPaste: Bool,
        model: String,
        allowEventLogging: Bool,
        allowContentRetention: Bool
    ) {
        self.version = version
        self.autoPaste = autoPaste
        self.model = model
        self.allowEventLogging = allowEventLogging
        self.allowContentRetention = allowContentRetention
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        autoPaste = try container.decodeIfPresent(Bool.self, forKey: .autoPaste) ?? true
        model = try container.decodeIfPresent(String.self, forKey: .model)
            ?? "gemini-3.1-flash-lite-preview"
        allowEventLogging = try container.decodeIfPresent(Bool.self, forKey: .allowEventLogging) ?? true
        allowContentRetention = try container.decodeIfPresent(Bool.self, forKey: .allowContentRetention)
            ?? false
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

    private var isSaving = false

    init() {
        let config = Self.loadOrCreateConfig()
        self.autoPaste = config.autoPaste
        self.model = config.model
        self.allowEventLogging = config.allowEventLogging
        self.allowContentRetention = config.allowContentRetention
    }

    var snapshot: RuntimeConfigFile {
        RuntimeConfigFile(
            version: 1,
            autoPaste: autoPaste,
            model: model,
            allowEventLogging: allowEventLogging,
            allowContentRetention: allowContentRetention
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
            model: "gemini-3.1-flash-lite-preview",
            allowEventLogging: true,
            allowContentRetention: false
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
