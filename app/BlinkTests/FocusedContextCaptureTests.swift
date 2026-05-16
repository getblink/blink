import AppKit
import ApplicationServices
import XCTest
@testable import Blink

final class FocusedContextCaptureTests: XCTestCase {
    func testPasteTargetDecisionAcceptsTextRoles() {
        XCTAssertEqual(
            FocusedContextCapture.textTargetDecision(focusedRole: "AXTextArea", descendantRoles: []),
            .textTarget
        )
        XCTAssertEqual(
            FocusedContextCapture.textTargetDecision(focusedRole: "AXTextField", descendantRoles: []),
            .textTarget
        )
        XCTAssertEqual(
            FocusedContextCapture.textTargetDecision(focusedRole: "AXSearchField", descendantRoles: []),
            .textTarget
        )
        XCTAssertEqual(
            FocusedContextCapture.textTargetDecision(focusedRole: "AXComboBox", descendantRoles: []),
            .textTarget
        )
        XCTAssertEqual(
            FocusedContextCapture.textTargetDecision(focusedRole: "AXGroup", descendantRoles: ["AXTextField"]),
            .textTarget
        )
    }

    func testPasteTargetDecisionTreatsNonTextRolesAsConfidentSkip() {
        XCTAssertEqual(
            FocusedContextCapture.textTargetDecision(focusedRole: "AXButton", descendantRoles: []),
            .confidentNoTextTarget
        )
        // Containers with no text-input descendant are now treated as
        // confident-no-text-target — caret resolution is the truth signal,
        // and a container with no inputs is strong evidence ⌘V has nowhere
        // to land.
        XCTAssertEqual(
            FocusedContextCapture.textTargetDecision(focusedRole: "AXWebArea", descendantRoles: []),
            .confidentNoTextTarget
        )
        XCTAssertEqual(
            FocusedContextCapture.textTargetDecision(focusedRole: "AXGroup", descendantRoles: []),
            .confidentNoTextTarget
        )
        // Roles that used to fall through to an indeterminate result
        // (link, heading, custom/unknown) now skip with a fallback toast.
        XCTAssertEqual(
            FocusedContextCapture.textTargetDecision(focusedRole: "AXLink", descendantRoles: []),
            .confidentNoTextTarget
        )
        XCTAssertEqual(
            FocusedContextCapture.textTargetDecision(focusedRole: "AXHeading", descendantRoles: []),
            .confidentNoTextTarget
        )
        XCTAssertEqual(
            FocusedContextCapture.textTargetDecision(focusedRole: nil, descendantRoles: []),
            .confidentNoTextTarget
        )
    }

    func testMeaningfulTextTreatsEmptyAndWhitespaceAsNoDraft() {
        XCTAssertNil(FocusedContextCapture.meaningfulText(""))
        XCTAssertNil(FocusedContextCapture.meaningfulText("\n"))
        XCTAssertNil(FocusedContextCapture.meaningfulText(" \t\n "))
    }

    func testMeaningfulTextPreservesRealDraft() {
        XCTAssertEqual(FocusedContextCapture.meaningfulText("  I think we should ship this\n"), "I think we should ship this")
    }

    func testSanitizeForUploadPreservesMeaningfulDraftMetadataWhenRedacted() {
        let payload: [String: Any] = [
            "value": "\n",
            "draft_present": false,
            "meaningful_value_char_count": 0,
        ]

        let sanitized = FocusedContextCapture.sanitizeForUpload(
            payload,
            allowContentRetention: false
        )

        XCTAssertNil(sanitized["value"])
        XCTAssertEqual(sanitized["value_redacted"] as? Bool, true)
        XCTAssertEqual(sanitized["value_char_count"] as? Int, 1)
        XCTAssertEqual(sanitized["meaningful_value_char_count"] as? Int, 0)
        XCTAssertEqual(sanitized["draft_present"] as? Bool, false)
    }

    func testSanitizeForUploadRedactsContentWithoutOptIn() {
        let payload: [String: Any] = [
            "role": "TextArea",
            "value": "draft reply",
            "selected_text": "reply",
            "nearby_relevant_text": "draft reply to a teammate",
            "draft_present": true,
            "meaningful_value_char_count": 11,
        ]

        let sanitized = FocusedContextCapture.sanitizeForUpload(
            payload,
            allowContentRetention: false
        )

        XCTAssertNil(sanitized["value"])
        XCTAssertNil(sanitized["selected_text"])
        XCTAssertNil(sanitized["nearby_relevant_text"])
        XCTAssertEqual(sanitized["value_redacted"] as? Bool, true)
        XCTAssertEqual(sanitized["selected_text_redacted"] as? Bool, true)
        XCTAssertEqual(sanitized["nearby_relevant_text_redacted"] as? Bool, true)
        XCTAssertEqual(sanitized["value_char_count"] as? Int, 11)
        XCTAssertEqual(sanitized["selected_text_char_count"] as? Int, 5)
        XCTAssertEqual(sanitized["draft_present"] as? Bool, true)
        XCTAssertEqual(sanitized["meaningful_value_char_count"] as? Int, 11)
    }

