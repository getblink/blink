import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Programmatic capture of the frontmost window of the frontmost application,
/// via ScreenCaptureKit (`SCScreenshotManager`).
///
/// We use ScreenCaptureKit (not `/usr/sbin/screencapture` or the deprecated
/// `CGWindowListCreateImage`) for three reasons:
///   1. It is the forward-supported API on macOS 14+.
///   2. Blink requests Screen Recording at app launch so it appears in System
///      Settings before the first capture. `CGPreflightScreenCaptureAccess`
///      alone does NOT register us.
///   3. It captures the actual pixels of the window, even when it's behind
///      other windows, unlike a naive region capture.
enum ScreenCapture {
    struct Capture {
        let pngData: Data
        let capturedAt: Date
        let windowFramePoints: CGRect
        let windowID: CGWindowID
        let windowTitle: String?
        let ownerPID: pid_t
        let ownerName: String?
        let ownerBundleID: String?
        let shareableContent: SCShareableContent
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
    /// Blink now runs as `.regular` so its own Control window can be frontmost
    /// when the hotkey or Summarize button fires. We never want to capture
    /// Blink itself, so when the resolved frontmost app is Blink we fall back
    /// to the topmost on-screen standard-layer window owned by a different
    /// process. For multi-frame sessions, callers should pass `preferredPID`
    /// after frame 0 so subsequent frames stay pinned to the original source
    /// app even if the collecting overlay momentarily activates Blink.
    static func captureFrontmostWindow(
        preferredGlobalRect: CGRect? = nil,
        shareableContent cachedContent: SCShareableContent? = nil,
        preferredPID: pid_t? = nil,
        axIsFullscreen: Bool = false,
        confirmCapture: Bool = true
    ) async throws -> Capture {
        let startedAt = Date()
        TCCDiagnostics.log(
            "screen_capture_start preferred_pid=\(preferredPID.map(String.init) ?? "nil") preferred_rect=\(preferredGlobalRect.map { NSStringFromRect($0) } ?? "nil") ax_is_fullscreen=\(axIsFullscreen) cached_shareable_content=\(cachedContent != nil)"
        )

        // Preflight is informational only — we do NOT guard on it (see class
        // doc). If permission is denied, the SCK call below surfaces the real
        // error and macOS shows the Screen Recording prompt at capture time.
        let ownPID = NSRunningApplication.current.processIdentifier
        let pid: pid_t
        let ownerName: String?
        if let preferredPID,
           preferredPID != ownPID,
           let app = NSRunningApplication(processIdentifier: preferredPID) {
            pid = preferredPID
            ownerName = app.localizedName
        } else {
            guard let resolved = await MainActor.run(body: { resolveTargetApp(excluding: ownPID) }) else {
                throw CaptureError.noFrontmostApp
            }
            pid = resolved.pid
            ownerName = resolved.name
        }
        TCCDiagnostics.log("screen_capture_owner pid=\(pid) owner_name=\(ownerName ?? "nil")")

        let content: SCShareableContent
        do {
            content = try await shareableContent(
                preferred: cachedContent,
                pid: pid,
                preferredGlobalRect: preferredGlobalRect
            )
            TCCDiagnostics.log(
                "shareable_content_success pid=\(pid) windows=\(content.windows.count) displays=\(content.displays.count)"
            )
        } catch {
            logSCKError("shareable_content_failed", error: error)
            // Only the real TCC denial code is a permission error. Other SCK
            // errors (e.g. ineligible window, transient stream config issues)
            // are bubbled as `.underlying` so they aren't mislabeled as a
            // permission problem.
            if isPermissionDenialError(error) {
                throw CaptureError.permissionDenied
            }
            throw CaptureError.underlying(error)
        }

        // Windows owned by Blink itself (the capture-confirmation flash, the
        // glass loading lens, the suggestions overlay). Excluded from any
        // *display* capture so a Blink surface that happens to be on screen at
        // capture time never bleeds into the screenshot — most importantly the
        // instant loading lens now shown at hotkey press (before this capture
        // runs), but also the collecting overlay during a multi-frame append.
        // Per-window capture (`desktopIndependentWindow`) already isolates the
        // target window, so this only matters for the display paths below.
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }

