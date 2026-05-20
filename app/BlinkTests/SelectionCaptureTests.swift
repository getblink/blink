import XCTest
@testable import Blink

final class SelectionCaptureTests: XCTestCase {
    func testUploadPayloadIncludesTextWhenRetentionAllowed() {
        let selection = SelectionCapture.Selection(
            text: "hello world",
            source: .ax,
            truncated: false,
            originalCharCount: 11
        )
        let payload = selection.uploadPayload(allowContentRetention: true)
        XCTAssertEqual(payload["text"] as? String, "hello world")
        XCTAssertEqual(payload["source"] as? String, "ax")
        XCTAssertEqual(payload["char_count"] as? Int, 11)
        XCTAssertEqual(payload["truncated"] as? Bool, false)
        XCTAssertNil(payload["text_redacted"])
    }

    func testUploadPayloadDropsTextWhenRetentionDenied() {
        let selection = SelectionCapture.Selection(
            text: "private draft",
            source: .syntheticCopy,
            truncated: true,
            originalCharCount: 10_000
        )
        let payload = selection.uploadPayload(allowContentRetention: false)
        XCTAssertNil(payload["text"])
        XCTAssertEqual(payload["text_redacted"] as? Bool, true)
        XCTAssertEqual(payload["source"] as? String, "synthetic_copy")
        XCTAssertEqual(payload["char_count"] as? Int, 10_000)
        XCTAssertEqual(payload["truncated"] as? Bool, true)
    }
}
