import CoreGraphics
import Foundation

/// Pure helpers that compute the request envelope's `capture_mode` and the
/// "collecting" overlay message from a set of captured frames. Extracted from
/// `TLDRCoordinator` so they're directly unit-testable without spinning up
/// the full coordinator (which depends on ScreenCaptureKit, the Python
/// runner, and the menubar app shell).
enum CaptureModeDeriver {
    struct FrameInfo {
        let windowID: CGWindowID
        let pid: Int?
        let appName: String?
        let bundleID: String?
    }

    /// `frontmost_window` for one frame, `frontmost_window_scroll` when every
    /// frame shares the same window+app (the legacy multi-frame scroll flow),
    /// and `multi_window` when at least one frame came from a different
    /// window or app (the new double-tap multi-window flow).
    static func captureMode(for frames: [FrameInfo]) -> String {
        guard frames.count > 1, let first = frames.first else {
            return "frontmost_window"
        }
        let allSameSurface = frames.allSatisfy { frame in
            frame.windowID == first.windowID && frame.pid == first.pid
        }
        return allSameSurface ? "frontmost_window_scroll" : "multi_window"
    }

    /// Lead message for the collecting overlay. `nil` lets the overlay fall
    /// back to the default "Collecting" copy. The "Same content" path is
    /// driven by the dedupe check, so callers pass `duplicate: true` to
    /// surface that copy verbatim.
    static func collectingMessage(frames: [FrameInfo], duplicate: Bool) -> String? {
        if duplicate {
            return "Same content. Scroll first"
        }
        guard frames.count >= 2 else { return nil }
        let identifiers = frames.map { frame -> String in
            frame.appName ?? frame.bundleID ?? "pid:\(frame.pid ?? -1)"
        }
        let unique = Set(identifiers)
        if unique.count > 1 {
            return "Collecting from \(unique.count) apps"
        }
        return nil
    }
}