        // Fullscreen apps live on their own macOS Space. Capturing them via a
        // per-window SCK filter from a different Space is the failure mode
        // behind: (a) "Failed to start stream due to audio/video capture
        // failure" dialogs, (b) silent all-black captures, and (c) the
        // chooser picking the wrong same-PID candidate when multiple
        // fullscreen Spaces are open. Display capture of the SCDisplay that
        // contains the AX-reported window center is significantly more
        // reliable on cross-Space content because it streams compositor
        // output rather than a per-surface window stream. Skip the
        // candidate/chooser walk entirely in that case.
        if axIsFullscreen,
           let axRect = preferredGlobalRect,
           let display = displayForRect(axRect, in: content) {
            TCCDiagnostics.log(
                "fullscreen_display_capture_attempt pid=\(pid) ax_rect=\(NSStringFromRect(axRect)) display_id=\(display.displayID) display_frame=\(NSStringFromRect(display.frame))"
            )
            do {
                let pngData = try await captureDisplayPNG(display, excludingWindows: ownWindows)
                if confirmCapture {
                    await MainActor.run {
                        CaptureConfirmationOverlay.flash(frame: display.frame)
                    }
                }
                return Capture(
                    pngData: pngData,
                    capturedAt: startedAt,
                    windowFramePoints: display.frame,
                    windowID: 0,
                    windowTitle: nil,
                    ownerPID: pid,
                    ownerName: ownerName,
                    ownerBundleID: nil,
                    shareableContent: content
                )
            } catch {
                logSCKError("fullscreen_display_capture_failed", error: error)
                if isPermissionDenialError(error) {
                    throw CaptureError.permissionDenied
                }
                // Fall through to the window-capture path as a backstop. The
                // chooser may still pick wrong, but on AX-reachable apps
                // we've at least logged the failure mode for diagnosis.
            }
        }

        let candidates = candidateWindows(in: content, pid: pid)
        logCGZOrderForPID(pid)
        guard let window = chooseWindow(
            from: candidates,
            preferredGlobalRect: preferredGlobalRect
        ) else {
            TCCDiagnostics.log(
                "screen_capture_no_window pid=\(pid) candidate_count=\(candidates.count) owner_name=\(ownerName ?? "nil")"
            )
            throw CaptureError.noCapturableWindow(ownerName: ownerName)
        }
        TCCDiagnostics.log(
            "screen_capture_window_selected pid=\(pid) window_id=\(window.windowID) title=\(window.title ?? "nil") frame=\(NSStringFromRect(window.frame))"
        )

        let scale = await MainActor.run { backingScaleFactor(for: window.frame) }

        if shouldUseDisplayFallback(windowFrame: window.frame, scale: scale),
           let display = displayForWindow(window, in: content) {
            do {
                TCCDiagnostics.log(
                    "display_capture_attempt display_id=\(display.displayID) frame=\(NSStringFromRect(display.frame))"
                )
                let pngData = try await captureDisplayPNG(display, excludingWindows: ownWindows)
                if confirmCapture {
                    await MainActor.run {
                        CaptureConfirmationOverlay.flash(frame: display.frame)
                    }
                }
                return Capture(
                    pngData: pngData,
                    capturedAt: startedAt,
                    windowFramePoints: display.frame,
                    windowID: window.windowID,
                    windowTitle: window.title,
                    ownerPID: pid,
                    ownerName: window.owningApplication?.applicationName ?? ownerName,
                    ownerBundleID: window.owningApplication?.bundleIdentifier,
                    shareableContent: content
                )
            } catch {
                logSCKError("display_capture_failed", error: error)
                if isPermissionDenialError(error) {
                    throw CaptureError.permissionDenied
                }
                // If the full-display fallback is unavailable for this
                // surface, keep the older window path as a last resort.
            }
        }

        let sizing = preferredCaptureSize(
            windowFrame: window.frame,
            preferredGlobalRect: preferredGlobalRect
        )
        TCCDiagnostics.log(
            "window_capture_attempt window_id=\(window.windowID) scale=\(scale) sck_frame=\(NSStringFromRect(window.frame)) ax_rect=\(preferredGlobalRect.map { NSStringFromRect($0) } ?? "nil") sizing_source=\(sizing.source == .ax ? "ax" : "sck")"
        )
        let cgImage = try await captureWindowImage(
            window,
            captureSize: sizing.size,
            scale: scale
        )
        guard let pngData = cgImageToPNG(cgImage) else {
            throw CaptureError.imageEncodingFailed
        }
        if confirmCapture {
            await MainActor.run {
                CaptureConfirmationOverlay.flash(frame: window.frame)
            }
        }
        return Capture(
            pngData: pngData,
            capturedAt: startedAt,
            windowFramePoints: window.frame,
            windowID: window.windowID,
            windowTitle: window.title,
            ownerPID: pid,
            ownerName: window.owningApplication?.applicationName ?? ownerName,
            ownerBundleID: window.owningApplication?.bundleIdentifier,
            shareableContent: content
        )
    }

