import Foundation

struct Config {
    let geminiApiKey: String?
    let devPythonPath: String?

    static func load() -> Config {
        Config(
            geminiApiKey: emptyToNil(ProcessInfo.processInfo.environment["GEMINI_API_KEY"]),
            devPythonPath: emptyToNil(ProcessInfo.processInfo.environment["TLDR_DEV_PYTHON"])
        )
    }

    private static func emptyToNil(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

enum Paths {
    static var runtimeDir: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".tldr", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var runtimePromptsDir: URL {
        let dir = runtimeDir.appendingPathComponent("prompts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var runtimeConfigPath: URL {
        runtimeDir.appendingPathComponent("runtime-config.json")
    }

    static var runtimeSettingsPath: URL {
        runtimeDir.appendingPathComponent("settings.json")
    }

    static var installIDPath: URL {
        runtimeDir.appendingPathComponent("install_id")
    }

    static func loadOrCreateInstallID() -> String {
        let path = installIDPath
        if let existing = try? String(contentsOf: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }
        let installID = UUID().uuidString.lowercased()
        try? installID.write(to: path, atomically: true, encoding: .utf8)
        return installID
    }

    static var appSupportDir: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = base.appendingPathComponent("TLDR", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var runsDir: URL {
        let dir = appSupportDir.appendingPathComponent("runs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var pendingDir: URL {
        let dir = appSupportDir.appendingPathComponent("pending", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func pythonBinary(config: Config) -> URL? {
        if let dev = config.devPythonPath {
            return URL(fileURLWithPath: dev)
        }
        let candidate = Bundle.main.resourceURL?
            .appendingPathComponent("python", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("python3")
        if let candidate,
           FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    static var tldrOncePath: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("tldr_once.py")
    }

    static func bundledResource(named name: String) -> URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent(name),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static func activePromptPath(named name: String) -> URL? {
        let override = runtimePromptsDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: override.path) {
            return override
        }
        return bundledResource(named: name)
    }

    static var promptPath: URL? { activePromptPath(named: "prompt.txt") }

    static var settingsPath: URL? {
        if FileManager.default.fileExists(atPath: runtimeSettingsPath.path) {
            return runtimeSettingsPath
        }
        return bundledResource(named: "settings.json")
    }
}
