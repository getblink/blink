import Foundation

struct TLDROverlayText: Equatable {
    static let showMoreText = "Show more"

    let raw: String
    let displayText: String
    let collapsedText: String
    let isCollapsedAtParagraphBreak: Bool

    init(_ raw: String) {
        self.raw = raw
        let displayText = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayText = displayText
        let preview = Self.paragraphPreview(for: displayText)
        self.collapsedText = preview.text
        self.isCollapsedAtParagraphBreak = preview.isCollapsed
    }

    static func displayText(for raw: String) -> String {
        TLDROverlayText(raw).displayText
    }

    var collapsedDisplayText: String {
        guard isCollapsedAtParagraphBreak else { return displayText }
        return collapsedText + "\n\n" + Self.showMoreText
    }

    /// Collapse the summary to its first two paragraphs. A TL;DR with one or
    /// two paragraphs shows in full (no "Show more"); three or more collapses
    /// to the first two with the affordance appended.
    private static func paragraphPreview(for text: String) -> (text: String, isCollapsed: Bool) {
        let pattern = #"\n[ \t]*\n"#
        guard let firstBreak = text.range(of: pattern, options: .regularExpression) else {
            return (text, false)
        }
        let firstParagraph = String(text[..<firstBreak.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let afterFirst = String(text[firstBreak.upperBound...])

        guard let secondBreak = afterFirst.range(of: pattern, options: .regularExpression) else {
            // Two paragraphs at most — show everything.
            return (text, false)
        }
        let secondParagraph = String(afterFirst[..<secondBreak.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = String(afterFirst[secondBreak.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !firstParagraph.isEmpty, !secondParagraph.isEmpty, !remainder.isEmpty else {
            return (text, false)
        }
        return (firstParagraph + "\n\n" + secondParagraph, true)
    }
}