    enum CaptureSizingSource { case ax, sck }

    // Pick the size we should ask SCK to render into. AX dims are preferred
    // when available because SCK's window.frame can lie (e.g. Chrome surfaces
    // a 1512×157 frame while the actual content layer is 1000×700, producing
    // the "3024×314 mostly-black canvas" bug). Falls back to SCK's frame when
    // AX is unavailable or returns something degenerate. Returns the source
    // tag too so callers can log unambiguously even when AX and SCK agree.
    static func preferredCaptureSize(
        windowFrame: CGRect,
        preferredGlobalRect: CGRect?
    ) -> (size: CGSize, source: CaptureSizingSource) {
        guard let ax = preferredGlobalRect,
              !ax.isNull, !ax.isEmpty, !ax.isInfinite,
              ax.width >= 100, ax.height >= 100
        else {
            return (windowFrame.size, .sck)
        }
        return (ax.size, .ax)
    }

    static func shouldUseDisplayFallback(windowFrame: CGRect, scale: Int) -> Bool {
        let pixelWidth = windowFrame.width * CGFloat(max(1, scale))
        let pixelHeight = windowFrame.height * CGFloat(max(1, scale))
        guard pixelWidth > 0, pixelHeight > 0 else { return false }
        // Full-screen apps can surface a thin title/toolbar strip through
        // ScreenCaptureKit. Capturing that as the "window" gives Blink a
        // 3000x64 image and highlights only the app chrome, so promote very
        // wide, very short captures to display capture.
        return pixelHeight < 180 && (pixelWidth / pixelHeight) >= 8
    }

    /// Sync bridge for call sites that aren't async-native. Blocks the caller's
    /// thread until capture completes. Do not call from the main thread.
    static func captureFrontmostWindowSync(
        preferredGlobalRect: CGRect? = nil,
        shareableContent: SCShareableContent? = nil,
        preferredPID: pid_t? = nil,
        axIsFullscreen: Bool = false,
        confirmCapture: Bool = true
    ) throws -> Capture {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Capture, Error>!
        Task.detached {
            do {
                result = .success(try await captureFrontmostWindow(
                    preferredGlobalRect: preferredGlobalRect,
                    shareableContent: shareableContent,
                    preferredPID: preferredPID,
                    axIsFullscreen: axIsFullscreen,
                    confirmCapture: confirmCapture
                ))
            }
            catch { result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }

    struct AXWindowProbe {
        var globalRect: CGRect?
        var isFullscreen: Bool
    }

    /// Probe Accessibility for the focused (or main) window's screen rect for the given PID.
    /// Three-tier: AXFocusedWindow → AXMainWindow → nil (today's behavior as last resort).
    /// A 200ms messaging timeout prevents a hung target from stalling capture.
    static func focusedWindowGlobalRect(for pid: pid_t) -> CGRect? {
        focusedWindowAXProbe(for: pid).globalRect
    }

    /// Combined AX probe that reads the focused window's global rect and its
    /// `kAXFullScreenAttribute` in one round-trip. Returned struct fields may
    /// be individually nil/false when the corresponding attribute couldn't be
    /// read; callers should treat the absence of fullscreen as the
    /// conservative default (window capture rather than display capture).
    static func focusedWindowAXProbe(for pid: pid_t) -> AXWindowProbe {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.2)

        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) != .success || windowRef == nil {
            AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &windowRef)
        }
        guard let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else {
            TCCDiagnostics.log("ax_focused_probe pid=\(pid) result=nil reason=no_window_attribute")
            return AXWindowProbe(globalRect: nil, isFullscreen: false)
        }
        let windowElement = windowRef as! AXUIElement  // safe: CFGetTypeID verified above
        // The 200ms cap set on `appElement` doesn't propagate to elements vended by it;
        // re-apply on `windowElement` so subsequent reads stay bounded too.
        AXUIElementSetMessagingTimeout(windowElement, 0.2)

