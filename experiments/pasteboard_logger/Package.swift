// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PasteboardLogger",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(
            name: "PasteboardReplayCore"
        ),
        .executableTarget(
            name: "PasteboardLogger"
        ),
        .executableTarget(
            name: "PasteboardHTMLPreview",
            dependencies: ["PasteboardReplayCore"]
        ),
        .executableTarget(
            name: "BatchClipboardHistoryReplay",
            dependencies: ["PasteboardReplayCore"]
        ),
        .executableTarget(
            name: "BatchClipboardHistoryHarness",
            dependencies: ["PasteboardReplayCore"]
        ),
        .testTarget(
            name: "PasteboardReplayCoreTests",
            dependencies: ["PasteboardReplayCore"]
        )
    ]
)
