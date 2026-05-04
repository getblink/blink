struct SuggestionChoiceState {
    enum NumberAction: Equatable {
        case expand(Int)
        case copy(Int)
        case focusInput
        case ignored
    }

    enum ReturnAction: Equatable {
        case insert(Int)
        case propagate
    }

    private let suggestionCount: Int
    private let customInputIndex: Int
    private(set) var expandedIndex: Int?
    private(set) var customInputActive: Bool

    init(suggestionCount: Int) {
        self.suggestionCount = max(0, suggestionCount)
        self.customInputIndex = 3
        self.expandedIndex = nil
        self.customInputActive = false
    }

    mutating func pressNumber(index: Int) -> NumberAction {
        if index == customInputIndex {
            expandedIndex = nil
            customInputActive = true
            return .focusInput
        }
        guard index >= 0 && index < suggestionCount else { return .ignored }
        customInputActive = false
        if expandedIndex == index {
            return .copy(index)
        }
        expandedIndex = index
        return .expand(index)
    }

    func pressReturn() -> ReturnAction {
        if customInputActive { return .propagate }
        guard let expandedIndex else { return .propagate }
        return .insert(expandedIndex)
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