        let rect = readAXWindowRect(windowElement, pid: pid)
        let isFullscreen = readAXFullscreen(windowElement)
        TCCDiagnostics.log(
            "ax_focused_probe pid=\(pid) rect=\(rect.map { NSStringFromRect($0) } ?? "nil") is_fullscreen=\(isFullscreen)"
        )
        return AXWindowProbe(globalRect: rect, isFullscreen: isFullscreen)
    }

    private static func readAXWindowRect(_ windowElement: AXUIElement, pid: pid_t) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowElement, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(windowElement, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, CFGetTypeID(posRef) == AXValueGetTypeID(),
              let sizeRef, CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &position),  // safe: AXValueGetTypeID verified above
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else {
            return nil
        }

        guard size.width >= 80, size.height >= 80 else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func readAXFullscreen(_ windowElement: AXUIElement) -> Bool {
        var valueRef: CFTypeRef?
        // "AXFullScreen" has been the canonical AXUIElement attribute name
        // for the green-traffic-light fullscreen state since OS X 10.7. There
        // is no kAX*Attribute symbol exported for it in the public
        // Accessibility headers, so the literal string is the documented
        // way to read it.
        guard AXUIElementCopyAttributeValue(windowElement, "AXFullScreen" as CFString, &valueRef) == .success,
              let valueRef else {
            return false
        }
        // CFBoolean is bridged into NSNumber-shaped values; reading it as
        // CFBooleanGetValue is the most direct check.
        let typeID = CFGetTypeID(valueRef)
        if typeID == CFBooleanGetTypeID() {
            return CFBooleanGetValue((valueRef as! CFBoolean))
        }
        // Some apps return NSNumber-bridged values for boolean AX attributes.
        if let number = valueRef as? NSNumber {
            return number.boolValue
        }
        return false
    }

    // `kSCStreamErrorUserDeclined` — the genuine TCC denial. Everything else
    // in the SCK domain is left as `.underlying` so transient errors (e.g.
    // ineligible window) aren't mislabeled as a permission problem.
    private static let kSCStreamErrorUserDeclined = -3801

    private static func isPermissionDenialError(_ error: Error) -> Bool {
        (error as NSError).code == kSCStreamErrorUserDeclined
    }

    private static func shareableContent(
        preferred: SCShareableContent?,
        pid: pid_t,
        preferredGlobalRect: CGRect?
    ) async throws -> SCShareableContent {
        if let preferred,
           chooseWindow(
            from: candidateWindows(in: preferred, pid: pid),
            preferredGlobalRect: preferredGlobalRect
           ) != nil {
            TCCDiagnostics.log("shareable_content_reused pid=\(pid)")
            return preferred
        }
        // `onScreenWindowsOnly: false` so fullscreen-Space windows of the
        // frontmost app still surface as candidates. From Blink's menu-bar Space,
        // ScreenCaptureKit reports those windows with `isOnScreen == false`.
        TCCDiagnostics.log("shareable_content_request pid=\(pid) excluding_desktop_windows=false on_screen_windows_only=false")
        return try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        )
    }

    /// Pick the app to capture, skipping Blink itself. Prefers
    /// `NSWorkspace.frontmostApplication` when it's not Blink; otherwise walks
    /// `CGWindowListCopyWindowInfo` (front-to-back z-order) for the topmost
    /// on-screen standard-layer window owned by a different process.
    @MainActor
    private static func resolveTargetApp(excluding ownPID: pid_t) -> (pid: pid_t, name: String?)? {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ownPID {
            return (frontmost.processIdentifier, frontmost.localizedName)
        }
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        guard let pid = topmostNonSelfOwnerPID(in: infoList, excluding: ownPID) else {
            return nil
        }
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName
        return (pid, name)
    }

    /// Picks the owner PID of the topmost standard-layer on-screen window not
    /// owned by `ownPID`. Extracted for testability — `CGWindowListCopyWindowInfo`
    /// returns dicts in front-to-back z-order, so we take the first match.
    ///
    /// Casts go through `NSNumber` because CF returns CFNumber-bridged
    /// NSNumbers, and `as? pid_t` (a typealias for Int32) is not a reliable
    /// bridge — it can return nil even when the value is present.
    static func topmostNonSelfOwnerPID(
        in windows: [[String: Any]],
        excluding ownPID: pid_t
    ) -> pid_t? {
        for window in windows {
            guard let ownerNumber = window[kCGWindowOwnerPID as String] as? NSNumber else { continue }
            let ownerPID = ownerNumber.int32Value
            guard ownerPID != ownPID else { continue }
            // Require an explicit layer == 0; missing or non-0 layer means
            // status item, dock tile, menu, etc., which we never want to capture.
            guard let layerNumber = window[kCGWindowLayer as String] as? NSNumber,
                  layerNumber.intValue == 0 else { continue }
            if let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
               let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
               bounds.width >= 80, bounds.height >= 80 {
                return ownerPID
            }
        }
        return nil
    }

    /// Best-effort rect (CG-global, top-left origin, +Y down) of the topmost
    /// standard-layer on-screen window not owned by `ownPID`. Resolved purely
    /// from `CGWindowListCopyWindowInfo` z-order — a cheap, synchronous,
    /// in-process query (no `SCShareableContent` round-trip), so it is safe to
    /// call on the main thread at hotkey time. Used to anchor the instant
    /// capture acknowledgment to the same window the real capture is most
    /// likely to pick. Returns nil when nothing suitable is on screen, in
    /// which case the caller simply skips the instant visual. Mirrors the
    /// front-to-back walk in `topmostNonSelfOwnerPID`.
    static func frontmostCapturableWindowRect(excluding ownPID: pid_t) -> CGRect? {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        return frontmostCapturableWindowRect(in: infoList, excluding: ownPID)
    }

    /// Pure core of `frontmostCapturableWindowRect`, split out — like
    /// `topmostNonSelfOwnerPID` — so the z-order / layer / bounds-parsing walk
    /// can be unit-tested without a live window server. Returns the bounds of
    /// the topmost standard-layer on-screen window not owned by `ownPID`.
    static func frontmostCapturableWindowRect(
        in windows: [[String: Any]],
        excluding ownPID: pid_t
    ) -> CGRect? {
        for window in windows {
            guard let ownerNumber = window[kCGWindowOwnerPID as String] as? NSNumber else { continue }
            guard ownerNumber.int32Value != ownPID else { continue }
            guard let layerNumber = window[kCGWindowLayer as String] as? NSNumber,
                  layerNumber.intValue == 0 else { continue }
            if let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
               let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
               bounds.width >= 80, bounds.height >= 80 {
                return bounds
            }
        }
        return nil
    }

    private static func candidateWindows(in content: SCShareableContent, pid: pid_t) -> [SCWindow] {
        content.windows.filter { window in
            window.owningApplication?.processID == pid
                && window.frame.width > 0
                && window.frame.height > 0
        }
    }

    private static func chooseWindow(
        from candidates: [SCWindow],
        preferredGlobalRect: CGRect?
    ) -> SCWindow? {
        logCandidates(candidates, axHint: preferredGlobalRect)
        guard !candidates.isEmpty else { return nil }
        guard let preferredGlobalRect, !preferredGlobalRect.isNull, !preferredGlobalRect.isEmpty else {
            // No hint from Accessibility — prefer standard-layer windows that
            // SCK still considers on-screen so we don't grab a minimized or
            // utility palette window. If none qualify (e.g. the frontmost app
            // is fullscreen on its own Space and Blink sees `isOnScreen ==
            // false` from the menu-bar Space), fall back to the first
            // standard-layer window, then to whatever exists.
            let standardLayer = candidates.filter { $0.windowLayer == 0 }
            if let visibleStandard = standardLayer.first(where: { $0.isOnScreen }) {
                logChooserChoice(visibleStandard, reason: "no_ax_hint_visible_standard")
                return visibleStandard
            }
            if let firstStandard = standardLayer.first {
                logChooserChoice(firstStandard, reason: "no_ax_hint_first_standard")
                return firstStandard
            }
            if let any = candidates.first {
                logChooserChoice(any, reason: "no_ax_hint_first_any")
                return any
            }
            return nil
        }

        let preferredCenter = CGPoint(
            x: preferredGlobalRect.midX,
            y: preferredGlobalRect.midY
        )
        var bestIndex = 0
        var bestContainsCenter = false
        var bestIntersectionArea: CGFloat = -1
        var bestDistanceSquared = CGFloat.greatestFiniteMagnitude

        for (index, window) in candidates.enumerated() {
            let frame = window.frame
            let containsCenter = frame.contains(preferredCenter)
            let intersection = frame.intersection(preferredGlobalRect)
            let intersectionArea = intersection.isNull
                ? 0
                : intersection.width * intersection.height
            let dx = frame.midX - preferredCenter.x
            let dy = frame.midY - preferredCenter.y
            let distanceSquared = dx * dx + dy * dy

            TCCDiagnostics.log(
                "window_chooser_eval index=\(index) window_id=\(window.windowID) contains_center=\(containsCenter) intersection_area=\(intersectionArea) distance_sq=\(distanceSquared)"
            )

            let isBetter =
                (containsCenter && !bestContainsCenter)
                || (containsCenter == bestContainsCenter && intersectionArea > bestIntersectionArea)
                || (
                    containsCenter == bestContainsCenter
                    && intersectionArea == bestIntersectionArea
                    && distanceSquared < bestDistanceSquared
                )

            if isBetter {
                bestIndex = index
                bestContainsCenter = containsCenter
                bestIntersectionArea = intersectionArea
                bestDistanceSquared = distanceSquared
            }
        }

        let chosen = candidates[bestIndex]
        let reason = bestContainsCenter
            ? "ax_hint_contains_center"
            : (bestIntersectionArea > 0 ? "ax_hint_intersection" : "ax_hint_nearest_center")
        logChooserChoice(chosen, reason: reason)
        return chosen
    }

    private static func logCandidates(_ candidates: [SCWindow], axHint: CGRect?) {
        TCCDiagnostics.log(
            "window_chooser_start candidate_count=\(candidates.count) ax_hint=\(axHint.map { NSStringFromRect($0) } ?? "nil")"
        )
        for (index, window) in candidates.enumerated() {
            // Truncate titles so a verbose Chrome tab title doesn't blow up
            // the log line; 60 chars is enough to disambiguate by hand.
            let title = (window.title ?? "").prefix(60)
            TCCDiagnostics.log(
                "window_chooser_candidate index=\(index) window_id=\(window.windowID) layer=\(window.windowLayer) on_screen=\(window.isOnScreen) frame=\(NSStringFromRect(window.frame)) title=\(title)"
            )
        }
    }

    private static func logChooserChoice(_ window: SCWindow, reason: String) {
        TCCDiagnostics.log(
            "window_chooser_choice window_id=\(window.windowID) frame=\(NSStringFromRect(window.frame)) title=\((window.title ?? "").prefix(60)) reason=\(reason)"
        )
    }

    /// Logs Quartz's front-to-back z-order of standard-layer windows owned by
    /// `pid` on the current Space. Used as ground truth against SCK's
    /// `SCShareableContent.windows`, which is *not* z-ordered — when those two
    /// disagree on which window is frontmost, we expect the multi-window
    /// fullscreen-Chrome wrong-window bug to surface.
    private static func logCGZOrderForPID(_ pid: pid_t) {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            TCCDiagnostics.log("cg_zorder_snapshot pid=\(pid) result=nil")
            return
        }
        let owned = infoList.filter { entry in
            ((entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1) == pid
        }
        let summary = owned.enumerated().map { index, entry -> String in
            let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
            let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            let title = (entry[kCGWindowName as String] as? String) ?? ""
            let boundsDict = entry[kCGWindowBounds as String] as? [String: Any]
            let bounds = boundsDict.flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
            let boundsStr = bounds.map { NSStringFromRect($0) } ?? "nil"
            return "[\(index):id=\(id),layer=\(layer),frame=\(boundsStr),title=\(title.prefix(40))]"
        }.joined(separator: " ")
        TCCDiagnostics.log("cg_zorder_snapshot pid=\(pid) count=\(owned.count) windows=\(summary)")
    }

    private static func captureWindowImage(
        _ window: SCWindow,
        captureSize: CGSize,
        scale: Int
    ) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        // Size the capture buffer to the window's pixel dimensions at the
        // owning display's backing scale so we don't downsample. We accept
        // captureSize from the caller because SCK's window.frame is unreliable
        // for some Chrome window states (reports a wide-short strip while
        // Chrome's content layer is normally proportioned), and the AX rect
        // — when available — is a more faithful source for window dims.
        config.width = max(1, Int(captureSize.width) * scale)
        config.height = max(1, Int(captureSize.height) * scale)
        config.showsCursor = false
        config.scalesToFit = true

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            TCCDiagnostics.log(
                "window_capture_success window_id=\(window.windowID) width=\(image.width) height=\(image.height)"
            )
            return image
        } catch {
            logSCKError("window_capture_failed", error: error)
            if isPermissionDenialError(error) {
                throw CaptureError.permissionDenied
            }
            throw CaptureError.underlying(error)
        }
    }

    private static func captureDisplayPNG(
        _ display: SCDisplay,
        excludingWindows: [SCWindow] = []
    ) async throws -> Data {
        let filter = SCContentFilter(display: display, excludingWindows: excludingWindows)
        if #available(macOS 14.2, *) {
            filter.includeMenuBar = false
        }
        let scale = await MainActor.run { backingScaleFactor(for: display.frame) }
        let config = SCStreamConfiguration()
        config.width = max(1, display.width * scale)
        config.height = max(1, display.height * scale)
        config.showsCursor = false
        config.scalesToFit = false

        let cgImage: CGImage
        do {
            cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            TCCDiagnostics.log(
                "display_capture_success display_id=\(display.displayID) width=\(cgImage.width) height=\(cgImage.height)"
            )
        } catch {
            logSCKError("display_capture_failed", error: error)
            if isPermissionDenialError(error) {
                throw CaptureError.permissionDenied
            }
            throw CaptureError.underlying(error)
        }
        guard let pngData = cgImageToPNG(cgImage) else {
            throw CaptureError.imageEncodingFailed
        }
        return pngData
    }

    private static func displayForWindow(_ window: SCWindow, in content: SCShareableContent) -> SCDisplay? {
        displayForRect(window.frame, in: content)
    }

    private static func displayForRect(_ rect: CGRect, in content: SCShareableContent) -> SCDisplay? {
        guard !content.displays.isEmpty else { return nil }
        guard let idx = bestDisplayIndex(for: rect, displayFrames: content.displays.map(\.frame)) else {
            return nil
        }
        return content.displays[idx]
    }

    /// Pure-data display chooser: returns the index of the display whose
    /// frame contains the center of `rect`, or the one with the largest
    /// intersection if no display contains the center. Extracted from
    /// `displayForRect` so it's testable without SCDisplay (which can't be
    /// constructed outside of SCK).
    static func bestDisplayIndex(for rect: CGRect, displayFrames: [CGRect]) -> Int? {
        guard !displayFrames.isEmpty else { return nil }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var bestIndex = 0
        var bestArea: CGFloat = -1
        var bestContainsCenter = false
        for (idx, frame) in displayFrames.enumerated() {
            let intersection = frame.intersection(rect)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            let containsCenter = frame.contains(center)
            let isBetter = (containsCenter && !bestContainsCenter)
                || (containsCenter == bestContainsCenter && area > bestArea)
            if isBetter {
                bestIndex = idx
                bestArea = area
                bestContainsCenter = containsCenter
            }
        }
        return bestIndex
    }

    /// Pick the `NSScreen` whose AppKit frame best covers `frame` (a global
    /// CG rect, top-left origin — same coordinate space as
    /// `Capture.windowFramePoints`). Used by the overlay to land on the
    /// display the captured content came from instead of `NSScreen.main`,
    /// which on multi-display setups flips around based on focus history.
    ///
    /// `NSScreen.frame` is in AppKit coords (bottom-left origin), while
    /// `windowFramePoints` is in CG global coords (top-left origin), so we
    /// translate before intersecting. Returns nil only when no screens are
    /// attached.
    @MainActor
    static func screenForGlobalRect(_ frame: CGRect) -> NSScreen? {
        guard let primary = NSScreen.screens.first else { return nil }
        let height = primary.frame.height
        // Convert frame from CG global (top-left) to AppKit (bottom-left).
        // Y in AppKit = primaryHeight - (top + height).
        let appKitRect = NSRect(
            x: frame.origin.x,
            y: height - frame.maxY,
            width: frame.width,
            height: frame.height
        )
        return NSScreen.screens.max { lhs, rhs in
            intersectionArea(lhs.frame, appKitRect) < intersectionArea(rhs.frame, appKitRect)
        }
    }

    private static func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }

    @MainActor
    private static func backingScaleFactor(for frame: CGRect) -> Int {
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) {
            return max(1, Int(round(screen.backingScaleFactor)))
        }
        return max(1, Int(round(NSScreen.main?.backingScaleFactor ?? 2)))
    }

    private static func cgImageToPNG(_ image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    private static func logSCKError(_ event: String, error: Error) {
        let nsError = error as NSError
        TCCDiagnostics.log(
            "\(event) domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)"
        )
    }
}

