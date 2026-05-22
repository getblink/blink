struct SuggestionChoiceState {
    enum NumberAction: Equatable {
        case expand(Int)
        case commit(Int)
        case focusInput
        case ignored
    }

    enum ReturnAction: Equatable {
        case insert(Int)
        case focusCustomInput
        case propagate
    }

    enum Direction {
        case up
        case down
    }

    enum Slot: Equatable {
        case suggestion(Int)
        case customInput
    }

    private let suggestionCount: Int
    private let customInputIndex: Int
    private let allowsCustomInput: Bool
    private(set) var expandedIndex: Int?
    private(set) var customInputActive: Bool
    private(set) var customInputArmed: Bool

    init(suggestionCount: Int, allowsCustomInput: Bool = true) {
        self.suggestionCount = max(0, suggestionCount)
        self.customInputIndex = 3
        self.allowsCustomInput = allowsCustomInput
        self.expandedIndex = nil
        self.customInputActive = false
        self.customInputArmed = false
    }

    mutating func pressNumber(index: Int) -> NumberAction {
        if index == customInputIndex {
            guard allowsCustomInput else { return .ignored }
            expandedIndex = nil
            customInputArmed = false
            customInputActive = true
            return .focusInput
        }
        guard index >= 0 && index < suggestionCount else { return .ignored }
        customInputActive = false
        customInputArmed = false
        if expandedIndex == index {
            return .commit(index)
        }
        expandedIndex = index
        return .expand(index)
    }

    func pressReturn(insertsFirstIfNone: Bool = false) -> ReturnAction {
        if customInputActive { return .propagate }
        if customInputArmed { return .focusCustomInput }
        if let expandedIndex {
            return .insert(expandedIndex)
        }
        if insertsFirstIfNone, suggestionCount > 0 {
            return .insert(0)
        }
        return .propagate
    }

    /// Arrow navigation cycles through suggestion cards 0..<navigableSuggestionCount,
    /// then (when allowsCustomInput) the custom-input slot, then wraps. Landing on
    /// the custom-input slot arms it (visual highlight) without entering edit mode —
    /// pressReturn then escalates armed → focusCustomInput.
    mutating func moveSelection(_ direction: Direction, navigableSuggestionCount: Int) -> Slot? {
        if customInputActive { return nil }
        let suggestions = max(0, navigableSuggestionCount)
        let total = suggestions + (allowsCustomInput ? 1 : 0)
        guard total > 0 else { return nil }

        let currentPos: Int?
        if customInputArmed {
            currentPos = suggestions
        } else if let e = expandedIndex {
            currentPos = e
        } else {
            currentPos = nil
        }
        let next: Int
        if let cur = currentPos {
            switch direction {
            case .down: next = (cur + 1) % total
            case .up:   next = (cur - 1 + total) % total
            }
        } else {
            switch direction {
            case .down: next = 0
            case .up:   next = total - 1
            }
        }
        if allowsCustomInput && next == suggestions {
            customInputArmed = true
            expandedIndex = nil
            return .customInput
        }
        customInputArmed = false
        expandedIndex = next
        return .suggestion(next)
    }

    mutating func setCustomInputActive(_ active: Bool) {
        customInputActive = active
        if active {
            expandedIndex = nil
            customInputArmed = false
        }
    }

    mutating func clearCustomInputArmed() {
        customInputArmed = false
    }

    mutating func reset() {
        expandedIndex = nil
        customInputActive = false
        customInputArmed = false
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
