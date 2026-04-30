import Foundation

struct ProxyConfig {
    let baseURL: URL
    let token: String
}

enum RuntimeEnvironment {
    static func proxyConfig() -> ProxyConfig? {
        let env = mergedEnvironment()
        let rawURL = (env["BLINK_PROXY_URL"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let token = (env["BLINK_PROXY_TOKEN"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawURL.isEmpty, !token.isEmpty, let url = URL(string: rawURL) else {
            return nil
        }
        return ProxyConfig(baseURL: url, token: token)
    }

    private static func mergedEnvironment() -> [String: String] {
        var result = ProcessInfo.processInfo.environment
        for path in [Paths.runtimeDir.appendingPathComponent(".env"), Paths.runtimeDir.appendingPathComponent(".env.local")] {
            guard let text = try? String(contentsOf: path, encoding: .utf8) else { continue }
            for rawLine in text.split(whereSeparator: \.isNewline) {
                guard let parsed = parseEnvLine(String(rawLine)) else { continue }
                if result[parsed.key] == nil {
                    result[parsed.key] = parsed.value
                }
            }
        }
        return result
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
}