@MainActor
enum CaptureConfirmationOverlay {
    private static let bleed: CGFloat = 28
    private static let pulseDuration: TimeInterval = 0.30
    private static let fadeDuration: TimeInterval = 0.18
    // For window-anchored placements the outline doesn't just fade — it
    // collapses toward the corner/edge where the loading puck docks, so the
    // capture and the "Reading…" pill read as one continuous gesture.
    private static let contractDuration: TimeInterval = 0.34

    static func flash(frame: CGRect) {
        // In glass-loading mode the clear Liquid Glass lens drawn over the
        // captured window *is* the capture confirmation. The scanner outline
        // would double up and clash with it, so skip it entirely.
        if RuntimeEnvironment.glassLoadingEnabled() { return }
        guard frame.width > 8, frame.height > 8 else { return }
        guard let primaryScreen = NSScreen.screens.first else { return }
        let appKitFrame = NSRect(
            x: frame.origin.x,
            y: primaryScreen.frame.height - frame.maxY,
            width: frame.width,
            height: frame.height
        )
        // Grow the panel beyond the captured window's frame so the layer
        // shadow used for the accent glow has room to render outside the
        // stroke. The inner view is inset by `bleed` and matches the original
        // window frame exactly.
        let panelFrame = appKitFrame.insetBy(dx: -bleed, dy: -bleed)
        let panel = NSPanel(
            contentRect: panelFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false

        let container = NSView(frame: NSRect(origin: .zero, size: panelFrame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = container

        // Brand-blue capture outline. This path only runs when Liquid Glass
        // loading is OFF (glass mode suppresses the flash and uses the lens as
        // its own confirmation), so here we want a clearly visible blue stroke:
        // a brand-blue border over a faint blue wash, with a soft blue glow so
        // it reads on both light and dark windows.
        let accent = NSColor.systemBlue
        let view = NSView(frame: NSRect(x: bleed, y: bleed, width: appKitFrame.width, height: appKitFrame.height))
        view.wantsLayer = true
        view.layer?.backgroundColor = accent.withAlphaComponent(0.10).cgColor
        view.layer?.borderColor = accent.withAlphaComponent(0.95).cgColor
        view.layer?.borderWidth = 2
        view.layer?.cornerRadius = 6
        view.layer?.cornerCurve = .continuous
        view.layer?.shadowColor = accent.cgColor
        view.layer?.shadowOpacity = 0.55
        view.layer?.shadowRadius = 18
        view.layer?.shadowOffset = .zero
        view.layer?.masksToBounds = false

        let placement = RuntimeEnvironment.loadingPlacement()
        let anchored = placement != .centered

        container.addSubview(view)
        panel.orderFrontRegardless()

        let border = CABasicAnimation(keyPath: "borderWidth")
        border.fromValue = 2
        border.toValue = 6
        border.duration = pulseDuration
        border.timingFunction = CAMediaTimingFunction(name: .easeOut)
        border.fillMode = .forwards
        border.isRemovedOnCompletion = false
        view.layer?.add(border, forKey: "captureBorder")
        view.layer?.borderWidth = 6

        let glow = CABasicAnimation(keyPath: "shadowRadius")
        glow.fromValue = 6
        glow.toValue = 22
        glow.duration = pulseDuration
        glow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        glow.fillMode = .forwards
        glow.isRemovedOnCompletion = false
        view.layer?.add(glow, forKey: "captureGlow")
        view.layer?.shadowRadius = 22

        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [1.0, 0.985, 1.0]
        scale.keyTimes = [0, 0.55, 1]
        scale.duration = pulseDuration
        scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        view.layer?.add(scale, forKey: "captureScale")

        DispatchQueue.main.asyncAfter(deadline: .now() + pulseDuration) {
            if anchored {
                // Collapse the outline toward the corner/edge where the loading
                // puck docks (bottom-right for corner, right-center for side) so
                // the capture visually resolves into the pill. Animating the
                // frame to an explicit target rect is unambiguous about
                // direction (anchorPoint math on a layer-backed view is fragile).
                let finalSize: CGFloat = 10
                let targetX = bleed + appKitFrame.width - finalSize
                let targetY: CGFloat = placement == .windowSide
                    ? bleed + appKitFrame.height / 2 - finalSize / 2
                    : bleed
                let targetRect = NSRect(x: targetX, y: targetY, width: finalSize, height: finalSize)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = contractDuration
                    context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    view.animator().frame = targetRect
                    container.animator().alphaValue = 0
                } completionHandler: {
                    panel.close()
                }
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = fadeDuration
                    context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    container.animator().alphaValue = 0
                } completionHandler: {
                    panel.close()
                }
            }
        }
    }
}
