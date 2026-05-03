import Foundation
import XCTest
@testable import TLDR

final class RuntimeEnvironmentTests: XCTestCase {
    func testMergeEnvTextKeepsExistingValuesAndAddsMissingValues() {
        var env = ["BLINK_PROXY_URL": "https://override.example"]

        RuntimeEnvironment.mergeEnvText(
            """
            # packaged defaults
            BLINK_PROXY_URL=https://packaged.example
            BLINK_PROXY_TOKEN="packaged-token"
            export EXTRA_VALUE='extra'
            """,
            into: &env
        )

        XCTAssertEqual(env["BLINK_PROXY_URL"], "https://override.example")
        XCTAssertEqual(env["BLINK_PROXY_TOKEN"], "packaged-token")
        XCTAssertEqual(env["EXTRA_VALUE"], "extra")
    }
}
