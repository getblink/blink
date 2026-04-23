import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Programmatic capture of the frontmost window of the frontmost application,
/// via ScreenCaptureKit (`SCScreenshotManager`).
///
/// We use ScreenCaptureKit (not `/usr/sbin/screencapture` or the deprecated
/// `CGWindowListCreateImage`) for three reasons:
///   1. It is the forward-supported API on macOS 14+.
///   2. Any SCK call from our process registers Blink in the TCC database, so
///      the user can actually grant Screen Recording from System Settings.
///      `CGPreflightScreenCaptureAccess` alone does NOT register us.
///   3. It captures the actual pixels of the window, even when it's behind
///      other windows, unlike a naive region capture.
enum ScreenCapture {
    struct Capture {
        let pngData: Data
        let capturedAt: Date
    }

    enum CaptureError: LocalizedError {
        case noFrontmostApp
        case noCapturableWindow(ownerName: String?)
        case imageEncodingFailed
        case permissionDenied
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .noFrontmostApp:
                return "no frontmost app"
            case .noCapturableWindow(let owner):
                if let owner = owner { return "no capturable window for \(owner)" }
                return "no capturable window"
            case .imageEncodingFailed:
                return "couldn't encode capture as PNG"
            case .permissionDenied:
                return "Screen Recording permission not granted"
            case .underlying(let err):
                return "ScreenCaptureKit: \(err.localizedDescription)"
            }
        }
    }

    /// Capture the frontmost on-screen window of the frontmost application.
    ///
    /// Called from hotkey handlers — the user's source/target app is still
    /// frontmost because Blink runs as `.accessory` and the hotkey tap doesn't
    /// steal focus.
    static func captureFrontmostWindow() async throws -> Capture {
        let startedAt = Date()

        // Preflight is informational only — we do NOT guard on it (see class
        // doc). If permission is denied, the SCK call below surfaces the real
        // error and the dialog gets shown by CGRequestScreenCaptureAccess() at
        // app launch.
        guard let frontmost = await MainActor.run(body: {
            NSWorkspace.shared.frontmostApplication
        }) else {
            throw CaptureError.noFrontmostApp
        }
        let pid = frontmost.processIdentifier
        let ownerName = frontmost.localizedName

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
        } catch {
            // SCK throws a TCC error if the user denied Screen Recording.
            let nsError = error as NSError
            if nsError.domain == "com.apple.ScreenCaptureKit" || nsError.code == -3801 {
                throw CaptureError.permissionDenied
            }
            throw CaptureError.underlying(error)
        }

        // SCShareableContent.windows is ordered front-to-back in macOS window
        // layer order, so the first match for our PID is the topmost window.
        guard let window = content.windows.first(where: { w in
            w.owningApplication?.processID == pid
                && w.isOnScreen
                && w.frame.width > 0 && w.frame.height > 0
        }) else {
            throw CaptureError.noCapturableWindow(ownerName: ownerName)
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        // Size the capture buffer to the window's pixel dimensions at the
        // owning display's backing scale so we don't downsample.
        let scale = Int(NSScreen.main?.backingScaleFactor ?? 2)
        config.width = max(1, Int(window.frame.width) * scale)
        config.height = max(1, Int(window.frame.height) * scale)
        config.showsCursor = false
        config.scalesToFit = true

        let cgImage: CGImage
        do {
            cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )
        } catch {
            let nsError = error as NSError
            if nsError.domain == "com.apple.ScreenCaptureKit" || nsError.code == -3801 {
                throw CaptureError.permissionDenied
            }
            throw CaptureError.underlying(error)
        }

        guard let pngData = cgImageToPNG(cgImage) else {
            throw CaptureError.imageEncodingFailed
        }
        return Capture(pngData: pngData, capturedAt: startedAt)
    }

    /// Sync bridge for call sites that aren't async-native. Blocks the caller's
    /// thread until capture completes. Do not call from the main thread.
    static func captureFrontmostWindowSync() throws -> Capture {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Capture, Error>!
        Task.detached {
            do { result = .success(try await captureFrontmostWindow()) }
            catch { result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }

    private static func cgImageToPNG(_ image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }
}
