import Foundation

struct TLDROverlayText: Equatable {
    let raw: String
    let collapsed: String
    let expanded: String?

    var displayText: String {
        if let expanded, !expanded.isEmpty {
            return [collapsed, expanded]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        }
        return collapsed
    }

    init(_ raw: String) {
        self.raw = raw
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let nsText = normalized as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let matches = Self.separatorRegex.matches(in: normalized, range: range)

        guard !matches.isEmpty else {
            self.collapsed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
            self.expanded = nil
            return
        }

        var parts: [String] = []
        var cursor = 0
        for match in matches {
            let partRange = NSRange(location: cursor, length: match.range.location - cursor)
            parts.append(nsText.substring(with: partRange))
            cursor = match.range.location + match.range.length
        }
        if cursor <= nsText.length {
            parts.append(nsText.substring(from: cursor))
        }

        let trimmedParts = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        self.collapsed = trimmedParts.first ?? ""
        let expandedParts = trimmedParts.dropFirst()
        self.expanded = expandedParts.isEmpty ? nil : expandedParts.joined(separator: "\n\n")
    }

    static func displayText(for raw: String) -> String {
        TLDROverlayText(raw).displayText
    }

    private static let separatorRegex = try! NSRegularExpression(
        pattern: #"\n[ \t]*\n[ \t]*---[ \t]*\n[ \t]*\n"#,
        options: []
    )
}
