import Foundation
import XCTest
@testable import TLDR

final class RuntimeConfigStoreTests: XCTestCase {
    func testRuntimeConfigFileDefaultsNewPrivacyFieldsWhenMissing() throws {
        let data = """
        {
          "version": 1,
          "auto_paste": false,
          "model": "gemini-2.0-flash"
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(RuntimeConfigFile.self, from: data)

        XCTAssertEqual(config.version, 1)
        XCTAssertEqual(config.autoPaste, false)
        XCTAssertEqual(config.model, "gemini-2.0-flash")
        XCTAssertEqual(config.allowEventLogging, true)
        XCTAssertEqual(config.allowContentRetention, false)
    }
}
