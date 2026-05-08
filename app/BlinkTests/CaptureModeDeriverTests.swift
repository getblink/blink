import CoreGraphics
import XCTest
@testable import Blink

final class CaptureModeDeriverTests: XCTestCase {
    private func frame(
        windowID: CGWindowID,
        pid: Int? = 100,
        appName: String? = "Slack",
        bundleID: String? = "com.tinyspeck.slackmacgap"
    ) -> CaptureModeDeriver.FrameInfo {
        CaptureModeDeriver.FrameInfo(
            windowID: windowID,
            pid: pid,
            appName: appName,
            bundleID: bundleID
        )
    }

    func testSingleFrameIsFrontmostWindow() {
        XCTAssertEqual(
            CaptureModeDeriver.captureMode(for: [frame(windowID: 1)]),
            "frontmost_window"
        )
    }

    func testEmptyFramesFallBackToFrontmostWindow() {
        XCTAssertEqual(
            CaptureModeDeriver.captureMode(for: []),
            "frontmost_window"
        )
    }

    func testSameWindowMultipleFramesIsScroll() {
        let frames = [frame(windowID: 7), frame(windowID: 7), frame(windowID: 7)]

        XCTAssertEqual(
            CaptureModeDeriver.captureMode(for: frames),
            "frontmost_window_scroll"
        )
    }

    func testDifferentWindowsSameAppIsMultiWindow() {
        let frames = [frame(windowID: 7), frame(windowID: 9)]

        XCTAssertEqual(
            CaptureModeDeriver.captureMode(for: frames),
            "multi_window"
        )
    }

    func testDifferentAppsIsMultiWindow() {
        let frames = [
            frame(windowID: 7, pid: 100, appName: "Slack", bundleID: "com.tinyspeck.slackmacgap"),
            frame(windowID: 11, pid: 200, appName: "Mail", bundleID: "com.apple.mail"),
        ]

        XCTAssertEqual(
            CaptureModeDeriver.captureMode(for: frames),
            "multi_window"
        )
    }

    func testCollectingMessageDefaultsToNilForSingleFrame() {
        XCTAssertNil(
            CaptureModeDeriver.collectingMessage(
                frames: [frame(windowID: 1)],
                duplicate: false
            )
        )
    }

    func testCollectingMessageReportsDuplicateFirst() {
        XCTAssertEqual(
            CaptureModeDeriver.collectingMessage(
                frames: [frame(windowID: 1)],
                duplicate: true
            ),
            "Same content. Scroll first"
        )
    }

    func testCollectingMessageNilForSameAppMultipleFrames() {
        let frames = [frame(windowID: 7), frame(windowID: 9)]

        XCTAssertNil(
            CaptureModeDeriver.collectingMessage(frames: frames, duplicate: false)
        )
    }

    func testCollectingMessageReportsAppCountWhenAppsDiffer() {
        let frames = [
            frame(windowID: 7, pid: 100, appName: "Slack", bundleID: "com.tinyspeck.slackmacgap"),
            frame(windowID: 11, pid: 200, appName: "Linear", bundleID: "com.linear.linear"),
        ]

        XCTAssertEqual(
            CaptureModeDeriver.collectingMessage(frames: frames, duplicate: false),
            "Collecting from 2 apps"
        )
    }

    func testCollectingMessageFallsBackToBundleIDWhenAppNameMissing() {
        let frames = [
            frame(windowID: 7, pid: 100, appName: nil, bundleID: "com.example.A"),
            frame(windowID: 11, pid: 200, appName: nil, bundleID: "com.example.B"),
        ]

        XCTAssertEqual(
            CaptureModeDeriver.collectingMessage(frames: frames, duplicate: false),
            "Collecting from 2 apps"
        )
    }
}
