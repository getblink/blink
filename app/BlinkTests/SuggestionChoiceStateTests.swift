import XCTest
import CoreGraphics
@testable import Blink

final class SuggestionChoiceStateTests: XCTestCase {
    func testPrefixStripperRemovesDuplicatedDraftPrefix() {
        XCTAssertEqual(
            SuggestionPrefixStripper.stripDuplicatedDraftPrefix(
                from: "I think we should ship this today",
                draft: "I think we should"
            ),
            "ship this today"
        )
    }

    func testPrefixStripperNormalizesWhitespaceAndCase() {
        XCTAssertEqual(
            SuggestionPrefixStripper.stripDuplicatedDraftPrefix(
                from: "i think   we should ship this today",
                draft: "I think we should"
            ),
            "ship this today"
        )
    }

    func testPrefixStripperLeavesPartialOverlapAlone() {
        XCTAssertEqual(
            SuggestionPrefixStripper.stripDuplicatedDraftPrefix(
                from: "We should ship this today",
                draft: "I think we should"
            ),
            "We should ship this today"
        )
    }

    func testPrefixStripperIgnoresEmptyOrSentinelDraft() {
        XCTAssertEqual(
            SuggestionPrefixStripper.stripDuplicatedDraftPrefix(
                from: "Ship this today",
                draft: "\n"
            ),
            "Ship this today"
        )
    }

    func testNumberPressExpandsBeforeCommittingSameSuggestion() {
        var state = SuggestionChoiceState(suggestionCount: 3)

        XCTAssertEqual(state.pressNumber(index: 0), .expand(0))
        XCTAssertEqual(state.expandedIndex, 0)
        XCTAssertEqual(state.pressNumber(index: 0), .commit(0))
    }

    func testDifferentNumberSwitchesExpandedSuggestion() {
        var state = SuggestionChoiceState(suggestionCount: 3)

        XCTAssertEqual(state.pressNumber(index: 0), .expand(0))
        XCTAssertEqual(state.pressNumber(index: 1), .expand(1))
        XCTAssertEqual(state.expandedIndex, 1)
        XCTAssertEqual(state.pressNumber(index: 1), .commit(1))
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

    func testFourthNumberIgnoredWhenCustomInputDisabled() {
        var state = SuggestionChoiceState(suggestionCount: 0, allowsCustomInput: false)

        XCTAssertEqual(state.pressNumber(index: 3), .ignored)
        XCTAssertFalse(state.customInputActive)
    }

    func testLeavingCustomInputRestoresSuggestionMode() {
        var state = SuggestionChoiceState(suggestionCount: 3)

        XCTAssertEqual(state.pressNumber(index: 3), .focusInput)
        state.setCustomInputActive(false)

        XCTAssertFalse(state.customInputActive)
        XCTAssertEqual(state.pressNumber(index: 0), .expand(0))
        XCTAssertEqual(state.pressReturn(), .insert(0))
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

    func testOverlayRouterLetsCustomInputKeepTypingExceptEscapeAndReturn() {
        XCTAssertNil(
            OverlayKeyRouter.command(forCGKeyCode: 18, flags: [], customInputActive: true)
        )
        XCTAssertEqual(
            OverlayKeyRouter.command(forCGKeyCode: 53, flags: [.maskAlphaShift], customInputActive: true),
            .leaveCustomInput
        )
        XCTAssertEqual(
            OverlayKeyRouter.command(forCGKeyCode: 36, flags: [], customInputActive: true),
            .insertCustomInput
        )
    }

    func testOverlayRouterRoutesCommandEditingShortcutsInCustomInput() {
        XCTAssertEqual(
            OverlayKeyRouter.command(forCGKeyCode: 0, flags: [.maskCommand], customInputActive: true),
            .textEditing(.selectAll)
        )
        XCTAssertEqual(
            OverlayKeyRouter.command(forCGKeyCode: 8, flags: [.maskCommand], customInputActive: true),
            .textEditing(.copy)
        )
        XCTAssertEqual(
            OverlayKeyRouter.command(forCGKeyCode: 9, flags: [.maskCommand], customInputActive: true),
            .textEditing(.paste)
        )
        XCTAssertEqual(
            OverlayKeyRouter.command(forCGKeyCode: 7, flags: [.maskCommand], customInputActive: true),
            .textEditing(.cut)
        )
    }

    func testOverlayRouterDoesNotStealCommandEditingShortcutsOutsideCustomInput() {
        XCTAssertNil(
            OverlayKeyRouter.command(forCGKeyCode: 0, flags: [.maskCommand], customInputActive: false)
        )
    }

    func testOverlayRouterAcceptsCommandRForRerollOutsideCustomInput() {
        XCTAssertEqual(
            OverlayKeyRouter.command(forCGKeyCode: 15, flags: [.maskCommand], customInputActive: false),
            .reroll
        )
    }

    func testOverlayRouterAcceptsCommandRForRerollWhileCustomInputIsActive() {
        XCTAssertEqual(
            OverlayKeyRouter.command(forCGKeyCode: 15, flags: [.maskCommand], customInputActive: true),
            .reroll
        )
    }

    func testOverlayRouterDoesNotAcceptPlainRForReroll() {
        XCTAssertNil(
            OverlayKeyRouter.command(forCGKeyCode: 15, flags: [], customInputActive: false)
        )
    }

    func testOverlayRouterDoesNotAcceptCommandRWithExtraActionModifiers() {
        XCTAssertNil(
            OverlayKeyRouter.command(forCGKeyCode: 15, flags: [.maskCommand, .maskShift], customInputActive: false)
        )
    }

    func testOverlayRouterDoesNotStealRWhileCustomInputIsActive() {
        XCTAssertNil(
            OverlayKeyRouter.command(forCGKeyCode: 15, flags: [], customInputActive: true)
        )
    }
}