    func testSanitizeForUploadBoundsRetainedContent() {
        let longValue = String(repeating: "a", count: 1205)
        let payload: [String: Any] = [
            "value": longValue,
        ]

        let sanitized = FocusedContextCapture.sanitizeForUpload(
            payload,
            allowContentRetention: true
        )

        XCTAssertEqual((sanitized["value"] as? String)?.count, 1000)
        XCTAssertEqual(sanitized["value_char_count"] as? Int, 1205)
        XCTAssertEqual(sanitized["value_truncated"] as? Bool, true)
        XCTAssertNil(sanitized["value_redacted"])
    }

    // MARK: - Caret slicing

    func testCaretSlicesReturnNilWhenInputsMissing() {
        let none = FocusedContextCapture.caretSlices(
            value: nil,
            selectedRange: nil,
            prefixLimit: 200,
            suffixLimit: 100
        )
        XCTAssertNil(none.prefix)
        XCTAssertNil(none.suffix)
    }

    func testCaretSlicesReturnsPrefixAndSuffixForPlainAscii() {
        let value = "hello world"
        let range = CFRange(location: 5, length: 0) // caret between "hello" and " world"
        let slices = FocusedContextCapture.caretSlices(
            value: value,
            selectedRange: range,
            prefixLimit: 200,
            suffixLimit: 100
        )
        XCTAssertEqual(slices.prefix, "hello")
        XCTAssertEqual(slices.suffix, " world")
    }

    func testCaretSlicesRespectsLimitsByUTF16CodeUnits() {
        let value = String(repeating: "a", count: 1000)
        let range = CFRange(location: 500, length: 0)
        let slices = FocusedContextCapture.caretSlices(
            value: value,
            selectedRange: range,
            prefixLimit: 50,
            suffixLimit: 30
        )
        XCTAssertEqual(slices.prefix?.count, 50)
        XCTAssertEqual(slices.suffix?.count, 30)
    }

    func testCaretSlicesHandlesCaretAtStart() {
        let value = "hello world"
        let range = CFRange(location: 0, length: 0)
        let slices = FocusedContextCapture.caretSlices(
            value: value,
            selectedRange: range,
            prefixLimit: 200,
            suffixLimit: 100
        )
        XCTAssertNil(slices.prefix)
        XCTAssertEqual(slices.suffix, "hello world")
    }

    func testCaretSlicesHandlesCaretAtEnd() {
        let value = "hello world"
        let range = CFRange(location: 11, length: 0)
        let slices = FocusedContextCapture.caretSlices(
            value: value,
            selectedRange: range,
            prefixLimit: 200,
            suffixLimit: 100
        )
        XCTAssertEqual(slices.prefix, "hello world")
        XCTAssertNil(slices.suffix)
    }

    func testCaretSlicesSkipsRangeOutOfBounds() {
        let value = "short"
        // location past end — selected_range stale relative to value
        let range = CFRange(location: 99, length: 0)
        let slices = FocusedContextCapture.caretSlices(
            value: value,
            selectedRange: range,
            prefixLimit: 200,
            suffixLimit: 100
        )
        XCTAssertNil(slices.prefix)
        XCTAssertNil(slices.suffix)
    }

    func testCaretSlicesHandlesEmojiSurrogatePairBoundary() {
        // "Hi 👋!" — 👋 is U+1F44B, encoded as a surrogate pair in UTF-16.
        // "Hi " is 3 code units, the pair is 2, "!" is 1, total 6.
        // Caret at UTF-16 offset 4 lands mid-surrogate-pair. We expect
        // the prefix to start at offset 0 and end at offset 4 (which
        // means the slice ends inside the surrogate pair) — String
        // decoding with U+FFFD replacement keeps it valid instead of
        // crashing.
        let value = "Hi 👋!"
        let range = CFRange(location: 4, length: 0)
        let slices = FocusedContextCapture.caretSlices(
            value: value,
            selectedRange: range,
            prefixLimit: 200,
            suffixLimit: 100
        )
        XCTAssertNotNil(slices.prefix)
        XCTAssertNotNil(slices.suffix)
    }

    func testCaretSlicesPropagatesThroughSanitizeRedaction() {
        let payload: [String: Any] = [
            "value": "the draft",
            "caret_prefix": "the",
            "caret_suffix": " draft",
        ]
        let redacted = FocusedContextCapture.sanitizeForUpload(
            payload,
            allowContentRetention: false
        )
        XCTAssertNil(redacted["caret_prefix"])
        XCTAssertNil(redacted["caret_suffix"])
        XCTAssertEqual(redacted["caret_prefix_redacted"] as? Bool, true)
        XCTAssertEqual(redacted["caret_suffix_redacted"] as? Bool, true)

        let retained = FocusedContextCapture.sanitizeForUpload(
            payload,
            allowContentRetention: true
        )
        XCTAssertEqual(retained["caret_prefix"] as? String, "the")
        XCTAssertEqual(retained["caret_suffix"] as? String, " draft")
    }

