import XCTest
import CoreGraphics
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

        XCTAssertEqual(state.pressNumber(index: 4), .ignored)
        XCTAssertNil(state.expandedIndex)
    }

    func testFourthNumberFocusesCustomInputAndClearsExpansion() {
        var state = SuggestionChoiceState(suggestionCount: 3)

        XCTAssertEqual(state.pressNumber(index: 1), .expand(1))
        XCTAssertEqual(state.pressNumber(index: 3), .focusInput)
        XCTAssertNil(state.expandedIndex)
        XCTAssertTrue(state.customInputActive)
        XCTAssertEqual(state.pressReturn(), .propagate)
    }

    func testSuggestionNumberLeavesCustomInputMode() {
        var state = SuggestionChoiceState(suggestionCount: 3)

        XCTAssertEqual(state.pressNumber(index: 3), .focusInput)
        XCTAssertEqual(state.pressNumber(index: 0), .expand(0))
        XCTAssertFalse(state.customInputActive)
        XCTAssertEqual(state.pressReturn(), .insert(0))
    }

    func testOverlayRouterAcceptsPlainNumberKeys() {
        XCTAssertEqual(
            OverlayKeyRouter.command(forCGKeyCode: 18, flags: [], customInputActive: false),
            .choice(0)
        )
        XCTAssertEqual(
            OverlayKeyRouter.command(forCGKeyCode: 19, flags: [], customInputActive: false),
            .choice(1)
        )
        XCTAssertEqual(
            OverlayKeyRouter.command(forCGKeyCode: 20, flags: [], customInputActive: false),
            .choice(2)
        )
    }

    func testOverlayRouterAcceptsPassiveFlagsForNumberKeys() {
        let passiveFlags: CGEventFlags = [.maskAlphaShift, .maskSecondaryFn, .maskNumericPad, .maskHelp]

        XCTAssertEqual(
            OverlayKeyRouter.command(forCGKeyCode: 18, flags: passiveFlags, customInputActive: false),
            .choice(0)
        )
    }

    func testOverlayRouterBlocksActionModifiersForNumberKeys() {
        let blockingFlags: [CGEventFlags] = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

        for flags in blockingFlags {
            XCTAssertNil(
                OverlayKeyRouter.command(forCGKeyCode: 18, flags: flags, customInputActive: false)
            )
        }
    }

    func testOverlayRouterLetsCustomInputKeepTypingExceptEscape() {
        XCTAssertNil(
            OverlayKeyRouter.command(forCGKeyCode: 18, flags: [], customInputActive: true)
        )
        XCTAssertEqual(
            OverlayKeyRouter.command(forCGKeyCode: 53, flags: [.maskAlphaShift], customInputActive: true),
            .dismiss
        )
    }
}
