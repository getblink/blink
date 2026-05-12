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
        preferredPID: pid_t? = nil
    ) async throws -> Capture {
        let startedAt = Date()
        TCCDiagnostics.log(
            "screen_capture_start preferred_pid=\(preferredPID.map(String.init) ?? "nil") preferred_rect=\(preferredGlobalRect.map { NSStringFromRect($0) } ?? "nil") cached_shareable_content=\(cachedContent != nil)"
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

        let candidates = candidateWindows(in: content, pid: pid)
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
                let pngData = try await captureDisplayPNG(display)
                await MainActor.run {
                    CaptureConfirmationOverlay.flash(frame: display.frame)
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
        await MainActor.run {
            CaptureConfirmationOverlay.flash(frame: window.frame)
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
        preferredPID: pid_t? = nil
    ) throws -> Capture {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Capture, Error>!
        Task.detached {
            do {
                result = .success(try await captureFrontmostWindow(
                    preferredGlobalRect: preferredGlobalRect,
                    shareableContent: shareableContent,
                    preferredPID: preferredPID
                ))
            }
            catch { result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }

    /// Probe Accessibility for the focused (or main) window's screen rect for the given PID.
    /// Three-tier: AXFocusedWindow → AXMainWindow → nil (today's behavior as last resort).
    /// A 200ms messaging timeout prevents a hung target from stalling capture.
    static func focusedWindowGlobalRect(for pid: pid_t) -> CGRect? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.2)

        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) != .success || windowRef == nil {
            AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &windowRef)
        }
        guard let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else {
            TCCDiagnostics.log("ax_focused_rect pid=\(pid) result=nil reason=no_window_attribute")
            return nil
        }
        let windowElement = windowRef as! AXUIElement  // safe: CFGetTypeID verified above
        // The 200ms cap set on `appElement` doesn't propagate to elements vended by it;
        // re-apply on `windowElement` so the position/size reads stay bounded too.
        AXUIElementSetMessagingTimeout(windowElement, 0.2)

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowElement, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(windowElement, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, CFGetTypeID(posRef) == AXValueGetTypeID(),
              let sizeRef, CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            TCCDiagnostics.log("ax_focused_rect pid=\(pid) result=nil reason=no_position_or_size")
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &position),  // safe: AXValueGetTypeID verified above
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else {
            TCCDiagnostics.log("ax_focused_rect pid=\(pid) result=nil reason=value_type_mismatch")
            return nil
        }

        guard size.width >= 80, size.height >= 80 else {
            TCCDiagnostics.log("ax_focused_rect pid=\(pid) result=nil reason=too_small width=\(size.width) height=\(size.height)")
            return nil
        }

        let rect = CGRect(origin: position, size: size)
        TCCDiagnostics.log("ax_focused_rect pid=\(pid) result=\(NSStringFromRect(rect))")
        return rect
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
                return visibleStandard
            }
            if let firstStandard = standardLayer.first {
                return firstStandard
            }
            return candidates.first
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

        return candidates[bestIndex]
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

    private static func captureDisplayPNG(_ display: SCDisplay) async throws -> Data {
        let filter = SCContentFilter(display: display, excludingWindows: [])
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
        guard !content.displays.isEmpty else { return nil }
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        var bestDisplay = content.displays[0]
        var bestArea: CGFloat = -1
        var bestContainsCenter = false
        for display in content.displays {
            let intersection = display.frame.intersection(window.frame)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            let containsCenter = display.frame.contains(center)
            let isBetter = (containsCenter && !bestContainsCenter)
                || (containsCenter == bestContainsCenter && area > bestArea)
            if isBetter {
                bestDisplay = display
                bestArea = area
                bestContainsCenter = containsCenter
            }
        }
        return bestDisplay
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
private enum CaptureConfirmationOverlay {
    private static let bleed: CGFloat = 28
    private static let pulseDuration: TimeInterval = 0.30
    private static let fadeDuration: TimeInterval = 0.18

    static func flash(frame: CGRect) {
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

        let view = NSView(frame: NSRect(x: bleed, y: bleed, width: appKitFrame.width, height: appKitFrame.height))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        view.layer?.borderWidth = 2
        view.layer?.cornerRadius = 6
        view.layer?.cornerCurve = .continuous
        view.layer?.shadowColor = NSColor.controlAccentColor.cgColor
        view.layer?.shadowOpacity = 0.65
        view.layer?.shadowRadius = 18
        view.layer?.shadowOffset = .zero
        view.layer?.masksToBounds = false
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
