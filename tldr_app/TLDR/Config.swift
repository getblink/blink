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

    static var deviceTokenPath: URL {
        runtimeDir.appendingPathComponent("device_token")
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

    static func loadDeviceToken() -> String? {
        guard let existing = try? String(contentsOf: deviceTokenPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !existing.isEmpty else {
            return nil
        }
        return existing
    }

    static func saveDeviceToken(_ token: String) throws {
        try token.write(to: deviceTokenPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: deviceTokenPath.path
        )
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

enum DeviceTokenManager {
    static func mintIfNeeded(proxyConfig: ProxyConfig?) {
        guard Paths.loadDeviceToken() == nil, let proxyConfig else { return }
        let installID = Paths.loadOrCreateInstallID()
        guard let body = try? JSONSerialization.data(
            withJSONObject: ["install_id": installID],
            options: []
        ) else {
            return
        }

        var request = URLRequest(url: proxyConfig.baseURL.appendingPathComponent("v1/auth/mint"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(proxyConfig.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, error in
            guard error == nil,
                  let httpResponse = response as? HTTPURLResponse,
                  (200 ..< 300).contains(httpResponse.statusCode),
                  let data,
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = payload["token"] as? String,
                  token.hasPrefix("tldr_dt_") else {
                return
            }
            try? Paths.saveDeviceToken(token)
        }.resume()
    }
}
