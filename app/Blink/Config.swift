import Foundation

struct Config {
    let geminiApiKey: String?
    let devPythonPath: String?

    static func load() -> Config {
        Config(
            geminiApiKey: emptyToNil(ProcessInfo.processInfo.environment["GEMINI_API_KEY"]),
            devPythonPath: emptyToNil(
                ProcessInfo.processInfo.environment["BLINK_DEV_PYTHON"]
                    ?? ProcessInfo.processInfo.environment["TLDR_DEV_PYTHON"]
            )
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
            .appendingPathComponent(".blink", isDirectory: true)
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

    static var tccDiagnosticsPath: URL {
        runtimeDir.appendingPathComponent("tcc-diagnostics.log")
    }

    static var runtimeSettingsPath: URL {
        runtimeDir.appendingPathComponent("settings.json")
    }

    static var onboardedPath: URL {
        runtimeDir.appendingPathComponent("onboarded")
    }

    static var firstHotkeyNudgePath: URL {
        runtimeDir.appendingPathComponent("first_hotkey_nudge_shown")
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
        let dir = base.appendingPathComponent("Blink", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var runsDir: URL {
        let dir = appSupportDir.appendingPathComponent("runs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func requiresFirstRunOnboarding(
        runtimeDir: URL = Paths.runtimeDir,
        runsDir: URL = Paths.runsDir
    ) -> Bool {
        // Wizard completion is tracked solely by the `onboarded` marker,
        // which is written only when the user clicks "Get Started" in the
        // first-run wizard. Run history doesn't count — TCC resets and
        // multi-version dogfood sessions can leave runs/ populated while
        // the user has never seen (or completed) the current wizard.
        let onboarded = runtimeDir.appendingPathComponent("onboarded")
        return !FileManager.default.fileExists(atPath: onboarded.path)
    }

    static func markOnboarded(runtimeDir: URL = Paths.runtimeDir) {
        let path = runtimeDir.appendingPathComponent("onboarded")
        try? JSONFiles.isoString().write(to: path, atomically: true, encoding: .utf8)
    }

    static func shouldShowFirstHotkeyNudge(
        runtimeDir: URL = Paths.runtimeDir,
        runsDir: URL = Paths.runsDir
    ) -> Bool {
        let onboarded = runtimeDir.appendingPathComponent("onboarded")
        let nudgeShown = runtimeDir.appendingPathComponent("first_hotkey_nudge_shown")
        guard FileManager.default.fileExists(atPath: onboarded.path),
              !FileManager.default.fileExists(atPath: nudgeShown.path) else {
            return false
        }
        let runNames = (try? FileManager.default.contentsOfDirectory(
            atPath: runsDir.path
        )) ?? []
        return runNames.isEmpty
    }

    static func markFirstHotkeyNudgeShown(runtimeDir: URL = Paths.runtimeDir) {
        let path = runtimeDir.appendingPathComponent("first_hotkey_nudge_shown")
        try? JSONFiles.isoString().write(to: path, atomically: true, encoding: .utf8)
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

    static var blinkOncePath: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("blink_once.py")
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

enum TCCDiagnostics {
    static func log(_ message: String) {
        let line = "\(JSONFiles.isoString()) BlinkTCC: \(message)\n"
        NSLog("%@", line.trimmingCharacters(in: .newlines))
        let path = Paths.tccDiagnosticsPath
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: path.path),
           let handle = try? FileHandle(forWritingTo: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: path, options: .atomic)
        }
    }
}

enum DeviceTokenManager {
    static func mintIfNeeded(proxyConfig: ProxyConfig?) {
        guard Paths.loadDeviceToken() == nil else { return }
        guard let proxyConfig else {
            TCCDiagnostics.log("mint_skipped reason=no_proxy_config")
            return
        }
        let installID = Paths.loadOrCreateInstallID()
        guard let body = try? JSONSerialization.data(
            withJSONObject: ["install_id": installID],
            options: []
        ) else {
            TCCDiagnostics.log("mint_skipped reason=request_body_serialization_failed install_id=\(installID)")
            return
        }

        let mintURL = proxyConfig.baseURL.appendingPathComponent("v1/auth/mint")
        var request = URLRequest(url: mintURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(proxyConfig.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        TCCDiagnostics.log("mint_request url=\(mintURL.absoluteString) install_id=\(installID)")

        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, error in
            if let error {
                TCCDiagnostics.log("mint_failed reason=transport_error error=\(error.localizedDescription)")
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                TCCDiagnostics.log("mint_failed reason=non_http_response")
                return
            }
            // Bound the body slice we log: proxy errors are short JSON
            // ("invalid bootstrap token", "device token storage unavailable"),
            // and successful responses contain a token we don't want to log.
            let bodySnippet: String = {
                guard let data, let s = String(data: data, encoding: .utf8) else { return "<no-body>" }
                return String(s.prefix(200))
            }()
            guard (200 ..< 300).contains(httpResponse.statusCode) else {
                TCCDiagnostics.log("mint_failed reason=http_status status=\(httpResponse.statusCode) body=\(bodySnippet)")
                return
            }
            guard let data,
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                TCCDiagnostics.log("mint_failed reason=response_not_json status=\(httpResponse.statusCode) body=\(bodySnippet)")
                return
            }
            guard let token = payload["token"] as? String, token.hasPrefix("tldr_dt_") else {
                TCCDiagnostics.log("mint_failed reason=token_field_invalid status=\(httpResponse.statusCode)")
                return
            }
            do {
                try Paths.saveDeviceToken(token)
                TCCDiagnostics.log("mint_succeeded install_id=\(installID)")
            } catch {
                TCCDiagnostics.log("mint_failed reason=save_failed error=\(error.localizedDescription)")
            }
        }.resume()
    }
}
