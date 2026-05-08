import Foundation
import XCTest
@testable import Blink

final class BlinkEventClientTests: XCTestCase {
    func testDeliverySucceededRequiresStoredTrue() throws {
        let response = try makeResponse(statusCode: 200)
        let data = #"{"ok":true,"stored":true}"#.data(using: .utf8)

        XCTAssertTrue(BlinkEventClient.deliverySucceeded(data: data, response: response, error: nil))
    }

    func testDeliverySucceededRejectsUnstored2xxResponse() throws {
        let response = try makeResponse(statusCode: 200)
        let data = #"{"ok":true,"stored":false}"#.data(using: .utf8)

        XCTAssertFalse(BlinkEventClient.deliverySucceeded(data: data, response: response, error: nil))
    }

    func testDeliverySucceededRejectsLegacy2xxResponseWithoutStoredFlag() throws {
        let response = try makeResponse(statusCode: 200)
        let data = #"{"ok":true}"#.data(using: .utf8)

        XCTAssertFalse(BlinkEventClient.deliverySucceeded(data: data, response: response, error: nil))
    }

    private func makeResponse(statusCode: Int) throws -> HTTPURLResponse {
        guard let response = HTTPURLResponse(
            url: URL(string: "https://example.com/v1/tldr/events")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        ) else {
            throw XCTSkip("Failed to create HTTPURLResponse")
        }
        return response
    }
}
