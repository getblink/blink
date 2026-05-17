import Foundation

/// A reference to a staged attachment the model wants to include with a suggestion.
struct AttachmentRef: Equatable, Sendable {
    let id: String
    let reason: String
}

struct SuggestionDetail: Equatable {
    let text: String
    let tags: [String]
    /// Attachments the model selected for this suggestion. Empty means no files.
    let attachments: [AttachmentRef]

    init(text: String, tags: [String] = [], attachments: [AttachmentRef] = []) {
        self.text = text
        self.tags = tags
        self.attachments = attachments
    }

    static func plain(_ text: String) -> SuggestionDetail {
        SuggestionDetail(text: text)
    }
}
