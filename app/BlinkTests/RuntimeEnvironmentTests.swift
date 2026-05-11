import Foundation
import XCTest
@testable import Blink

final class RuntimeEnvironmentTests: XCTestCase {
    func testFirstRunOnboardingRequiresNoMarkerAndNoRuns() throws {
        let base = try makeTempDirectory()
        let runtime = base.appendingPathComponent("runtime", isDirectory: true)
        let runs = base.appendingPathComponent("runs", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)

        XCTAssertTrue(Paths.requiresFirstRunOnboarding(runtimeDir: runtime, runsDir: runs))

        Paths.markOnboarded(runtimeDir: runtime)
        XCTAssertFalse(Paths.requiresFirstRunOnboarding(runtimeDir: runtime, runsDir: runs))
    }

    func testFirstRunOnboardingSkipsExistingRunHistory() throws {
        let base = try makeTempDirectory()
        let runtime = base.appendingPathComponent("runtime", isDirectory: true)
        let runs = base.appendingPathComponent("runs", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
        try "done".write(to: runs.appendingPathComponent("existing-run"), atomically: true, encoding: .utf8)

        XCTAssertFalse(Paths.requiresFirstRunOnboarding(runtimeDir: runtime, runsDir: runs))
    }

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

    func testProxyConfigDisabledByEnvironmentSwitch() {
        var env: [String: String] = [:]
        RuntimeEnvironment.mergeEnvText(
            """
            BLINK_PROXY_URL=https://packaged.example
            BLINK_PROXY_TOKEN=packaged-token
            BLINK_DISABLE_PROXY=1
            """,
            into: &env
        )

        XCTAssertTrue(RuntimeEnvironment.proxyDisabled(in: env))
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
