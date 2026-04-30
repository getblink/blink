import XCTest
@testable import TLDR

final class FocusedContextCaptureTests: XCTestCase {
    func testSanitizeForUploadRedactsContentWithoutOptIn() {
        let payload: [String: Any] = [
            "role": "TextArea",
            "value": "draft reply",
            "selected_text": "reply",
            "nearby_relevant_text": "draft reply to a teammate",
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
