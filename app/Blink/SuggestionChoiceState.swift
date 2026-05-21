struct SuggestionChoiceState {
    enum NumberAction: Equatable {
        case expand(Int)
        case commit(Int)
        case focusInput
        case ignored
    }

    enum ReturnAction: Equatable {
        case insert(Int)
        case propagate
    }

    enum Direction {
        case up
        case down
    }

    private let suggestionCount: Int
    private let customInputIndex: Int
    private let allowsCustomInput: Bool
    private(set) var expandedIndex: Int?
    private(set) var customInputActive: Bool

    init(suggestionCount: Int, allowsCustomInput: Bool = true) {
        self.suggestionCount = max(0, suggestionCount)
        self.customInputIndex = 3
        self.allowsCustomInput = allowsCustomInput
        self.expandedIndex = nil
        self.customInputActive = false
    }

    mutating func pressNumber(index: Int) -> NumberAction {
        if index == customInputIndex {
            guard allowsCustomInput else { return .ignored }
            expandedIndex = nil
            customInputActive = true
            return .focusInput
        }
        guard index >= 0 && index < suggestionCount else { return .ignored }
        customInputActive = false
        if expandedIndex == index {
            return .commit(index)
        }
        expandedIndex = index
        return .expand(index)
    }

    func pressReturn(insertsFirstIfNone: Bool = false) -> ReturnAction {
        if customInputActive { return .propagate }
        if let expandedIndex {
            return .insert(expandedIndex)
        }
        if insertsFirstIfNone, suggestionCount > 0 {
            return .insert(0)
        }
        return .propagate
    }

    mutating func moveSelection(_ direction: Direction, navigableCount: Int) -> Int? {
        guard navigableCount > 0 else { return nil }
        if customInputActive { return nil }
        let next: Int
        if let current = expandedIndex {
            switch direction {
            case .down:
                next = (current + 1) % navigableCount
            case .up:
                next = (current - 1 + navigableCount) % navigableCount
            }
        } else {
            switch direction {
            case .down:
                next = 0
            case .up:
                next = navigableCount - 1
            }
        }
        expandedIndex = next
        return next
    }

    mutating func setCustomInputActive(_ active: Bool) {
        customInputActive = active
        if active {
            expandedIndex = nil
        }
    }

    mutating func reset() {
        expandedIndex = nil
        customInputActive = false
    }
}

enum SuggestionPrefixStripper {
    static func stripDuplicatedDraftPrefix(
        from suggestion: String,
        draft: String?
    ) -> String {
        let original = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty,
              let draft = FocusedContextCapture.meaningfulText(draft)
        else {
            return original
        }

        let normalizedSuggestion = normalized(original)
        let normalizedDraft = normalized(draft)
        guard !normalizedDraft.isEmpty,
              normalizedSuggestion.hasPrefix(normalizedDraft)
        else {
            return original
        }

        let stripped = stripPrefixByNormalizedWords(original: original, draft: draft)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? original : stripped
    }

    private static func normalized(_ value: String) -> String {
        value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    private static func stripPrefixByNormalizedWords(original: String, draft: String) -> String {
        var originalIndex = original.startIndex
        var draftIndex = draft.startIndex

        while draftIndex < draft.endIndex {
            while originalIndex < original.endIndex, original[originalIndex].isWhitespace {
                originalIndex = original.index(after: originalIndex)
            }
            while draftIndex < draft.endIndex, draft[draftIndex].isWhitespace {
                draftIndex = draft.index(after: draftIndex)
            }
            guard draftIndex < draft.endIndex else { break }
            guard originalIndex < original.endIndex,
                  String(original[originalIndex]).lowercased() == String(draft[draftIndex]).lowercased()
            else {
                return original
            }
            originalIndex = original.index(after: originalIndex)
            draftIndex = draft.index(after: draftIndex)
        }
        return String(original[originalIndex...])
    }
}
