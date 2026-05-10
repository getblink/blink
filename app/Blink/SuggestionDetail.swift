import Foundation

struct SuggestionDetail: Equatable {
    let text: String
    let tags: [String]

    init(text: String, tags: [String] = []) {
        self.text = text
        self.tags = tags
    }

    static func plain(_ text: String) -> SuggestionDetail {
        SuggestionDetail(text: text)
    }
}
