import XCTest
@testable import Blink

final class SelectionCaptureTests: XCTestCase {
    func testUploadPayloadAlwaysIncludesTextForModelUse() {
        // The selection is the user's *explicit* request input — they
        // highlighted it and pressed the hotkey on purpose. The model
        // needs to see it. Storage-time redaction lives server-side in
        // `_privacy_safe_envelope`.
        let selection = SelectionCapture.Selection(
            text: "hello world",
            source: .ax,
            truncated: false,
            originalCharCount: 11
        )
        let payload = selection.uploadPayload()
        XCTAssertEqual(payload["text"] as? String, "hello world")
        XCTAssertEqual(payload["source"] as? String, "ax")
        XCTAssertEqual(payload["char_count"] as? Int, 11)
        XCTAssertEqual(payload["truncated"] as? Bool, false)
        XCTAssertNil(payload["text_redacted"])
    }

    func testUploadPayloadCarriesSourceAndTruncationMetadata() {
        let selection = SelectionCapture.Selection(
            text: "truncated body",
            source: .syntheticCopy,
            truncated: true,
            originalCharCount: 10_000
        )
        let payload = selection.uploadPayload()
        XCTAssertEqual(payload["text"] as? String, "truncated body")
        XCTAssertEqual(payload["source"] as? String, "synthetic_copy")
        XCTAssertEqual(payload["char_count"] as? Int, 10_000)
        XCTAssertEqual(payload["truncated"] as? Bool, true)
    }
}
