import Foundation

struct ProxyConfig {
    let baseURL: URL
    let token: String
}

/// Where the overlay (loading state + result card) is positioned on screen.
/// `centered` is the historical behavior. The window-anchored modes use the
/// captured window's frame so the loading indicator stays out of the reading
/// area while the user scans the source content. Switched via
/// `BLINK_LOADING_PLACEMENT` so the three approaches can be compared without
/// a rebuild — see `RuntimeEnvironment.loadingPlacement()`.
enum LoadingPlacement: String {
    case centered
    case windowSide
    case windowCorner
}

enum RuntimeEnvironment {
    static func proxyConfig() -> ProxyConfig? {
        proxyConfig(preferDeviceToken: true)
    }

    static func bootstrapProxyConfig() -> ProxyConfig? {
        proxyConfig(preferDeviceToken: false)
    }

    private static func proxyConfig(preferDeviceToken: Bool) -> ProxyConfig? {
        let env = mergedEnvironment()
        guard !proxyDisabled(in: env) else {
            return nil
        }
        let rawURL = (env["BLINK_PROXY_URL"] ?? env["TLDR_PROXY_URL"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let bundledToken = (env["BLINK_PROXY_TOKEN"] ?? env["TLDR_PROXY_TOKEN"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let token = (preferDeviceToken ? Paths.loadDeviceToken() : nil) ?? bundledToken
        guard !rawURL.isEmpty, !token.isEmpty, let url = URL(string: rawURL) else {
            return nil
        }
        return ProxyConfig(baseURL: url, token: token)
    }

    static func mergedEnvironment() -> [String: String] {
        var result = ProcessInfo.processInfo.environment
        for path in [Paths.runtimeDir.appendingPathComponent(".env"), Paths.runtimeDir.appendingPathComponent(".env.local")] {
            guard let text = try? String(contentsOf: path, encoding: .utf8) else { continue }
            mergeEnvText(text, into: &result)
        }
        if let bundledProxy = Paths.bundledResource(named: "proxy.env"),
           let text = try? String(contentsOf: bundledProxy, encoding: .utf8) {
            mergeEnvText(text, into: &result)
        }
        return result
    }

    static func mergeEnvText(_ text: String, into result: inout [String: String]) {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            guard let parsed = parseEnvLine(String(rawLine)) else { continue }
            if result[parsed.key] == nil {
                result[parsed.key] = parsed.value
            }
        }
    }

    private static func parseEnvLine(_ rawLine: String) -> (key: String, value: String)? {
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
        if line.hasPrefix("export ") {
            line = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let key = String(line[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
        var value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        if value.count >= 2, let first = value.first, let last = value.last, first == last, first == "\"" || first == "'" {
            value.removeFirst()
            value.removeLast()
        }
        return (key, value)
    }

    static func proxyDisabled(in env: [String: String]) -> Bool {
        isTruthy(env["BLINK_DISABLE_PROXY"]) || isTruthy(env["TLDR_DISABLE_PROXY"])
    }

    /// Force the legacy NSVisualEffectView fallback in the overlay even when
    /// running on macOS 26+ where NSGlassEffectView is available. Used to
    /// dogfood the non-liquid-glass UI path on a liquid-glass machine.
    static func forceLegacyGlass() -> Bool {
        let env = mergedEnvironment()
        return isTruthy(env["BLINK_FORCE_LEGACY_GLASS"]) || isTruthy(env["TLDR_FORCE_LEGACY_GLASS"])
    }

    /// Overlay placement, read fresh so editing `.env.local` and triggering a
    /// new capture picks up the change without a rebuild. Unknown / unset
    /// values fall back to `.centered` (the shipped behavior), so the
    /// window-anchored modes are strictly opt-in.
    static func loadingPlacement() -> LoadingPlacement {
        let env = mergedEnvironment()
        let raw = (env["BLINK_LOADING_PLACEMENT"] ?? env["TLDR_LOADING_PLACEMENT"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch raw {
        case "corner", "windowcorner", "window_corner":
            return .windowCorner
        case "side", "windowside", "window_side":
            return .windowSide
        default:
            return .centered
        }
    }

    /// Opt into the Liquid Glass capture-loading animation (a clear lens over the
    /// captured window that drains into a glass "Reading…" pill) in place of the
    /// default corner puck. Read fresh each capture; unset = off.
    static func glassLoadingEnabled() -> Bool {
        let env = mergedEnvironment()
        return isTruthy(env["BLINK_GLASS_LOADING"]) || isTruthy(env["TLDR_GLASS_LOADING"])
    }

    private static func isTruthy(_ value: String?) -> Bool {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }
}
