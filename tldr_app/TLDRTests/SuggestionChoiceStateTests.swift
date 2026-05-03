import XCTest
@testable import TLDR

final class SuggestionChoiceStateTests: XCTestCase {
    func testNumberPressExpandsBeforeCopyingSameSuggestion() {
        var state = SuggestionChoiceState(suggestionCount: 3)

        XCTAssertEqual(state.pressNumber(index: 0), .expand(0))
        XCTAssertEqual(state.expandedIndex, 0)
        XCTAssertEqual(state.pressNumber(index: 0), .copy(0))
    }

    func testDifferentNumberSwitchesExpandedSuggestion() {
        var state = SuggestionChoiceState(suggestionCount: 3)

        XCTAssertEqual(state.pressNumber(index: 0), .expand(0))
        XCTAssertEqual(state.pressNumber(index: 1), .expand(1))
        XCTAssertEqual(state.expandedIndex, 1)
        XCTAssertEqual(state.pressNumber(index: 1), .copy(1))
    }

    func testReturnPropagatesUntilSuggestionIsExpanded() {
        var state = SuggestionChoiceState(suggestionCount: 3)

        XCTAssertEqual(state.pressReturn(), .propagate)
        XCTAssertEqual(state.pressNumber(index: 2), .expand(2))
        XCTAssertEqual(state.pressReturn(), .insert(2))
    }

    func testInvalidNumberIsIgnored() {
        var state = SuggestionChoiceState(suggestionCount: 2)

        XCTAssertEqual(state.pressNumber(index: 2), .ignored)
        XCTAssertNil(state.expandedIndex)
    }
}