    // MARK: - Source confidence

    func testSourceConfidenceTerminalBundlesGetTerminalNone() {
        let result = FocusedContextCapture.deriveSourceConfidence(
            bundleID: "com.apple.Terminal",
            role: "TextArea",
            valueLength: 42,
            selectedRange: CFRange(location: 10, length: 0)
        )
        XCTAssertEqual(result, "terminal_none")
    }

    func testSourceConfidenceChromiumInputVsContentEditable() {
        let input = FocusedContextCapture.deriveSourceConfidence(
            bundleID: "com.google.Chrome",
            role: "TextField",
            valueLength: 20,
            selectedRange: CFRange(location: 5, length: 0)
        )
        XCTAssertEqual(input, "chromium_input")

        // contentEditable shows up as AXGroup / AXWebArea, not a text-input role
        let editable = FocusedContextCapture.deriveSourceConfidence(
            bundleID: "com.google.Chrome",
            role: "Group",
            valueLength: 20,
            selectedRange: CFRange(location: 5, length: 0)
        )
        XCTAssertEqual(editable, "chromium_contenteditable")
    }

    func testSourceConfidenceChromiumPrefixesMatchKnownBrowsers() {
        // Channel-suffixed Chrome (Canary) and Arc (com.thebrowser.Browser)
        // both need to be detected via prefix match.
        let canary = FocusedContextCapture.deriveSourceConfidence(
            bundleID: "com.google.Chrome.canary",
            role: "TextField",
            valueLength: 5,
            selectedRange: CFRange(location: 2, length: 0)
        )
        XCTAssertEqual(canary, "chromium_input")

        let arc = FocusedContextCapture.deriveSourceConfidence(
            bundleID: "com.thebrowser.Browser",
            role: "TextField",
            valueLength: 5,
            selectedRange: CFRange(location: 2, length: 0)
        )
        XCTAssertEqual(arc, "chromium_input")
    }

    func testSourceConfidenceElectronPartialFlaggedWhenSelectionPinnedAtOrigin() {
        // Slack desktop: bundle isn't in our terminal or Chromium set,
        // value is non-trivial, selection comes back as {0,0}.
        let result = FocusedContextCapture.deriveSourceConfidence(
            bundleID: "com.tinyspeck.slackmacgap",
            role: "TextArea",
            valueLength: 50,
            selectedRange: CFRange(location: 0, length: 0)
        )
        XCTAssertEqual(result, "electron_partial")
    }

    func testSourceConfidenceShortValuesAtZeroStayNative() {
        // Below the 16-char floor: a native AppKit field with a short
        // prefilled value at caret-0 (e.g. tabbing into a search bar)
        // must not get misclassified as electron_partial — that would
        // suppress the caret marker on a perfectly valid native input.
        let result = FocusedContextCapture.deriveSourceConfidence(
            bundleID: "com.apple.Safari",
            role: "TextField",
            valueLength: 12,
            selectedRange: CFRange(location: 0, length: 0)
        )
        XCTAssertEqual(result, "native_ax")
    }

    func testSourceConfidenceNativeAxForNativeTextInputWithRealSelection() {
        let result = FocusedContextCapture.deriveSourceConfidence(
            bundleID: "com.apple.Notes",
            role: "TextArea",
            valueLength: 42,
            selectedRange: CFRange(location: 10, length: 0)
        )
        XCTAssertEqual(result, "native_ax")
    }

    func testSourceConfidenceUnknownForNonTextRoleNoBundle() {
        let result = FocusedContextCapture.deriveSourceConfidence(
            bundleID: nil,
            role: "Group",
            valueLength: 0,
            selectedRange: nil
        )
        XCTAssertEqual(result, "unknown")
    }

    // MARK: - AX bounds flip

    func testAxBoundsToScreenFlipsAroundPrimaryHeight() throws {
        // Skip when no display is attached (CI / headless).
        guard let primaryHeight = NSScreen.screens.first?.frame.height else {
            throw XCTSkip("No primary screen attached.")
        }
        let rawAX = CGRect(x: 100, y: 50, width: 200, height: 30)
        let flipped = FocusedContextCapture.axBoundsToScreen(rawAX)
        XCTAssertNotNil(flipped)
        // Top edge (rawAX.y = 50, height 30 → bottom in AX is at y=80)
        // becomes (primaryHeight - 80) in AppKit-screen.
        XCTAssertEqual(flipped!.origin.x, 100, accuracy: 0.001)
        XCTAssertEqual(flipped!.origin.y, primaryHeight - 80, accuracy: 0.001)
        XCTAssertEqual(flipped!.size.width, 200, accuracy: 0.001)
        XCTAssertEqual(flipped!.size.height, 30, accuracy: 0.001)
    }
}
