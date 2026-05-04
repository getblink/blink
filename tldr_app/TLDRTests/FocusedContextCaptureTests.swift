import XCTest
@testable import TLDR

final class FocusedContextCaptureTests: XCTestCase {
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
}
