struct SuggestionChoiceState {
    enum NumberAction: Equatable {
        case expand(Int)
        case copy(Int)
        case ignored
    }

    enum ReturnAction: Equatable {
        case insert(Int)
        case propagate
    }

    private let suggestionCount: Int
    private(set) var expandedIndex: Int?

    init(suggestionCount: Int) {
        self.suggestionCount = max(0, suggestionCount)
        self.expandedIndex = nil
    }

    mutating func pressNumber(index: Int) -> NumberAction {
        guard index >= 0 && index < suggestionCount else { return .ignored }
        if expandedIndex == index {
            return .copy(index)
        }
        expandedIndex = index
        return .expand(index)
    }

    func pressReturn() -> ReturnAction {
        guard let expandedIndex else { return .propagate }
        return .insert(expandedIndex)
    }

    mutating func reset() {
        expandedIndex = nil
    }
}
