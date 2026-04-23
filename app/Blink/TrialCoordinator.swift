import AppKit
import Foundation

/// Orchestrates one copy-paste trial:
///   ⌃⇧C → captures source screenshot, stashes it in memory
///   ⌃⇧V → captures target screenshot + AX metadata, invokes Python, pastes result
///
/// All state is serialized on `queue`; the hotkey callbacks bounce onto it so
/// Swift-side I/O doesn't race the event tap callback thread.
final class TrialCoordinator {
    private let config: Config
    private let queue = DispatchQueue(label: "blink.coordinator", qos: .userInitiated)
    private var stashedSource: (image: Data, capturedAt: Date)?

    var onStatusChange: ((String) -> Void)?

    init(config: Config) {
        self.config = config
    }

    func setSource() {
        queue.async { [self] in
            status("capturing source…")
            do {
                let capture = try ScreenCapture.captureFrontmostWindowSync()
                stashedSource = (image: capture.pngData, capturedAt: capture.capturedAt)
                status("source captured — press ⌃⇧V on the target field")
            } catch {
                status("source capture failed: \(error.localizedDescription)")
            }
        }
    }

    func runTarget() {
        queue.async { [self] in
            guard let source = stashedSource else {
                status("no source stashed — press ⌃⇧C first")
                return
            }
            status("capturing target…")

            let metadata: TargetMetadata
            let targetCapture: ScreenCapture.Capture
            do {
                // AX metadata FIRST — it reads the currently focused element,
                // which must not change before we capture. SCScreenshotManager
                // runs off-thread and doesn't affect focus.
                metadata = TargetMetadataCapture.capture()
                targetCapture = try ScreenCapture.captureFrontmostWindowSync()
            } catch {
                status("target capture failed: \(error.localizedDescription)")
                return
            }

            let bundleId = ArtifactWriter.newBundleID()
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("blink-\(bundleId)-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                try source.image.write(to: tempDir.appendingPathComponent("source.png"))
                try targetCapture.pngData.write(to: tempDir.appendingPathComponent("target.png"))
                try ArtifactWriter.writeJSON(
                    metadata.asDictionary(),
                    to: tempDir.appendingPathComponent("target_metadata.json")
                )
            } catch {
                try? FileManager.default.removeItem(at: tempDir)
                status("artifact prep failed: \(error.localizedDescription)")
                return
            }

            status("calling Gemini…")
            PythonRunner.runOnce(
                config: config,
                sourcePNG: tempDir.appendingPathComponent("source.png"),
                targetPNG: tempDir.appendingPathComponent("target.png"),
                targetMetadataJSON: tempDir.appendingPathComponent("target_metadata.json"),
                outputParent: Paths.runsDir,
                bundleId: bundleId
            ) { [weak self] result in
                guard let self = self else {
                    try? FileManager.default.removeItem(at: tempDir)
                    return
                }
                self.queue.async {
                    defer { try? FileManager.default.removeItem(at: tempDir) }
                    switch result {
                    case .success(let output):
                        if output.isEmpty {
                            self.status("empty output; check run.json for errors")
                            return
                        }
                        self.status("inserting \(output.count) chars…")
                        Inserter.insert(text: output) { insertResult in
                            switch insertResult {
                            case .success:
                                self.status("done — output pasted")
                            case .failure(let err):
                                self.status("paste failed: \(err.localizedDescription)")
                            }
                        }
                    case .failure(let err):
                        self.status("python failed: \(err.localizedDescription)")
                    }
                }
            }
        }
    }

    private func status(_ text: String) {
        onStatusChange?(text)
        NSLog("[blink] %@", text)
    }
}
