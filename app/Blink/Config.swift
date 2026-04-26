import Foundation

/// Runtime configuration for Blink.app, resolved from (in order):
/// 1. `~/Library/Application Support/Blink/overrides.plist`
/// 2. `Info.plist` (`BlinkProxyURL`, `BlinkProxyToken`)
///
/// Overrides exist so a dogfood tester can rotate the proxy bearer without
/// re-notarization. The overrides file is ignored if missing; all keys are
/// optional.
struct Config {
    let proxyURL: String?
    let proxyToken: String?
    let geminiApiKey: String?
    let devPythonPath: String?

    static func load() -> Config {
        let overrides = readOverrides()
        let bundleDict = Bundle.main.infoDictionary ?? [:]

        let proxyURL = overrides["BlinkProxyURL"] as? String
            ?? bundleDict["BlinkProxyURL"] as? String

        let proxyToken = overrides["BlinkProxyToken"] as? String
            ?? bundleDict["BlinkProxyToken"] as? String

        // GEMINI_API_KEY for dev / direct-to-Google runs (no proxy). Sources,
        // in order: overrides.plist → launchd-inherited env var. Testers using
        // a proxy wouldn't set this.
        let apiKey = overrides["GeminiApiKey"] as? String
            ?? ProcessInfo.processInfo.environment["GEMINI_API_KEY"]

        // `BLINK_DEV_PYTHON` env var only: dev escape hatch during Phase 2
        // when the .app doesn't yet bundle its own python runtime.
        let devPython = ProcessInfo.processInfo.environment["BLINK_DEV_PYTHON"]

        return Config(
            proxyURL: emptyToNil(proxyURL),
            proxyToken: emptyToNil(proxyToken),
            geminiApiKey: emptyToNil(apiKey),
            devPythonPath: emptyToNil(devPython)
        )
    }

    private static func emptyToNil(_ s: String?) -> String? {
        guard let s = s, !s.isEmpty else { return nil }
        return s
    }

    private static func readOverrides() -> [String: Any] {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return [:] }
        let url = appSupport
            .appendingPathComponent("Blink", isDirectory: true)
            .appendingPathComponent("overrides.plist")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any]
        else { return [:] }
        return plist
    }
}

/// Paths the app writes to / reads from.
enum Paths {
    /// `~/.blink/`
    static var runtimeDir: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".blink", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `~/.blink/prompts/`
    static var runtimePromptsDir: URL {
        let dir = runtimeDir.appendingPathComponent("prompts", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var runtimeConfigPath: URL {
        runtimeDir.appendingPathComponent("runtime-config.json")
    }

    static var runtimeSettingsPath: URL {
        runtimeDir.appendingPathComponent("settings.json")
    }

    /// `~/Library/Application Support/Blink/`
    static var appSupportDir: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = base.appendingPathComponent("Blink", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `~/Library/Application Support/Blink/runs/`
    static var runsDir: URL {
        let dir = appSupportDir.appendingPathComponent("runs", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `Blink.app/Contents/Resources/python/bin/python3`, or the dev-python path
    /// when running unbundled (Phase 2).
    static func pythonBinary(config: Config) -> URL? {
        if let dev = config.devPythonPath {
            return URL(fileURLWithPath: dev)
        }
        let candidate = Bundle.main.resourceURL?
            .appendingPathComponent("python", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("python3")
        if let candidate = candidate,
           FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    /// `Blink.app/Contents/Resources/run_once.py`, etc.
    static var bundledResources: URL? { Bundle.main.resourceURL }

    /// `Blink.app/Contents/Resources/python/app/python/run_once.py`
    static var runOncePath: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("run_once.py")
    }

    static var prepareSourcePath: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("prepare_source.py")
    }

    static var providerPresetsPath: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("provider_presets.json"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
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
