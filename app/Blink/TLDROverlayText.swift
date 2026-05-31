import Foundation

struct TLDROverlayText: Equatable {
    let raw: String
    let displayText: String

    init(_ raw: String) {
        self.raw = raw
        self.displayText = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func displayText(for raw: String) -> String {
        TLDROverlayText(raw).displayText
    }
}
