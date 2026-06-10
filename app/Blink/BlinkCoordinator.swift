import AppKit
import Combine
import CryptoKit
import Foundation
import OSLog
import ScreenCaptureKit

final class BlinkCoordinator: @unchecked Sendable {
    private struct CapturedFrame {
        let index: Int
        let pngURL: URL
        let capturedAt: Date
        let captureMS: Int
        let windowID: CGWindowID
        let screenshotMeta: [String: Any]
        let imageDiagnostics: [String: Any]
        let sha256: String
        let thumbnail: NSImage?
        let frontmostApp: [String: Any]
        /// The AppKit-screen rect (points) that this captured PNG
        /// covers. Used by `ScreenAnnotator` to translate caret /
        /// mouse / focused-bounds points into image pixels. Sourced
        /// from `ScreenCapture.Capture.windowFramePoints` — the same
        /// struct that produced the PNG bytes — so the rect can't
        /// drift from the image (a separate AX query could).
        let captureRectPoints: CGRect
        /// Selection text harvested at the same instant as this frame,
        /// when the source app exposed one. Captured on the capture
        /// queue *before* Blink's overlay activates so the AX query
        /// (and any synthesized Cmd+C) targets the source app.
        let selection: SelectionCapture.Selection?
    }

    private struct CaptureSession {
        let requestID: String
        let startedAt: Date
        let startedPerf: DispatchTime
        let runtime: RuntimeConfigFile
        let clientMetadata: [String: Any]
        var frontmostApp: [String: Any]
        let staging: URL
        var frames: [CapturedFrame]
        var collectingTimer: DispatchSourceTimer?
    }

    private struct CapturedFrameResult {
        let frame: CapturedFrame
        let shareableContent: SCShareableContent
    }

    private struct InflightSubmission {
        let token: UUID
        let requestID: String
        var run: PythonRunner.StreamingRun?
    }

    private struct FollowUpTurn {
        let instruction: String
        let tldr: String
        let suggestions: [SuggestionDetail]
    }

    private struct TLDREntry {
        let tldr: String
    }

    private struct ChimeLatencyDetails {
        let segmentAMS: Int
        let segmentBMS: Int
        let segmentCMS: Int
        let totalMS: Int
        let pressIndex: Int
        let launchAgeMS: Int
        let soundsOn: Bool

        var eventDetails: [String: Any] {
            [
                "chime_segment_a_ms": segmentAMS,
                "chime_segment_b_ms": segmentBMS,
                "chime_segment_c_ms": segmentCMS,
                "chime_total_ms": totalMS,
                "press_index": pressIndex,
                "launch_age_ms": launchAgeMS,
                "sounds_on": soundsOn,
            ]
        }
    }

    private let latencyLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.henryz2004.blink",
        category: "latency"
    )

    private let config: Config
    private let runtimeStore: RuntimeConfigStore
    private let eventClient: BlinkEventClient
    private let summaryHotkey: Hotkey
    private let soundEffects: SoundEffects
    private let launchedAt: DispatchTime
    private let queue = DispatchQueue(label: "blink.coordinator", qos: .userInitiated)
    private let submitQueue = DispatchQueue(label: "blink.coordinator.submit", qos: .userInitiated)
    private let overlay = SuggestionsOverlay()
    private let glassLoading = GlassCaptureLoadingController()
    // True while the glass loading lens is on screen. Glass mode suppresses the
    // SuggestionsPanel during loading, so this is the only signal that an
    // in-flight request is being shown — used to keep the global Esc tap armed
    // (via the overlay-active mirror) so Esc still cancels mid-stream. Main
    // thread only.
    private var glassLoadingActive = false
    /// AppKit-screen rect the glass lens is currently presented at. Tracked so
    /// the submit path can tell whether the precise captured rect differs
    /// materially from the instant-ack rect the lens was first shown at (at
    /// hotkey time, before capture) and only re-anchor when it does. Main-thread
    /// only, like `glassLoadingActive`.
    private var glassLoadingPresentedRect: NSRect?
    private var currentSuggestions: [String] = []
    private var currentSuggestionDetails: [SuggestionDetail] = []
    private var currentBundleDir: URL?
    private var currentRequestID: String?
    /// Bundle id of the app the current overlay's capture came from. Drives the
    /// overlay ⌘T reasoning toggle's per-surface persistence. Set at capture
    /// time; survives rerolls (same surface).
    private var currentSurfaceBundleID: String?
    private var followUpHistory: [FollowUpTurn] = []
    private var tldrHistory: [TLDREntry] = []
    private var currentTldrIndex: Int = 0
    // Tracks the request ID for which a terminal event (copied / inserted /
    // paste_failed flow) has already been emitted, so a follow-on dismissOverlay
    // call during the close/insert animation does not emit a redundant
    // suggestion_dismissed and overwrite the server-side outcome.
    private var terminalEmittedRequestID: String?
    private var currentStreamingRun: PythonRunner.StreamingRun?
    // Token for the in-flight Python submission. Used by the double-tap
    // promotion path to mark a specific submission as cancelled without
    // affecting any later submission that reuses the same requestID.
    private var currentSubmission: InflightSubmission?
    private var cancelledSubmissionTokens: Set<UUID> = []
    private var choiceState = SuggestionChoiceState(suggestionCount: 0)
    private var running = false
    private var session: CaptureSession?
    private var pendingDoubleTap: CaptureSession?
    private var doubleTapTimer: DispatchSourceTimer?
    private var pendingDoubleTapRequestID: String?
    private let collectingStateLock = NSLock()
    private var collectingState = false
    private let overlayActiveLock = NSLock()
    private var overlayActiveValue = false
    private let customInputActiveLock = NSLock()
    private var customInputActiveValue = false
    private let overlayPinnedLock = NSLock()
    private var overlayPinnedValue = false
    private let overlayInsertConsumeLock = NSLock()
    private var overlayInsertConsumesReturnValue = false
    private var overlayKeySuggestionCount = 0
    private var overlayKeyAllowsCustomInput = true
    private let doubleTapWindowMS = 400
    private let collectingTimeoutSeconds = 8
    private let maxCapturedFrames = 8

    /// Snapshot of the most recently dismissed (but not picked-or-pinned)
    /// run. Persisted in-memory between dismiss and the next hotkey press
    /// so an accidental Esc + immediate retry restores the prior chat
    /// without re-capturing. All access is on the main thread (mutated
    /// from `dismissOverlay` (@MainActor) and `summarizeFrontmostWindow`
    /// (invoked from `DispatchQueue.main.async` in HotkeyManager)).
    private var lastDismissedSession: LastDismissedSession?
    private var lastDismissedSessionExpiry: DispatchSourceTimer?
    /// Auto-resume window. Tight (~3s) on purpose: the goal is to catch
    /// "oh shit, I didn't mean to dismiss that" moments without auto-
    /// restoring a chat the user has mentally moved on from. Esc dismisses
    /// (`dismissedExplicitly = true`) are never auto-resumed regardless
    /// of age — Esc is the "I'm done" signal.
    private let autoResumeWindowSeconds: TimeInterval = 3

    private struct LastDismissedSession {
        let dismissedAt: Date
        let bundleDir: URL?
        let suggestions: [String]
        let suggestionDetails: [SuggestionDetail]
        let tldr: String
        let customInputText: String
        let frontmostApp: [String: Any]
        let priorRequestID: String?
        /// True for Esc dismiss; false for outside-click ("accidental").
        /// Only `false` snapshots are eligible for auto-resume on next
        /// hotkey press.
        let dismissedExplicitly: Bool
        /// Context fingerprint at dismiss time. Auto-resume requires both
        /// to match the current frontmost — same app *and* same window.
        let frontmostBundleID: String?
        let frontmostWindowTitle: String?
        /// Last-submitted-run context, preserved across dismiss so that
        /// auto-resume + hotkey-to-add-frame keeps working (otherwise
        /// the resumed chat can't be extended with another capture).
        let submittedRun: SubmittedRunContext?
    }

    /// Snapshot of the just-submitted capture so that a hotkey press
    /// while suggestions are visible can rebuild a `CaptureSession` from
    /// the prior frames (added to, not replaced) and enter the collecting
    /// overlay for a multi-frame follow-up. Populated by `submitSession`
    /// before the active session is cleared, replaced by each new submit,
    /// and dropped on dismiss.
    private struct SubmittedRunContext {
        let staging: URL
        let frames: [CapturedFrame]
        let runtime: RuntimeConfigFile
        let clientMetadata: [String: Any]
        let frontmostApp: [String: Any]
    }
    private var lastSubmittedRun: SubmittedRunContext?

    /// While the modal multi-frame mode is open from suggestions, this
    /// holds the chat to restore on Esc. Cleared on successful submit
    /// (the new run replaces it) or on intentional dismiss.
    private var modalChatSnapshot: LastDismissedSession?

    private var captureHotkeyPressIndex = 0

    var onStatusChange: ((String) -> Void)?
    var onFailureNotice: ((String, String) -> Void)?
    var onPermissionsNeeded: (() -> Void)?
    /// Fires when a summary completes its overlay-shown moment (success) or
    /// hits a user-visible failure. Used by the onboarding demo card to know
    /// whether the user's first hotkey press actually produced a result.
    var onSummaryCompleted: ((Bool) -> Void)?
    /// Fires when the user picks a suggestion (1/2/3 / equivalent). Index is
    /// zero-based. Used by the onboarding demo card to record first-paste.
    var onSuggestionPicked: ((Int) -> Void)?

    /// Combine subject for surfaces that want to subscribe rather than own
    /// the callback (the menubar already owns `onStatusChange`). Mirrors what
    /// `status(_:)` sends — last-write-wins, replays the current value to
    /// new subscribers via `CurrentValueSubject`.
    let statusSubject = CurrentValueSubject<String, Never>("Idle")

    init(
        config: Config,
        runtimeStore: RuntimeConfigStore,
        eventClient: BlinkEventClient,
        summaryHotkey: Hotkey,
        soundEffects: SoundEffects,
        launchedAt: DispatchTime
    ) {
        self.config = config
        self.runtimeStore = runtimeStore
        self.eventClient = eventClient
        self.summaryHotkey = summaryHotkey
        self.soundEffects = soundEffects
        self.launchedAt = launchedAt
        self.overlay.onVisibilityChange = { [weak self] active in
            self?.setOverlayActiveMirror(active)
        }
    }

    var isOverlayActive: Bool {
        overlayActiveLock.lock()
        defer { overlayActiveLock.unlock() }
        return overlayActiveValue
    }

    var isCustomInputActive: Bool {
        customInputActiveLock.lock()
        defer { customInputActiveLock.unlock() }
        return customInputActiveValue
    }

    var isCollectingActive: Bool {
        collectingStateLock.lock()
        defer { collectingStateLock.unlock() }
        return collectingState
    }

    var shouldConsumeOverlayInsertKey: Bool {
        overlayInsertConsumeLock.lock()
        defer { overlayInsertConsumeLock.unlock() }
        return overlayInsertConsumesReturnValue
    }

    var isOverlayPinned: Bool {
        overlayPinnedLock.lock()
        defer { overlayPinnedLock.unlock() }
        return overlayPinnedValue
    }

    private func setOverlayPinnedMirror(_ pinned: Bool) {
        overlayPinnedLock.lock()
        overlayPinnedValue = pinned
        overlayPinnedLock.unlock()
    }

    static func clientMetadata() -> [String: Any] {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        let name = info["CFBundleName"] as? String ?? "Blink"
        return [
            "app_name": name,
            "app_version": version,
            "app_build": build,
            "bundle_id": Bundle.main.bundleIdentifier ?? "com.henryz2004.blink",
            "install_id": Paths.loadOrCreateInstallID(),
            "platform": "macOS",
            "platform_version": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
    }

    /// Per-invocation client metadata. Currently identical to the static
    /// snapshot; kept as an instance method so per-invocation context can be
    /// merged in here if needed.
    func clientMetadata() -> [String: Any] {
        Self.clientMetadata()
    }

    /// The active summary hotkey. Read-only mirror so surfaces (e.g. the
    /// permissions wizard) can render up-to-date copy without owning the
    /// HotkeyManager.
    var currentHotkey: Hotkey { summaryHotkey }

    /// Warm the capture-feedback surfaces — the chime's audio route and the
    /// glass lens's SwiftUI / Liquid Glass render — at launch, off the hot path,
    /// so the *first* capture after launch doesn't pay their one-time first-use
    /// cost as an audible / visible lag. Main thread.
    @MainActor
    func prewarmCaptureFeedback() {
        soundEffects.prewarm()
        glassLoading.prewarm(speed: runtimeStore.lensAnimationSpeed)
    }

    private func setOverlayActiveMirror(_ active: Bool) {
        overlayActiveLock.lock()
        overlayActiveValue = active
        overlayActiveLock.unlock()
    }

    /// Present the glass loading lens and arm the global Esc tap. In glass mode
    /// the SuggestionsPanel never shows during loading, so `onVisibilityChange`
    /// never fires the overlay-active mirror; set it here so the CGEventTap
    /// still routes Esc to `dismissOverlay` (which cancels the in-flight run).
    /// - Parameter armKeyTap: when true, arms the global Esc key-tap mirror so
    ///   Esc cancels the in-flight run. The instant-ack presentation (at hotkey
    ///   time, before capture) passes `false`: there is no run to cancel yet,
    ///   and leaving the mirror disarmed keeps the double-tap-to-multiframe
    ///   window open during capture. The submit path arms it once the run is
    ///   about to stream.
    private func presentGlassLoading(windowRect: NSRect, speed: Double, armKeyTap: Bool = true) {
        // The submit path (armKeyTap == true) re-presenting over a live lens is a
        // re-anchor: the precise captured rect arrived after the instant-ack guess
        // and differs (notably in fullscreen, where the cheap CGWindowList rect is
        // the window minus the menu bar while the capture is the full display).
        // Reposition WITHOUT restarting the drain, or the user sees the animation
        // replay ("double lens"). The instant-ack (armKeyTap == false) always
        // starts fresh — it begins a new capture, even if a prior capture's lens
        // is somehow still up — so it must not continue an older drain.
        let isReanchor = glassLoadingActive && armKeyTap
        glassLoadingActive = true
        glassLoadingPresentedRect = windowRect
        if armKeyTap {
            setOverlayActiveMirror(true)
        }
        // If the request hangs and the 90s backstop tears the panel down on its
        // own, clear the armed key-tap mirror so it can't keep swallowing keys
        // with nothing on screen. (Normal dismiss/result/cancel paths go through
        // dismissGlassLoading and never reach this.)
        glassLoading.onBackstop = { [weak self] in
            guard let self else { return }
            self.glassLoadingActive = false
            self.glassLoadingPresentedRect = nil
            if !self.overlay.isVisible {
                self.setOverlayActiveMirror(false)
            }
        }
        // `speed` is supplied by the caller (from the @MainActor store at hotkey
        // time, or the captured Sendable runtime at submit) so a Settings change
        // to Loading animation speed takes effect on the very next capture.
        if isReanchor {
            glassLoading.reanchor(to: windowRect, speed: speed)
        } else {
            glassLoading.show(windowRect: windowRect, speed: speed)
        }
    }

    /// Tear down the glass loading lens. Clears the overlay-active mirror only
    /// when no result panel is on screen — on the loading→result hand-off the
    /// panel's own `show()` re-arms the mirror immediately after.
    private func dismissGlassLoading() {
        glassLoading.dismiss()
        glassLoadingActive = false
        glassLoadingPresentedRect = nil
        if !overlay.isVisible {
            setOverlayActiveMirror(false)
        }
    }

    /// Fire the immediate capture acknowledgment, paired with the chime in
    /// `acknowledgeCaptureHotkey`, so the user gets a *visual* response at
    /// key-down instead of only after the SCShareableContent capture finishes.
    /// Anchored to a cheap CGWindowList rect — no capture pipeline — so it can
    /// run synchronously on the main thread at hotkey time. Returns true iff a
    /// visual was shown, so the caller can suppress the post-capture flash for
    /// that frame and avoid a double indicator.
    ///
    ///   glass on  → present the loading lens now (the same lens the result
    ///               hands off from). The capture excludes Blink's own windows,
    ///               so the lens never lands in the screenshot.
    ///   glass off → the brand-blue capture outline. (The user explicitly
    ///               disliked the outline *with* glass, so it stays off there.)
    @MainActor
    private func presentInstantCaptureAck(pressedAt: DispatchTime) -> Bool {
        let ownPID = NSRunningApplication.current.processIdentifier
        let glass = RuntimeEnvironment.glassLoadingEnabled()
        let cgRect = ScreenCapture.frontmostCapturableWindowRect(excluding: ownPID)

        // FAST PATH: a substantial on-screen window is almost certainly the content
        // we'll capture — anchor the lens there directly with NO Accessibility call,
        // so the instant-ack stays a ~1-5ms CGWindowList lookup. Only when the cheap
        // path can't see a plausible content window — nil, or a thin strip much
        // shorter than the screen — do we escalate to the AX probe. That strip is
        // the tell that the real window is FULLSCREEN in its own Space (Edge reports
        // a ~116pt top strip); CGWindowList can't see the fullscreen content window
        // from Blink's Space. The size check here only ROUTES whether to probe — the
        // AX probe is the authority, and a wrong route only costs latency (a probe),
        // never correctness. (Probing unconditionally added 20-330ms to every
        // capture, varying with the target app's AX responsiveness — a regression.)
        let activeFrame = NSScreen.main?.frame
        let cheapLooksLikeContent: Bool = {
            guard let r = cgRect else { return false }
            guard let s = activeFrame, s.height > 0 else { return true }
            return r.height >= s.height * 0.33
        }()
        if !cheapLooksLikeContent,
           let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           frontPID != ownPID,
           ScreenCapture.focusedWindowAXProbe(for: frontPID).isFullscreen,
           let display = activeFrame, display.height > 0 {
            if glass {
                presentGlassLoading(windowRect: display, speed: runtimeStore.lensAnimationSpeed, armKeyTap: false)
            } else {
                CaptureConfirmationOverlay.flash(frame: CGRect(origin: .zero, size: display.size))
            }
            latencyLogger.info(
                "instant_ack shown=\(true, privacy: .public) glass=\(glass, privacy: .public) anchor=fullscreen_display press_to_visual_ms=\(self.durationMS(from: pressedAt, to: self.monotonicNow()), privacy: .public)"
            )
            return true
        }

        guard let cgRect else {
            latencyLogger.info("instant_ack shown=\(false, privacy: .public) reason=no_window")
            return false
        }
        guard let screenFrame = NSScreen.screens.first?.frame, screenFrame.height > 0 else {
            latencyLogger.info("instant_ack shown=\(false, privacy: .public) reason=no_screen")
            return false
        }
        if glass {
            // CGWindow bounds are CG-global (top-left origin, +Y down); the lens
            // panel wants AppKit-screen coords (bottom-left, +Y up). Flip against
            // the primary screen height — same convention as
            // `captureRectInAppKitScreen`, inlined because we're already on the
            // main thread (that helper hops via DispatchQueue.main.sync and would
            // deadlock here).
            let appKitRect = NSRect(
                x: cgRect.origin.x,
                y: screenFrame.height - cgRect.maxY,
                width: cgRect.width,
                height: cgRect.height
            )
            presentGlassLoading(
                windowRect: appKitRect,
                speed: runtimeStore.lensAnimationSpeed,
                armKeyTap: false
            )
        } else {
            CaptureConfirmationOverlay.flash(frame: cgRect)
        }
        latencyLogger.info(
            "instant_ack shown=\(true, privacy: .public) glass=\(glass, privacy: .public) press_to_visual_ms=\(self.durationMS(from: pressedAt, to: self.monotonicNow()), privacy: .public)"
        )
        return true
    }

    /// True when two rects are within `tolerance` points on every edge. Used to
    /// decide whether the precise captured rect is close enough to the
    /// instant-ack rect that the already-presented lens needn't be re-anchored.
    private static func rectsApproximatelyEqual(
        _ a: CGRect,
        _ b: CGRect,
        tolerance: CGFloat = 8
    ) -> Bool {
        abs(a.origin.x - b.origin.x) <= tolerance
            && abs(a.origin.y - b.origin.y) <= tolerance
            && abs(a.width - b.width) <= tolerance
            && abs(a.height - b.height) <= tolerance
    }

    private func setCustomInputActiveMirror(_ active: Bool) {
        customInputActiveLock.lock()
        customInputActiveValue = active
        customInputActiveLock.unlock()
    }

    private func setOverlayKeyState(
        suggestionCount: Int,
        allowsCustomInput: Bool,
        consumesReturn: Bool
    ) {
        overlayInsertConsumeLock.lock()
        overlayKeySuggestionCount = max(0, suggestionCount)
        overlayKeyAllowsCustomInput = allowsCustomInput
        overlayInsertConsumesReturnValue = consumesReturn
        overlayInsertConsumeLock.unlock()
    }

    private func setOverlayInsertConsumesReturn(_ consumes: Bool) {
        overlayInsertConsumeLock.lock()
        overlayInsertConsumesReturnValue = consumes
        overlayInsertConsumeLock.unlock()
    }

    private func resetChoiceState(
        suggestionCount: Int,
        allowsCustomInput: Bool = true,
        consumesReturnWhileLoading: Bool = false
    ) {
        choiceState = SuggestionChoiceState(
            suggestionCount: suggestionCount,
            allowsCustomInput: allowsCustomInput
        )
        setCustomInputActiveMirror(choiceState.customInputActive)
        overlay.setCustomInputArmedHighlight(false)
        setOverlayKeyState(
            suggestionCount: suggestionCount,
            allowsCustomInput: allowsCustomInput,
            consumesReturn: consumesReturnWhileLoading
        )
    }

    private func applyChoiceNumber(_ index: Int) -> SuggestionChoiceState.NumberAction {
        let action = choiceState.pressNumber(index: index)
        setCustomInputActiveMirror(choiceState.customInputActive)
        setOverlayInsertConsumesReturn(choiceState.pressReturn() != .propagate)
        return action
    }

    private func setCustomInputActive(_ active: Bool) {
        choiceState.setCustomInputActive(active)
        setCustomInputActiveMirror(choiceState.customInputActive)
        setOverlayInsertConsumesReturn(choiceState.pressReturn() != .propagate)
    }

    func preflightOverlayChoiceKey(index: Int) {
        // The event-tap thread may see Return before main has processed the
        // preceding number key. Mirror just enough state to keep that path
        // nonblocking without leaking the Return through.
        overlayInsertConsumeLock.lock()
        if index >= 0 && index < overlayKeySuggestionCount {
            overlayInsertConsumesReturnValue = true
        } else if index == 3 && overlayKeyAllowsCustomInput {
            overlayInsertConsumesReturnValue = false
        }
        overlayInsertConsumeLock.unlock()
    }

    private static func requiredPermissionsGranted(caller: String) -> Bool {
        let accessibility = AXIsProcessTrusted()
        let screenRecording = CGPreflightScreenCaptureAccess()
        let inputMonitoring = HotkeyManager.inputMonitoringGranted()
        TCCDiagnostics.log(
            "required_permissions caller=\(caller) accessibility=\(accessibility) screen_recording_preflight=\(screenRecording) input_monitoring=\(inputMonitoring)"
        )
        return accessibility && screenRecording && inputMonitoring
    }

    @MainActor
    func summarizeFrontmostWindow(pressedAt: DispatchTime, summarizeEnteredAt: DispatchTime) {
        guard Self.requiredPermissionsGranted(caller: "BlinkCoordinator.summarizeFrontmostWindow") else {
            status("permissions needed")
            // HotkeyManager dispatches onSummarize on the main queue, so we
            // can show the wizard inline without another hop.
            onPermissionsNeeded?()
            return
        }
        // Auto-resume the just-dismissed chat when:
        //   - last dismiss was implicit (outside-click, not Esc)
        //   - within `autoResumeWindowSeconds` (~3s — only catches accidents)
        //   - same frontmost app *and* same focused window title
        // Outside that gate the hotkey is a normal fresh capture.
        if let snapshot = takeAutoResumeSnapshotIfEligible() {
            acknowledgeCaptureHotkey(
                pressedAt: pressedAt,
                summarizeEnteredAt: summarizeEnteredAt,
                statusText: "resumed last chat"
            )
            restoreLastDismissedSession(snapshot)
            return
        }
        acknowledgeCaptureHotkey(
            pressedAt: pressedAt,
            summarizeEnteredAt: summarizeEnteredAt,
            statusText: "capturing window..."
        )
        // Paired with the chime above: show the user a capture indicator now,
        // before the SCShareableContent pipeline runs. When shown, the frame's
        // post-capture confirmation flash is suppressed so they don't double up.
        // Skip it for a second tap inside the double-tap window — the first
        // tap's indicator is already up, and this tap promotes to multi-frame
        // collecting (which tears that indicator down).
        let instantAckShown = pendingDoubleTapRequestID == nil
            ? presentInstantCaptureAck(pressedAt: pressedAt)
            : false
        enqueueSummarize(instantAckShown: instantAckShown)
    }

    /// Returns the LDS snapshot iff it's eligible for auto-resume:
    /// implicit dismiss, within the window, same bundle, same window
    /// title. Consumes the snapshot on success.
    @MainActor
    private func takeAutoResumeSnapshotIfEligible() -> LastDismissedSession? {
        guard let snapshot = lastDismissedSession else { return nil }
        guard !snapshot.dismissedExplicitly else { return nil }
        let age = Date().timeIntervalSince(snapshot.dismissedAt)
        guard age <= autoResumeWindowSeconds else {
            clearLastDismissedSession()
            return nil
        }
        let currentMeta = frontmostAppMetadata()
        let currentBundle = currentMeta["bundle_id"] as? String
        let currentTitle = currentMeta["window_title"] as? String
        guard let snapshotBundle = snapshot.frontmostBundleID,
              !snapshotBundle.isEmpty,
              snapshotBundle == currentBundle else {
            return nil
        }
        // Require both sides to have a title and match — strictness here
        // is on purpose: same app + different window should not resume.
        guard let snapshotTitle = snapshot.frontmostWindowTitle,
              !snapshotTitle.isEmpty,
              snapshotTitle == currentTitle else {
            return nil
        }
        lastDismissedSession = nil
        lastDismissedSessionExpiry?.cancel()
        lastDismissedSessionExpiry = nil
        return snapshot
    }

    private func armResumeExpiryTimer() {
        lastDismissedSessionExpiry?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + autoResumeWindowSeconds)
        timer.setEventHandler { [weak self] in
            self?.clearLastDismissedSession()
        }
        lastDismissedSessionExpiry = timer
        timer.resume()
    }

    private func clearLastDismissedSession() {
        lastDismissedSession = nil
        lastDismissedSessionExpiry?.cancel()
        lastDismissedSessionExpiry = nil
    }

    /// Wires the full set of overlay interaction callbacks. Every path that
    /// (re)presents the result panel — fresh result, reroll, and
    /// restore-after-dismiss — must install the identical set, so this is
    /// the single place they are assigned. (The three previously copy-pasted
    /// blocks had already diverged: the restore path omitted `onArrowKey`,
    /// killing arrow-nav after auto-resume.)
    @MainActor
    private func wireOverlayCallbacks() {
        overlay.onCustomInputFocusChanged = { [weak self] active in
            self?.setCustomInputActive(active)
        }
        overlay.onCustomInsert = { [weak self] text in
            self?.insertCustomReply(text: text)
        }
        overlay.onCustomFollowUp = { [weak self] text in
            self?.rerollCurrentSuggestions(followUpInstruction: text)
        }
        overlay.onChoiceKey = { [weak self] index in
            self?.chooseSuggestion(index: index)
        }
        overlay.onArrowKey = { [weak self] direction in
            self?.handleArrowNav(direction)
        }
        overlay.onInsertKey = { [weak self] in
            self?.insertExpandedSuggestion() ?? false
        }
        overlay.onCustomInsertKey = { [weak self] in
            _ = self?.submitCustomInputFromInput()
            return true
        }
        overlay.onLeaveCustomInputKey = { [weak self] in
            self?.leaveCustomInput()
        }
        overlay.onTextEditingKey = { [weak self] shortcut in
            self?.performCustomInputShortcut(shortcut) ?? false
        }
        overlay.onRerollKey = { [weak self] in
            self?.rerollCurrentSuggestions()
        }
        overlay.onTogglePinKey = { [weak self] in
            guard let self else { return }
            self.overlay.setPinned(!self.overlay.isPinned)
        }
        overlay.onCycleThinkingKey = { [weak self] in
            self?.cycleThinkingForCurrentSurface()
        }
        overlay.onSetReasoning = { [weak self] level in
            self?.setReasoningForCurrentSurface(level)
        }
        overlay.reasoningOverrideValue = { [weak self] in
            guard let self, let bundle = self.currentSurfaceBundleID else { return nil }
            return self.runtimeStore.appThinkingLevels[bundle]
        }
        overlay.onPinnedChanged = { [weak self] pinned in
            self?.setOverlayPinnedMirror(pinned)
        }
        overlay.onDismissKey = { [weak self] in
            self?.dismissOverlay()
        }
        overlay.onOutsideClickDismiss = { [weak self] in
            self?.dismissOverlay(implicit: true)
        }
    }

    @MainActor
    private func restoreLastDismissedSession(_ snapshot: LastDismissedSession) {
        let resumedRequestID = "resumed-" + UUID().uuidString.lowercased()
        currentRequestID = resumedRequestID
        currentSuggestions = snapshot.suggestions
        currentSuggestionDetails = snapshot.suggestionDetails
        currentBundleDir = snapshot.bundleDir
        // Restore the submitted-run context so a follow-up hotkey on the
        // resumed chat can still enter modal multi-frame. Without this,
        // `handleSummaryHotkeyWhileOverlay` falls into the "nothing to
        // add to" branch on auto-resumed chats.
        lastSubmittedRun = snapshot.submittedRun
        terminalEmittedRequestID = nil
        resetChoiceState(suggestionCount: snapshot.suggestions.count)

        wireOverlayCallbacks()
        overlay.show(
            tldr: snapshot.tldr,
            suggestionDetails: snapshot.suggestionDetails
        )
        if !snapshot.customInputText.isEmpty {
            overlay.restoreCustomInputText(snapshot.customInputText)
        }
        soundEffects.play(.resultReady)
        emitEvent(
            requestID: resumedRequestID,
            type: "run_resumed",
            allowLogging: runtimeStore.allowEventLogging,
            clientMetadata: Self.clientMetadata(),
            details: [
                "prior_request_id": snapshot.priorRequestID as Any,
                "resume_age_seconds": Int(Date().timeIntervalSince(snapshot.dismissedAt)),
            ]
        )
    }

    @MainActor
    func handleSummaryHotkeyWhileOverlay(pressedAt: DispatchTime, summarizeEnteredAt: DispatchTime) {
        // Already in the collecting overlay: existing append-a-frame path.
        if isCollectingActive {
            acknowledgeCaptureHotkey(
                pressedAt: pressedAt,
                summarizeEnteredAt: summarizeEnteredAt,
                statusText: nil
            )
            queue.async { [self] in appendFrameToSession() }
            return
        }
        // Streaming / model thinking: refuse until the run lands. Avoids
        // racing the in-flight stream against a brand-new submission.
        if currentStreamingRun?.isRunning == true {
            status("still thinking — try again in a moment")
            return
        }
        // Suggestions visible with a prior run on record: enter modal
        // multi-frame. Snapshot the chat so Esc can restore it, rebuild
        // a CaptureSession from the prior run's frames + staging, then
        // capture a new frame appended to that list.
        guard !currentSuggestions.isEmpty, let prior = lastSubmittedRun else {
            status("nothing to add to")
            return
        }
        // The modal multi-frame Esc-restore path is internal — it only
        // ever round-trips through `restoreLastDismissedSession`, never
        // through the hotkey auto-resume gate. So the dismissed/bundle/
        // title fields don't have to be accurate; nil/false is fine.
        modalChatSnapshot = LastDismissedSession(
            dismissedAt: Date(),
            bundleDir: currentBundleDir,
            suggestions: currentSuggestions,
            suggestionDetails: currentSuggestionDetails,
            tldr: overlay.summaryFullText,
            customInputText: overlay.customInputText,
            frontmostApp: prior.frontmostApp,
            priorRequestID: currentRequestID,
            dismissedExplicitly: true,
            frontmostBundleID: nil,
            frontmostWindowTitle: nil,
            submittedRun: lastSubmittedRun
        )
        let newRequestID = UUID().uuidString.lowercased()
        currentRequestID = newRequestID
        // Old streaming/submission state is already settled at this point
        // (we guarded on `currentStreamingRun?.isRunning` above), but
        // clear refs so the new session starts clean.
        currentSubmission = nil
        currentStreamingRun = nil
        acknowledgeCaptureHotkey(
            pressedAt: pressedAt,
            summarizeEnteredAt: summarizeEnteredAt,
            statusText: nil
        )
        queue.async { [self, prior, newRequestID] in
            guard !running else {
                status("already working")
                return
            }
            session = CaptureSession(
                requestID: newRequestID,
                startedAt: Date(),
                startedPerf: monotonicNow(),
                runtime: prior.runtime,
                clientMetadata: prior.clientMetadata,
                frontmostApp: prior.frontmostApp,
                staging: prior.staging,
                frames: prior.frames,
                collectingTimer: nil
            )
            appendFrameToSession()
        }
    }

    /// Esc inside modal multi-frame restores the chat snapshot instead
    /// of tearing down the staging dir (which is shared with the prior
    /// run on record). The just-captured frame becomes an orphan PNG
    /// inside `prior.staging` — the OS will clean up /tmp.
    @MainActor
    func cancelCollectingFromUI() {
        if let snapshot = modalChatSnapshot {
            modalChatSnapshot = nil
            queue.async { [self] in
                if let active = session {
                    active.collectingTimer?.cancel()
                    session = nil
                    setCollectingActive(false)
                }
                DispatchQueue.main.async {
                    self.overlay.dismissSubmitPrompt()
                    self.restoreLastDismissedSession(snapshot)
                }
            }
            return
        }
        cancelCollectingSession()
    }

    private func enqueueSummarize(instantAckShown: Bool) {
        queue.async { [self] in
            if pendingDoubleTap != nil {
                // Second tap promotes to multi-frame; the lens (if any) is torn
                // down inside promoteToMultiFrame as the collecting overlay opens.
                promoteToMultiFrame()
                return
            }
            guard !running else {
                status("already working")
                if instantAckShown { DispatchQueue.main.async { self.dismissGlassLoading() } }
                return
            }
            if session == nil {
                startCaptureSession(instantAckShown: instantAckShown)
            } else {
                // Rare: a fresh-capture hotkey landed here with a session still
                // open. Drop the instant lens (this becomes an append, not a
                // submit) and add the frame.
                if instantAckShown { DispatchQueue.main.async { self.dismissGlassLoading() } }
                appendFrameToSession()
            }
        }
    }

    @MainActor
    private func acknowledgeCaptureHotkey(
        pressedAt: DispatchTime,
        summarizeEnteredAt: DispatchTime,
        statusText: String?
    ) {
        // Runs synchronously on the main thread — every caller is @MainActor.
        // The chime is the very first thing on key-down: nothing (not a runloop
        // hop, not telemetry) sits between the press and the sound. The previous
        // `DispatchQueue.main.async` wrapper deferred the sound a full runloop
        // turn, which on a busy/slow main thread read as audible lag.
        let acknowledgeStartedAt = monotonicNow()
        let soundsOn = runtimeStore.soundsEnabled
        soundEffects.play(.capture)
        let soundReturnedAt = monotonicNow()

        if let statusText {
            onStatusChange?(statusText)
            statusSubject.send(statusText)
        }
        captureHotkeyPressIndex += 1
        let pressIndex = captureHotkeyPressIndex

        // Telemetry is deferred off the hot path so a log write or event enqueue
        // can never land between the press and the feedback.
        let details = ChimeLatencyDetails(
            segmentAMS: durationMS(from: pressedAt, to: summarizeEnteredAt),
            segmentBMS: durationMS(from: summarizeEnteredAt, to: acknowledgeStartedAt),
            segmentCMS: durationMS(from: acknowledgeStartedAt, to: soundReturnedAt),
            totalMS: durationMS(from: pressedAt, to: soundReturnedAt),
            pressIndex: pressIndex,
            launchAgeMS: durationMS(from: launchedAt, to: pressedAt),
            soundsOn: soundsOn
        )
        DispatchQueue.main.async {
            self.latencyLogger.info(
                "chime_lag press=\(details.pressIndex, privacy: .public) launch_age_ms=\(details.launchAgeMS, privacy: .public) a=\(details.segmentAMS, privacy: .public) b=\(details.segmentBMS, privacy: .public) c=\(details.segmentCMS, privacy: .public) total=\(details.totalMS, privacy: .public) sounds_on=\(details.soundsOn, privacy: .public)"
            )
            self.eventClient.send(
                requestID: UUID().uuidString.lowercased(),
                eventType: "chime_latency",
                allowLogging: self.runtimeStore.allowEventLogging,
                clientMetadata: Self.clientMetadata(),
                details: details.eventDetails
            )
        }
    }

    func submitCollectingSession() {
        queue.async { [self] in
            submitSession()
        }
    }

    func cancelCollectingSession() {
        queue.async { [self] in
            cancelActiveSession(statusText: "cancelled")
        }
    }

    /// Called from `dismissOverlay` (main) to clean up coordinator-owned
    /// pending double-tap state when the user dismisses while a single-shot
    /// submission is in flight but still inside the double-tap window.
    /// Does NOT remove the staging directory: the Python subprocess may
    /// still be reading the request envelope and screenshot files until
    /// SIGTERM lands. Orphans in `/tmp` get cleaned up by the OS.
    func clearPendingDoubleTap() {
        queue.async { [self] in
            guard pendingDoubleTap != nil else { return }
            doubleTapTimer?.cancel()
            doubleTapTimer = nil
            pendingDoubleTap = nil
        }
    }

    private func setCollectingActive(_ active: Bool) {
        collectingStateLock.lock()
        collectingState = active
        collectingStateLock.unlock()
    }

    private func cancelActiveSession(statusText: String) {
        guard let active = session else { return }
        active.collectingTimer?.cancel()
        session = nil
        // Defensive: a future caller could reach this path while a pending
        // double-tap is also armed (e.g. cancelling a freshly-promoted
        // session). Tear that down so the timer doesn't outlive us.
        doubleTapTimer?.cancel()
        doubleTapTimer = nil
        pendingDoubleTap = nil
        setCollectingActive(false)
        DispatchQueue.main.sync {
            if let submission = self.currentSubmission, submission.requestID == active.requestID {
                self.cancelledSubmissionTokens.insert(submission.token)
                submission.run?.terminate()
                self.currentSubmission = nil
            }
            self.currentStreamingRun = nil
        }
        try? FileManager.default.removeItem(at: active.staging)
        PendingRunStore.finish(requestID: active.requestID)
        emitEvent(
            requestID: active.requestID,
            type: "capture_cancelled",
            allowLogging: active.runtime.allowEventLogging,
            clientMetadata: active.clientMetadata,
            details: ["frame_count": active.frames.count]
        )
        status(statusText)
        DispatchQueue.main.async {
            self.overlay.close()
            self.overlay.dismissSubmitPrompt()
        }
    }

    /// - Parameter instantAckShown: true when `presentInstantCaptureAck` already
    ///   put a capture indicator on screen at hotkey time. The frame's
    ///   post-capture confirmation flash is then suppressed so the user doesn't
    ///   see two indicators, and any failure before submit tears the instant
    ///   lens back down.
    private func startCaptureSession(instantAckShown: Bool) {
        running = true
        defer { running = false }

        let (runtime, clientMetadata) = DispatchQueue.main.sync {
            (runtimeStore.snapshot, self.clientMetadata())
        }
        let frontmostApp = frontmostAppMetadata()
        let requestID = UUID().uuidString.lowercased()
        let startedAt = Date()
        let staging: URL
        do {
            staging = try makeStagingDir()
        } catch {
            if instantAckShown { DispatchQueue.main.async { self.dismissGlassLoading() } }
            reportFailure(
                title: "Blink Failed",
                statusText: "failed: \(shortErrorSummary(error))",
                detail: detailedErrorMessage(error)
            )
            return
        }
        let pendingPayload: [String: Any] = [
            "request_id": requestID,
            "started_at": JSONFiles.isoString(startedAt),
            "updated_at": JSONFiles.isoString(startedAt),
            "last_phase": "capture_started",
            "client": clientMetadata,
            "capture_mode": "frontmost_window",
            "input_mode": "screenshot",
            "frontmost_app": frontmostApp,
            "frames": [],
        ]
        do {
            try PendingRunStore.create(requestID: requestID, payload: pendingPayload)
            emitEvent(
                requestID: requestID,
                type: "capture_started",
                createdAt: JSONFiles.isoString(startedAt),
                allowLogging: runtime.allowEventLogging,
                clientMetadata: clientMetadata,
                details: ["frontmost_app": frontmostApp]
            )
            status("capturing window...")
            let frontmostPID = (frontmostApp["pid"] as? Int).map { pid_t($0) }
            // Suppress the post-capture flash when the instant ack already put an
            // indicator on screen at hotkey time (avoids a double indicator).
            let captureResult = try captureFrame(
                index: 0,
                staging: staging,
                preferredPID: frontmostPID,
                confirmCapture: !instantAckShown
            )
            let frame = captureResult.frame
            var sessionFrontmost = frame.frontmostApp
            if sessionFrontmost["bundle_id"] == nil, let bundle = frontmostApp["bundle_id"] {
                sessionFrontmost["bundle_id"] = bundle
            }
            if sessionFrontmost["app_name"] == nil, let name = frontmostApp["app_name"] {
                sessionFrontmost["app_name"] = name
            }
            // Per-app-surface reasoning: resolve the level for the captured
            // bundle (override or global) into this session's runtime, and
            // remember the bundle so the overlay's ⌘T toggle knows which
            // surface it's cycling. ⌘T only affects the NEXT capture, so this
            // session keeps whatever level was resolved at capture time.
            let sourceBundleID = sessionFrontmost["bundle_id"] as? String
            var sessionRuntime = runtime
            DispatchQueue.main.sync {
                sessionRuntime.thinkingLevel = self.runtimeStore.resolvedThinkingLevel(forBundle: sourceBundleID)
                self.currentSurfaceBundleID = sourceBundleID
            }
            // The per-app map is a client-side resolution table (it names the
            // apps you use); the resolved level is already baked into
            // `thinkingLevel`, so keep the map out of the per-request runtime.json.
            sessionRuntime.appThinkingLevels = [:]
            let active = CaptureSession(
                requestID: requestID,
                startedAt: startedAt,
                startedPerf: monotonicNow(),
                runtime: sessionRuntime,
                clientMetadata: clientMetadata,
                frontmostApp: sessionFrontmost,
                staging: staging,
                frames: [frame],
                collectingTimer: nil
            )
            recordFrameCaptured(active, frame: frame, mode: "frontmost_window")
            status("captured frame 1")
            // Single press is the most common case, so submit the session
            // immediately. The double-tap timer keeps the submission
            // promotable into multi-frame mode if a second tap arrives
            // within `doubleTapWindowMS`. Set the coord-queue and main
            // mirrors of the pending state together so dismissOverlay
            // (main) can never observe one without the other.
            pendingDoubleTap = active
            DispatchQueue.main.sync {
                self.pendingDoubleTapRequestID = requestID
            }
            armDoubleTapTimer(requestID: requestID)
            dispatchSubmit(active)
        } catch {
            if instantAckShown { DispatchQueue.main.async { self.dismissGlassLoading() } }
            try? FileManager.default.removeItem(at: staging)
            PendingRunStore.finish(requestID: requestID)
            emitEvent(
                requestID: requestID,
                type: failureEventType(for: error, lastPhase: "capture_started"),
                allowLogging: runtime.allowEventLogging,
                clientMetadata: clientMetadata,
                details: ["error": shortErrorSummary(error)]
            )
            reportFailure(
                title: "Blink Failed",
                statusText: "failed: \(shortErrorSummary(error))",
                detail: detailedErrorMessage(error)
            )
        }
    }

    private func dispatchSubmit(_ active: CaptureSession) {
        let token = UUID()
        // Stash the just-submitted run so a follow-up hotkey while
        // suggestions are visible can extend its frames with another
        // capture (modal multi-frame). Both the single-tap path
        // (`startCaptureSession`) and the collecting-mode path
        // (`submitSession`) funnel through here, so this is the one
        // place that guarantees both flows can append.
        let context = SubmittedRunContext(
            staging: active.staging,
            frames: active.frames,
            runtime: active.runtime,
            clientMetadata: active.clientMetadata,
            frontmostApp: active.frontmostApp
        )
        DispatchQueue.main.sync {
            // If an earlier submission is still streaming, abandon it so
            // it doesn't head-of-line-block this submit on the serial
            // submitQueue (and so its tail main blocks don't briefly
            // overwrite this submission's overlay state).
            if let inflight = self.currentSubmission {
                self.cancelledSubmissionTokens.insert(inflight.token)
                inflight.run?.terminate()
            }
            self.currentSubmission = InflightSubmission(
                token: token,
                requestID: active.requestID,
                run: nil
            )
            self.lastSubmittedRun = context
        }
        submitQueue.async { [self] in
            submitCapturedSession(active, submissionToken: token)
        }
    }

    private func promoteToMultiFrame() {
        guard var pending = pendingDoubleTap else { return }
        let requestID = pending.requestID
        doubleTapTimer?.cancel()
        doubleTapTimer = nil
        pendingDoubleTap = nil

        // Mark the in-flight submission cancelled and tear down its UI
        // state so the original submit's still-pending main blocks bail
        // out instead of clobbering the collecting overlay.
        DispatchQueue.main.sync {
            if let submission = self.currentSubmission, submission.requestID == requestID {
                self.cancelledSubmissionTokens.insert(submission.token)
                submission.run?.terminate()
                self.currentSubmission = nil
            }
            self.currentStreamingRun = nil
            self.currentRequestID = nil
            self.pendingDoubleTapRequestID = nil
            // The instant-ack lens (shown at the first tap, glass mode) is
            // superseded by the collecting overlay this promotion opens.
            self.dismissGlassLoading()
        }

        emitEvent(
            requestID: requestID,
            type: "capture_promoted_to_multiframe",
            allowLogging: pending.runtime.allowEventLogging,
            clientMetadata: pending.clientMetadata,
            details: ["frame_count": pending.frames.count]
        )

        running = true
        defer { running = false }
        do {
            status("capturing frame \(pending.frames.count + 1)...")
            let captureResult = try captureFrame(
                index: pending.frames.count,
                staging: pending.staging,
                shareableContent: nil,
                preferredPID: nil
            )
            let frame = captureResult.frame
            let isDuplicate: Bool
            if let previous = pending.frames.last, previous.windowID == frame.windowID {
                try replaceFrameFile(at: previous.pngURL, with: frame.pngURL)
                pending.frames[pending.frames.count - 1] = CapturedFrame(
                    index: previous.index,
                    pngURL: previous.pngURL,
                    capturedAt: frame.capturedAt,
                    captureMS: frame.captureMS,
                    windowID: frame.windowID,
                    screenshotMeta: frame.screenshotMeta,
                    imageDiagnostics: frame.imageDiagnostics,
                    sha256: frame.sha256,
                    thumbnail: frame.thumbnail,
                    frontmostApp: frame.frontmostApp,
                    captureRectPoints: frame.captureRectPoints,
                    selection: frame.selection
                )
                status("no new content — scroll first")
                isDuplicate = true
            } else {
                pending.frames.append(frame)
                status("collecting \(pending.frames.count) frames")
                isDuplicate = false
            }
            session = pending
            updatePendingFrames(pending)
            recordFrameCaptured(pending, frame: frame, mode: deriveCaptureMode(frames: pending.frames))
            let thumbnails = pending.frames.compactMap(\.thumbnail)
            let collectingMessage = collectingMessage(
                frames: pending.frames,
                duplicate: isDuplicate
            )
            DispatchQueue.main.async {
                self.overlay.showCollecting(
                    frameCount: pending.frames.count,
                    maxFrames: self.maxCapturedFrames,
                    hotkeyDisplay: self.summaryHotkey.displayString,
                    thumbnails: thumbnails,
                    message: collectingMessage,
                    flashLastThumbnail: isDuplicate
                )
            }
            armCollectingTimer(requestID: requestID)
        } catch {
            session = pending
            cancelActiveSession(statusText: "capture failed")
            reportFailure(
                title: "Blink Failed",
                statusText: "failed: \(shortErrorSummary(error))",
                detail: detailedErrorMessage(error)
            )
        }
    }

    private func armDoubleTapTimer(requestID: String) {
        doubleTapTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(doubleTapWindowMS))
        timer.setEventHandler { [weak self] in
            self?.doubleTapWindowExpired(requestID: requestID)
        }
        doubleTapTimer = timer
        timer.resume()
    }

    private func doubleTapWindowExpired(requestID: String) {
        guard let pending = pendingDoubleTap, pending.requestID == requestID else { return }
        pendingDoubleTap = nil
        doubleTapTimer = nil
        DispatchQueue.main.async {
            if self.pendingDoubleTapRequestID == requestID {
                self.pendingDoubleTapRequestID = nil
            }
        }
    }

    private func appendFrameToSession() {
        guard var active = session else { return }
        if active.frames.count >= maxCapturedFrames {
            status("max frames reached")
            session = active
            armCollectingTimer(requestID: active.requestID)
            let thumbnails = active.frames.compactMap(\.thumbnail)
            DispatchQueue.main.async {
                self.overlay.showCollecting(
                    frameCount: active.frames.count,
                    maxFrames: self.maxCapturedFrames,
                    hotkeyDisplay: self.summaryHotkey.displayString,
                    thumbnails: thumbnails,
                    message: "Max frames reached"
                )
            }
            return
        }
        running = true
        defer { running = false }
        do {
            status("capturing frame \(active.frames.count + 1)...")
            // Multi-frame is now an explicit double-tap mode that may span
            // any frontmost window or app. Re-query SCShareableContent on
            // every frame so windows from a different app surface as
            // capturable, and let `ScreenCapture` pick whatever is
            // frontmost right now.
            let captureResult = try captureFrame(
                index: active.frames.count,
                staging: active.staging,
                shareableContent: nil,
                preferredPID: nil
            )
            let frame = captureResult.frame
            let isDuplicate: Bool
            if let previous = active.frames.last, previous.sha256 == frame.sha256 {
                do {
                    try replaceFrameFile(at: previous.pngURL, with: frame.pngURL)
                } catch {
                    try? FileManager.default.removeItem(at: frame.pngURL)
                    throw error
                }
                active.frames[active.frames.count - 1] = CapturedFrame(
                    index: previous.index,
                    pngURL: previous.pngURL,
                    capturedAt: frame.capturedAt,
                    captureMS: frame.captureMS,
                    windowID: frame.windowID,
                    screenshotMeta: frame.screenshotMeta,
                    imageDiagnostics: frame.imageDiagnostics,
                    sha256: frame.sha256,
                    thumbnail: frame.thumbnail,
                    frontmostApp: frame.frontmostApp,
                    captureRectPoints: frame.captureRectPoints,
                    selection: frame.selection
                )
                status("no new content — scroll first")
                isDuplicate = true
            } else {
                active.frames.append(frame)
                status("collecting \(active.frames.count) frames")
                isDuplicate = false
            }
            session = active
            if let current = session {
                updatePendingFrames(current)
            }
            let thumbnails = active.frames.compactMap(\.thumbnail)
            let collectingMsg = collectingMessage(frames: active.frames, duplicate: isDuplicate)
            DispatchQueue.main.async {
                self.overlay.showCollecting(
                    frameCount: active.frames.count,
                    maxFrames: self.maxCapturedFrames,
                    hotkeyDisplay: self.summaryHotkey.displayString,
                    thumbnails: thumbnails,
                    message: collectingMsg,
                    flashLastThumbnail: isDuplicate
                )
            }
            armCollectingTimer(requestID: active.requestID)
        } catch {
            session = active
            cancelActiveSession(statusText: "capture failed")
            reportFailure(title: "Blink Failed", statusText: "failed: \(shortErrorSummary(error))", detail: detailedErrorMessage(error))
        }
    }

    private func submitSession() {
        guard let active = session else { return }
        active.collectingTimer?.cancel()
        // Submitting from modal multi-frame means the user wants the new
        // run — there's no chat to revert to anymore. (lastSubmittedRun
        // is stamped inside dispatchSubmit, covering both this path and
        // single-tap startCaptureSession.)
        DispatchQueue.main.async { [weak self] in
            self?.modalChatSnapshot = nil
        }
        session = nil
        setCollectingActive(false)
        DispatchQueue.main.async { [weak self] in self?.overlay.dismissSubmitPrompt() }
        dispatchSubmit(active)
    }

    /// - Parameter confirmCapture: when false, the post-capture confirmation
    ///   flash is suppressed for this frame (the caller already showed an instant
    ///   capture indicator at hotkey time). Defaults to true so the append /
    ///   multi-frame paths keep their per-frame flash.
    private func captureFrame(
        index: Int,
        staging: URL,
        shareableContent: SCShareableContent? = nil,
        preferredPID: pid_t? = nil,
        confirmCapture: Bool = true
    ) throws -> CapturedFrameResult {
        dispatchPrecondition(condition: .notOnQueue(.main))
        TCCDiagnostics.log(
            "capture_frame_start index=\(index) preferred_pid=\(preferredPID.map(String.init) ?? "nil") cached_shareable_content=\(shareableContent != nil)"
        )
        let captureStartedPerf = monotonicNow()

        let ownPID = NSRunningApplication.current.processIdentifier
        let effectivePID: pid_t?
        if let preferredPID, preferredPID != ownPID {
            effectivePID = preferredPID
        } else {
            // Skip Blink itself — the Control window / Settings can be the
            // frontmost app when the hotkey or Summarize button fires, and
            // we never want to capture our own window.
            effectivePID = DispatchQueue.main.sync {
                let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
                if let frontmost, frontmost != ownPID { return frontmost }
                return nil
            }
        }
        let axProbe = effectivePID.map { ScreenCapture.focusedWindowAXProbe(for: $0) }

        let capture = try ScreenCapture.captureFrontmostWindowSync(
            preferredGlobalRect: axProbe?.globalRect,
            shareableContent: shareableContent,
            preferredPID: effectivePID,
            axIsFullscreen: axProbe?.isFullscreen ?? false,
            confirmCapture: confirmCapture
        )
        let captureMS = durationMS(since: captureStartedPerf)
        TCCDiagnostics.log(
            "capture_frame_success index=\(index) capture_ms=\(captureMS) owner_pid=\(capture.ownerPID) owner_bundle_id=\(capture.ownerBundleID ?? "nil") window_id=\(capture.windowID)"
        )
        guard let capturePayload = ImageDiagnostics.makePayload(pngData: capture.pngData) else {
            throw NSError(domain: "BlinkCoordinator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't inspect screenshot metadata."])
        }
        let frameURL = staging.appendingPathComponent("screenshot_\(index).jpg")
        try capture.pngData.write(to: frameURL, options: .atomic)
        var frontmostApp: [String: Any] = [
            "pid": Int(capture.ownerPID),
            "window_id": Int(capture.windowID),
        ]
        if let bundleID = capture.ownerBundleID {
            frontmostApp["bundle_id"] = bundleID
        }
        if let name = capture.ownerName {
            frontmostApp["app_name"] = name
        }
        if let title = capture.windowTitle, !title.isEmpty {
            frontmostApp["window_title"] = title
        }
        // `Capture.windowFramePoints` comes straight from `SCWindow.frame`
        // / `SCDisplay.frame`, which are CG global coordinates (origin
        // top-left, +Y down). Every other marker input to ScreenAnnotator
        // — caret point, mouse point, focused bounds — is AppKit-screen
        // (origin bottom-left, +Y up). Flip Y here so the rect lives in
        // the same coord system as the markers; ScreenAnnotator's
        // pixel-mapping math relies on that consistency. The flip mirrors
        // `CaptureConfirmationOverlay.flash` (ScreenCapture.swift:571-576)
        // which does the same conversion for its overlay window.
        let captureRectScreen = captureRectInAppKitScreen(capture.windowFramePoints)
        // Tell the overlay which screen the captured content came from
        // before any showCollecting / show / showLoading call constructs a
        // panel. `panel.screen` takes over for recenters once the panel
        // exists; this only steers the *first* placement. On fullscreen
        // / multi-display setups, this is what prevents the overlay from
        // landing on a different display than the captured window.
        let capturedFrame = capture.windowFramePoints
        DispatchQueue.main.async { [overlay] in
            overlay.preferredScreen = ScreenCapture.screenForGlobalRect(capturedFrame)
        }
        // Selection harvest runs here — on the capture queue, after the
        // PNG has landed and before any main-thread overlay dispatch —
        // so AX (and any synthesized Cmd+C) targets the still-frontmost
        // source app rather than Blink's overlay panel.
        let selection = SelectionCapture.captureSync()
        return CapturedFrameResult(
            frame: CapturedFrame(
                index: index,
                pngURL: frameURL,
                capturedAt: capture.capturedAt,
                captureMS: captureMS,
                windowID: capture.windowID,
                screenshotMeta: capturePayload.screenshot,
                imageDiagnostics: capturePayload.diagnostics,
                sha256: sha256Hex(capture.pngData),
                thumbnail: Self.makeThumbnail(from: capture.pngData),
                frontmostApp: frontmostApp,
                captureRectPoints: captureRectScreen,
                selection: selection
            ),
            shareableContent: capture.shareableContent
        )
    }

    /// Flip a CG-global rect (top-left origin, +Y down) into AppKit-screen
    /// coords (bottom-left, +Y up) so it matches the marker points
    /// `ScreenAnnotator` receives. Falls back to the input if no screen
    /// is attached so a future headless CI run can't crash here.
    private func captureRectInAppKitScreen(_ cgRect: CGRect) -> CGRect {
        let primaryHeight = DispatchQueue.main.sync {
            NSScreen.screens.first?.frame.height ?? 0
        }
        guard primaryHeight > 0 else { return cgRect }
        return CGRect(
            x: cgRect.origin.x,
            y: primaryHeight - cgRect.maxY,
            width: cgRect.width,
            height: cgRect.height
        )
    }

    private func armCollectingTimer(requestID: String) {
        guard var active = session, active.requestID == requestID else { return }
        active.collectingTimer?.cancel()
        setCollectingActive(true)
        // A prior timeout may have already surfaced the submit-prompt pill.
        // Adding another frame restarts the collecting window, so dismiss it
        // — the standard "Collecting" overlay panel will resume.
        DispatchQueue.main.async { [weak self] in self?.overlay.dismissSubmitPrompt() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(collectingTimeoutSeconds))
        timer.setEventHandler { [weak self] in
            self?.promptSubmitOnTimeout(requestID: requestID)
        }
        active.collectingTimer = timer
        session = active
        timer.resume()
    }

    /// Fired by the collecting timer instead of auto-submitting. Keeps the
    /// session alive and drops the "Hit ↩ to send to tl;dr" pill so the
    /// user can press Return (submit), Esc (cancel), or the hotkey again
    /// (add another frame).
    private func promptSubmitOnTimeout(requestID: String) {
        // Timer source runs on `queue` — same queue all session state is
        // touched from. Re-check requestID in case the session was already
        // replaced or cancelled before the timer fired.
        guard var active = session, active.requestID == requestID else { return }
        active.collectingTimer?.cancel()
        active.collectingTimer = nil
        session = active
        status("waiting on Return")
        let thumbnails = active.frames.compactMap(\.thumbnail)
        let frameCount = active.frames.count
        let maxFrames = self.maxCapturedFrames
        let hotkeyDisplay = self.summaryHotkey.displayString
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.overlay.showCollecting(
                frameCount: frameCount,
                maxFrames: maxFrames,
                hotkeyDisplay: hotkeyDisplay,
                thumbnails: thumbnails,
                message: "Ready — press Return"
            )
            self.overlay.showSubmitPrompt()
        }
    }

    private func frameInfo(_ frame: CapturedFrame) -> CaptureModeDeriver.FrameInfo {
        CaptureModeDeriver.FrameInfo(
            windowID: frame.windowID,
            pid: frame.frontmostApp["pid"] as? Int,
            appName: frame.frontmostApp["app_name"] as? String,
            bundleID: frame.frontmostApp["bundle_id"] as? String
        )
    }

    private func deriveCaptureMode(frames: [CapturedFrame]) -> String {
        CaptureModeDeriver.captureMode(for: frames.map(frameInfo))
    }

    private func collectingMessage(frames: [CapturedFrame], duplicate: Bool) -> String? {
        CaptureModeDeriver.collectingMessage(
            frames: frames.map(frameInfo),
            duplicate: duplicate
        )
    }

    private func submitCapturedSession(_ active: CaptureSession, submissionToken: UUID) {
        guard let firstFrame = active.frames.first else { return }
        let requestID = active.requestID
        let runtime = active.runtime
        let clientMetadata = active.clientMetadata
        let captureMode = deriveCaptureMode(frames: active.frames)
        var lastPhase = "capture_succeeded"
        do {
            let focusedSnapshot = FocusedContextCapture.captureSnapshot(
                allowContentRetention: runtime.allowContentRetention
            )
            // NSEvent.mouseLocation is main-thread-only; this code path
            // is on submitQueue. The sync hop is cheap (microseconds) and
            // matches the existing pattern at the top of captureFrame
            // (line ~788) for NSWorkspace.shared.frontmostApplication.
            let mouseLocation: CGPoint = DispatchQueue.main.sync { NSEvent.mouseLocation }
            // Full-window AX tree (off-screen included) so the server can give
            // the model scrolling context the viewport screenshot lacks. Walk
            // is clamped (node/value caps); nil when AX is denied or empty.
            // nodeCount + truncated are surfaced for rollout observability so we
            // can tell the client node cap apart from the server char clamp.
            let axTreeResult = WindowAXTreeCapture.capture()
            var focusedContext = focusedSnapshot.uploadPayload
            // Annotate every frame in place before the runner reads them.
            // Each frame carries its own captureRect, so the marker math
            // stays correct for multi-frame scrolls where the window
            // moved between captures.
            //
            // Stash the runtime values used for marker placement into
            // `focused_context.marker_diagnostics` so a mis-placed marker
            // can be debugged from request.json alone. Captures every
            // intermediate coordinate without needing to attach a debugger.
            let firstCaptureRect = active.frames.first?.captureRectPoints ?? .zero
            let primaryScreenFrame = DispatchQueue.main.sync {
                NSScreen.screens.first?.frame ?? .zero
            }
            let allScreenFrames = DispatchQueue.main.sync {
                NSScreen.screens.map { $0.frame }
            }
            var diag: [String: Any] = [
                "primary_screen_frame_appkit": [
                    "x": primaryScreenFrame.origin.x,
                    "y": primaryScreenFrame.origin.y,
                    "width": primaryScreenFrame.size.width,
                    "height": primaryScreenFrame.size.height,
                ],
                "all_screen_frames_appkit": allScreenFrames.map { [
                    "x": $0.origin.x,
                    "y": $0.origin.y,
                    "width": $0.size.width,
                    "height": $0.size.height,
                ] },
                "capture_rect_appkit_first_frame": [
                    "x": firstCaptureRect.origin.x,
                    "y": firstCaptureRect.origin.y,
                    "width": firstCaptureRect.size.width,
                    "height": firstCaptureRect.size.height,
                    "max_x": firstCaptureRect.maxX,
                    "max_y": firstCaptureRect.maxY,
                ],
                "mouse_screen_point_appkit": [
                    "x": mouseLocation.x,
                    "y": mouseLocation.y,
                ],
                "source_confidence": focusedSnapshot.sourceConfidence,
            ]
            if let bounds = focusedSnapshot.focusedBoundsScreen {
                diag["focused_bounds_screen_appkit"] = [
                    "x": bounds.origin.x,
                    "y": bounds.origin.y,
                    "width": bounds.size.width,
                    "height": bounds.size.height,
                    "max_y": bounds.maxY,
                ]
            }
            if let caret = focusedSnapshot.caretScreenPoint {
                diag["caret_screen_point_appkit"] = [
                    "x": caret.x,
                    "y": caret.y,
                ]
            }
            focusedContext["marker_diagnostics"] = diag

            if runtime.annotateScreenshots {
                let markers = ScreenAnnotator.Markers(
                    focusedBounds: focusedSnapshot.focusedBoundsScreen,
                    caretPoint: focusedSnapshot.caretScreenPoint,
                    mousePoint: mouseLocation,
                    sourceConfidence: focusedSnapshot.sourceConfidence
                )
                for frame in active.frames {
                    guard let pngData = try? Data(contentsOf: frame.pngURL) else { continue }
                    guard let annotated = ScreenAnnotator.annotate(
                        pngData: pngData,
                        captureRect: frame.captureRectPoints,
                        markers: markers
                    ) else { continue }
                    try? annotated.write(to: frame.pngURL, options: .atomic)
                }
            }
            let runtimeURL = active.staging.appendingPathComponent("runtime.json")
            let hostProfileURL = active.staging.appendingPathComponent("host_profile.json")
            let requestURL = active.staging.appendingPathComponent("request.json")
            try writeJSON(runtime, to: runtimeURL)
            try? FileManager.default.removeItem(at: active.staging.appendingPathComponent("screenshot.jpg"))
            try FileManager.default.copyItem(
                at: firstFrame.pngURL,
                to: active.staging.appendingPathComponent("screenshot.jpg")
            )

            let attachmentsCatalog: [[String: Any]] = DispatchQueue.main.sync {
                AttachmentLibrary.shared.entries.map(\.catalogItem)
            }
            let requestEnvelope = makeRequestEnvelope(
                requestID: requestID,
                runtime: runtime,
                clientMetadata: clientMetadata,
                frontmostApp: active.frontmostApp,
                screenshotMeta: firstFrame.screenshotMeta,
                diagnostics: firstFrame.imageDiagnostics,
                focusedContext: focusedContext,
                axTree: axTreeResult?.text,
                axTreeNodes: axTreeResult?.nodeCount,
                axTreeTruncated: axTreeResult?.truncated ?? false,
                mouseScreenPoint: mouseLocation,
                captureMode: captureMode,
                frames: active.frames,
                attachmentsCatalog: attachmentsCatalog
            )
            try JSONFiles.writeObject(requestEnvelope, to: requestURL)

            let captureMS = active.frames.reduce(0) { $0 + $1.captureMS }
            let hostProfile: [String: Any] = [
                "request_id": requestID,
                "started_at": JSONFiles.isoString(active.startedAt),
                "capture_ms": captureMS,
                "frame_count": active.frames.count,
                "frontmost_app": active.frontmostApp,
                "client": clientMetadata,
                "image_diagnostics": firstFrame.imageDiagnostics,
                "frames": framePayloads(active.frames),
            ]
            try JSONFiles.writeObject(hostProfile, to: hostProfileURL)

            updatePendingFrames(active, focusedContext: focusedContext, phase: lastPhase)
            emitEvent(
                requestID: requestID,
                type: "capture_succeeded",
                allowLogging: runtime.allowEventLogging,
                clientMetadata: clientMetadata,
                details: [
                    "capture_ms": captureMS,
                    "frame_count": active.frames.count,
                    "screenshot": firstFrame.screenshotMeta,
                    "image_diagnostics": firstFrame.imageDiagnostics,
                ]
            )
            for frame in active.frames where (frame.imageDiagnostics["blank_likely"] as? Bool) == true {
                emitEvent(
                    requestID: requestID,
                    type: "capture_blank_detected",
                    allowLogging: runtime.allowEventLogging,
                    clientMetadata: clientMetadata,
                    details: ["frame_index": frame.index, "image_diagnostics": frame.imageDiagnostics]
                )
            }

            lastPhase = "request_upload_started"
            PendingRunStore.update(requestID: requestID) { payload in
                payload["last_phase"] = lastPhase
            }
            emitEvent(
                requestID: requestID,
                type: "request_upload_started",
                allowLogging: runtime.allowEventLogging,
                clientMetadata: clientMetadata,
                details: ["input_mode": "screenshot", "frame_count": active.frames.count]
            )

            status("calling Blink backend...")
            DispatchQueue.main.async {
                guard !self.cancelledSubmissionTokens.contains(submissionToken) else { return }
                self.currentRequestID = requestID
                self.currentSuggestions = []
                self.currentSuggestionDetails = []
                self.currentBundleDir = nil
                self.followUpHistory = []
                self.tldrHistory = []
                self.currentTldrIndex = 0
                self.resetChoiceState(
                    suggestionCount: 0,
                    allowsCustomInput: false,
                    consumesReturnWhileLoading: true
                )
                self.overlay.onCustomInputFocusChanged = nil
                self.overlay.onCustomInsert = nil
                self.overlay.onCustomFollowUp = nil
                self.overlay.onCustomInsertKey = nil
                self.overlay.onLeaveCustomInputKey = nil
                self.overlay.onTextEditingKey = nil
                self.overlay.onRerollKey = nil
                self.overlay.onChoiceKey = { _ in }
                self.overlay.onArrowKey = nil
                self.overlay.onInsertKey = { true }
                self.overlay.onDismissKey = { [weak self] in
                    self?.dismissOverlay()
                }
                // Anchor the overlay to the most recent captured window so the
                // window-anchored placement modes land beside it. Nil-safe:
                // the centered placement ignores this.
                self.overlay.anchorRect = active.frames.last?.captureRectPoints
                if RuntimeEnvironment.glassLoadingEnabled(),
                   let windowRect = active.frames.last?.captureRectPoints {
                    // Glass loading replaces the corner puck: a clear lens over the
                    // captured window drains into the Reading pill. Suppress the
                    // puck; the result is shown via the normal final show().
                    if self.glassLoadingActive {
                        // The lens has been on screen since hotkey time (instant
                        // ack). Now that the run is about to stream, arm the Esc
                        // key-tap mirror — deferred until here so the double-tap
                        // window stayed open during capture. Only re-anchor the
                        // lens if the real capture landed somewhere materially
                        // different (fullscreen / display fallback / window moved);
                        // otherwise keep the single continuous drain.
                        self.setOverlayActiveMirror(true)
                        if let presented = self.glassLoadingPresentedRect,
                           !Self.rectsApproximatelyEqual(presented, windowRect) {
                            self.presentGlassLoading(windowRect: windowRect, speed: active.runtime.lensAnimationSpeed)
                        }
                    } else {
                        // No live instant lens. Either no cheap rect was available
                        // at hotkey time (single-shot), or this is a multi-frame
                        // submit whose collecting overlay is still on screen. Tear
                        // any such panel down before the lens becomes the sole
                        // loading surface: the non-glass branch gets this for free
                        // via showLoading()->show()->close(), but the glass branch
                        // must do it explicitly, or the stale collecting panel
                        // lingers behind the lens and then captures the streaming
                        // partials / the final result (it has isLoadingState=false,
                        // so the result hand-off mistakes it for a streaming panel).
                        // close() no-ops when nothing is visible (the single-shot case).
                        self.overlay.close()
                        self.presentGlassLoading(windowRect: windowRect, speed: active.runtime.lensAnimationSpeed)
                    }
                } else {
                    self.overlay.showLoading(tldr: active.frames.count > 1 ? "Reading \(active.frames.count) frames..." : "Reading this screen...")
                    if active.frames.contains(where: { ($0.imageDiagnostics["blank_likely"] as? Bool) == true }) {
                        self.overlay.showSoftError("One capture looks blank. Blink will still try to read it.")
                    }
                }
            }
            let pythonStartedPerf = monotonicNow()
            let result = try PythonRunner.runOnceStreaming(
                config: config,
                screenshotPNGs: active.frames.map(\.pngURL),
                runtimeJSON: runtimeURL,
                settingsJSON: Paths.settingsPath,
                prompt: Paths.promptPath,
                requestJSON: requestURL,
                outputParent: Paths.runsDir,
                hostProfileJSON: hostProfileURL,
                onRunStarted: { run in
                    DispatchQueue.main.async {
                        if self.cancelledSubmissionTokens.contains(submissionToken) {
                            run.terminate()
                            return
                        }
                        if var submission = self.currentSubmission, submission.token == submissionToken {
                            submission.run = run
                            self.currentSubmission = submission
                        }
                        self.currentStreamingRun = run
                    }
                },
                onEvent: { event in
                    DispatchQueue.main.async {
                        guard !self.cancelledSubmissionTokens.contains(submissionToken) else { return }
                        guard self.currentRequestID == requestID else { return }
                        switch event {
                        case .phase(let message):
                            self.overlay.updateLoadingPhase(message)
                        case .partialSummary(let text):
                            self.overlay.updateSummary(text)
                        case .partialSuggestions(let list):
                            self.overlay.updateSuggestions(Array(list.prefix(3)))
                        }
                    }
                }
            )
            let streamCompletedAt = Date()
            let firstTokenAt = DispatchQueue.main.sync { self.currentStreamingRun?.firstTokenAt }
            DispatchQueue.main.async {
                if let submission = self.currentSubmission, submission.token == submissionToken {
                    self.currentSubmission = nil
                }
                if self.currentRequestID == requestID {
                    self.currentStreamingRun = nil
                }
            }
            let wasAbandoned = DispatchQueue.main.sync { () -> Bool in
                if self.cancelledSubmissionTokens.remove(submissionToken) != nil {
                    return true
                }
                return self.currentRequestID != requestID
            }
            if wasAbandoned {
                DispatchQueue.main.async { self.dismissGlassLoading() }
                return
            }
            let pythonMS = durationMS(since: pythonStartedPerf)
            let totalMS = durationMS(since: active.startedPerf)

            let bundleDir = URL(fileURLWithPath: result.bundleDir)
            try updateRunHostProfile(
                bundleDir: bundleDir,
                requestID: requestID,
                captureMS: captureMS,
                pythonMS: pythonMS,
                totalMS: totalMS,
                result: result,
                firstTokenAt: firstTokenAt,
                streamCompletedAt: streamCompletedAt
            )

            lastPhase = "overlay_shown"
            PendingRunStore.update(requestID: requestID) { payload in
                payload["last_phase"] = lastPhase
                payload["bundle_dir"] = result.bundleDir
            }
            emitEvent(
                requestID: requestID,
                type: "server_response_received",
                allowLogging: runtime.allowEventLogging,
                clientMetadata: clientMetadata,
                details: [
                    "duration_ms": result.durationMS as Any,
                    "warnings": result.warnings,
                    "model": result.model as Any,
                    "frame_count": active.frames.count,
                ]
            )

            status("ready - press 1/2/3 to expand")
            DispatchQueue.main.async {
                guard self.currentRequestID == requestID else { return }
                self.currentSuggestionDetails = self.normalizedSuggestionDetails(
                    result.suggestionDetails,
                    fallbackSuggestions: result.suggestions,
                    draft: focusedSnapshot.meaningfulDraftText ?? ""
                )
                self.currentSuggestions = self.currentSuggestionDetails.map(\.text)
                self.currentBundleDir = bundleDir
                self.currentRequestID = requestID
                self.resetChoiceState(suggestionCount: self.currentSuggestions.count)
                self.wireOverlayCallbacks()
                // Hand off from the glass loading (if active) to the result panel.
                self.dismissGlassLoading()
                if self.overlay.isStreamingActive {
                    // Streaming already populated the panel via updateSummary
                    // and updateSuggestions. Calling show() here would close
                    // and rebuild the entire NSPanel, producing a whole-UI
                    // flicker. Push the final values through the in-place
                    // update entry points instead.
                    self.overlay.updateSummary(result.tldr)
                    self.overlay.updateSuggestionDetails(self.currentSuggestionDetails)
                } else {
                    self.overlay.show(
                        tldr: result.tldr,
                        suggestionDetails: self.currentSuggestionDetails
                    )
                }
                // Seed TL;DR history with the initial capture (pager hidden since count=1).
                self.tldrHistory = [TLDREntry(tldr: result.tldr)]
                self.currentTldrIndex = 0
                self.overlay.setPager(count: 1, currentIndex: 0)
                self.overlay.onTLDRDotTapped = { [weak self] index in
                    guard let self, index >= 0, index < self.tldrHistory.count else { return }
                    self.currentTldrIndex = index
                    self.overlay.updateSummaryFromHistory(self.tldrHistory[index].tldr)
                    self.overlay.setPager(count: self.tldrHistory.count, currentIndex: index)
                }
                self.soundEffects.play(.resultReady)
                if result.tldr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && self.currentSuggestions.isEmpty {
                    self.overlay.showSoftError("Blink came back empty. Try a clearer or more text-heavy window.")
                }
                self.emitEvent(
                    requestID: requestID,
                    type: "overlay_shown",
                    allowLogging: runtime.allowEventLogging,
                    clientMetadata: clientMetadata,
                    details: ["suggestion_count": self.currentSuggestions.count]
                )
                self.onSummaryCompleted?(true)
            }
        } catch {
            DispatchQueue.main.async { self.dismissGlassLoading() }
            let wasAbandoned = DispatchQueue.main.sync { () -> Bool in
                if self.cancelledSubmissionTokens.remove(submissionToken) != nil {
                    return true
                }
                return self.currentRequestID != requestID
            }
            if wasAbandoned {
                return
            }
            PendingRunStore.update(requestID: requestID) { payload in
                payload["last_phase"] = lastPhase
                payload["error"] = self.shortErrorSummary(error)
            }
            emitEvent(
                requestID: requestID,
                type: failureEventType(for: error, lastPhase: lastPhase),
                allowLogging: runtime.allowEventLogging,
                clientMetadata: clientMetadata,
                details: [
                    "last_phase": lastPhase,
                    "error": shortErrorSummary(error),
                ]
            )
            PendingRunStore.finish(requestID: requestID)
            DispatchQueue.main.async { [weak self] in
                self?.onSummaryCompleted?(false)
            }
            reportFailure(
                title: "Blink Failed",
                statusText: "failed: \(shortErrorSummary(error))",
                detail: detailedErrorMessage(error)
            )
        }
    }

    @MainActor
    func rerollCurrentSuggestions(followUpInstruction rawInstruction: String? = nil) {
        guard overlay.isVisible,
              let sourceBundleDir = currentBundleDir,
              let sourceRequestID = currentRequestID,
              !currentSuggestions.isEmpty
        else {
            return
        }
        if currentStreamingRun?.isRunning == true {
            status("already rerolling")
            return
        }
        let screenshotURLs = rerollScreenshotURLs(in: sourceBundleDir)
        guard !screenshotURLs.isEmpty else {
            overlay.showSoftError("Can't reroll this one. The saved screenshot is missing.")
            return
        }
        let requestID = UUID().uuidString.lowercased()
        let clientMetadata = self.clientMetadata()
        var runtime = runtimeStore.snapshot
        // Keep the per-app resolution table out of the per-request runtime.json
        // (the original capture's thinking_level is restored from request.json
        // below). See the matching note in `startCaptureSession`.
        runtime.appThinkingLevels = [:]
        let allowEventLogging = runtime.allowEventLogging
        let startedAt = Date()
        let followUpInstruction = rawInstruction?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingPayload: [String: Any] = [
            "request_id": requestID,
            "started_at": JSONFiles.isoString(startedAt),
            "updated_at": JSONFiles.isoString(startedAt),
            "last_phase": "reroll_started",
            "client": clientMetadata,
            "capture_mode": "frontmost_window",
            "input_mode": "screenshot",
            "source_request_id": sourceRequestID,
            "source_bundle_dir": sourceBundleDir.path,
            "frames": screenshotURLs.map(\.lastPathComponent),
            "has_follow_up_instruction": followUpInstruction?.isEmpty == false,
        ]
        do {
            try PendingRunStore.create(requestID: requestID, payload: pendingPayload)
        } catch {
            overlay.showSoftError("Couldn't prepare a reroll.")
            status("reroll failed")
            return
        }
        // Snap to head of TL;DR history before issuing request so any
        // scrolled-back view snaps to the latest entry.
        if !tldrHistory.isEmpty && currentTldrIndex != tldrHistory.count - 1 {
            currentTldrIndex = tldrHistory.count - 1
            overlay.updateSummaryFromHistory(tldrHistory[currentTldrIndex].tldr)
            overlay.setPager(count: tldrHistory.count, currentIndex: currentTldrIndex)
        }
        let priorSuggestions = currentSuggestionDetails.isEmpty
            ? currentSuggestions.map(SuggestionDetail.plain)
            : currentSuggestionDetails
        let runtimeURL: URL
        let hostProfileURL = sourceBundleDir.appendingPathComponent("host_profile.json")
        let tempDir: URL
        do {
            tempDir = try makeStagingDir()
            runtimeURL = tempDir.appendingPathComponent("runtime.json")
            var requestEnvelope = JSONFiles.readObject(at: sourceBundleDir.appendingPathComponent("request.json")) ?? [:]
            if let preferences = requestEnvelope["preferences"] as? [String: Any] {
                runtime.thinkingLevel = preferences["thinking_level"] as? String
                runtime.outputFormat = preferences["output_format"] as? String
            }
            try writeJSON(runtime, to: runtimeURL)
            requestEnvelope["request_id"] = requestID
            requestEnvelope.removeValue(forKey: "stateful_context")
            // Keep full prior suggestions in the local request.json so the direct local runner can reroll without a server store. The Python proxy path trims this to schema_version + source_request_id before upload.
            var rerollContext: [String: Any] = [
                "schema_version": 1,
                "source_request_id": sourceRequestID,
                "previous_suggestions": currentSuggestions,
                "previous_suggestion_details": priorSuggestions.map { detail in
                    [
                        "text": detail.text,
                        "tags": detail.tags,
                    ]
                },
            ]
            if let followUpInstruction, !followUpInstruction.isEmpty {
                rerollContext["follow_up_instruction"] = followUpInstruction
            }
            if !followUpHistory.isEmpty {
                rerollContext["follow_up_history"] = followUpHistory.map { turn in
                    [
                        "instruction": turn.instruction,
                        "tldr": turn.tldr,
                        "suggestions": turn.suggestions.map(\.text),
                    ] as [String: Any]
                }
            }
            requestEnvelope["reroll_context"] = rerollContext
            try JSONFiles.writeObject(
                requestEnvelope,
                to: tempDir.appendingPathComponent("request.json")
            )
        } catch {
            PendingRunStore.finish(requestID: requestID)
            overlay.showSoftError("Couldn't prepare a reroll.")
            status("reroll failed")
            return
        }

        terminalEmittedRequestID = sourceRequestID
        emitEvent(
            requestID: sourceRequestID,
            type: "run_completed",
            allowLogging: allowEventLogging,
            clientMetadata: clientMetadata,
            details: ["outcome": "rerolled"]
        )
        PendingRunStore.finish(requestID: sourceRequestID)

        let token = UUID()
        if let inflight = currentSubmission {
            cancelledSubmissionTokens.insert(inflight.token)
            inflight.run?.terminate()
        }
        currentSubmission = InflightSubmission(token: token, requestID: requestID, run: nil)
        currentStreamingRun = nil
        currentRequestID = requestID
        currentBundleDir = nil
        currentSuggestions = []
        currentSuggestionDetails = []
        resetChoiceState(
            suggestionCount: 0,
            allowsCustomInput: false,
            consumesReturnWhileLoading: true
        )
        overlay.onChoiceKey = { _ in }
        overlay.onArrowKey = nil
        overlay.onInsertKey = { true }
        overlay.onCustomInputFocusChanged = nil
        overlay.onCustomInsert = nil
        overlay.onCustomFollowUp = nil
        overlay.onCustomInsertKey = nil
        overlay.onLeaveCustomInputKey = nil
        overlay.onTextEditingKey = nil
        overlay.onRerollKey = nil
        overlay.onDismissKey = { [weak self] in
            self?.dismissOverlay()
        }
        overlay.onOutsideClickDismiss = { [weak self] in
            self?.dismissOverlay(implicit: true)
        }
        overlay.beginSuggestionRefresh()
        // The follow-up text has been captured into the request, but we leave it
        // in the box through the loading state and clear it only once the
        // response lands (in the success handler below). That keeps the user
        // looking at what they asked while it generates, and a failed reroll
        // leaves their text intact to retry. The clear runs in the shared
        // completion handler, so both the changed and unchanged-suggestions
        // branches consume it.
        status("rerolling suggestions...")
        emitEvent(
            requestID: requestID,
            type: "reroll_started",
            allowLogging: allowEventLogging,
            clientMetadata: clientMetadata,
            details: [
                "source_request_id": sourceRequestID,
                "previous_suggestion_count": priorSuggestions.count,
                "has_follow_up_instruction": followUpInstruction?.isEmpty == false,
            ]
        )

        let requestURL = tempDir.appendingPathComponent("request.json")
        let rerollStartedPerf = monotonicNow()
        submitQueue.async { [self] in
            do {
                let result = try PythonRunner.runOnceStreaming(
                    config: config,
                    screenshotPNGs: screenshotURLs,
                    runtimeJSON: runtimeURL,
                    settingsJSON: Paths.settingsPath,
                    prompt: Paths.promptPath,
                    requestJSON: requestURL,
                    outputParent: Paths.runsDir,
                    hostProfileJSON: hostProfileURL,
                    onRunStarted: { run in
                        DispatchQueue.main.async {
                            if self.cancelledSubmissionTokens.contains(token) {
                                run.terminate()
                                return
                            }
                            if var submission = self.currentSubmission, submission.token == token {
                                submission.run = run
                                self.currentSubmission = submission
                            }
                            self.currentStreamingRun = run
                        }
                    },
                    onEvent: { event in
                        DispatchQueue.main.async {
                            guard !self.cancelledSubmissionTokens.contains(token) else { return }
                            guard self.currentRequestID == requestID else { return }
                            switch event {
                            case .phase:
                                break
                            case .partialSummary:
                                break
                            case .partialSuggestions:
                                // Hold the faded cards until completion. The
                                // reroll TL;DR is applied only at completion
                                // (Option A — no streaming partials), so
                                // streaming suggestions live here would churn
                                // the cards under a frozen TL;DR. Letting both
                                // land together at completion keeps them moving
                                // as one (TL;DR first).
                                break
                            }
                        }
                    }
                )
                let streamCompletedAt = Date()
                let firstTokenAt = DispatchQueue.main.sync { self.currentStreamingRun?.firstTokenAt }
                DispatchQueue.main.async {
                    if let submission = self.currentSubmission, submission.token == token {
                        self.currentSubmission = nil
                    }
                    if self.currentRequestID == requestID {
                        self.currentStreamingRun = nil
                    }
                }
                let wasAbandoned = DispatchQueue.main.sync { () -> Bool in
                    if self.cancelledSubmissionTokens.remove(token) != nil {
                        return true
                    }
                    return self.currentRequestID != requestID
                }
                if wasAbandoned { return }

                let pythonMS = durationMS(since: rerollStartedPerf)
                let bundleDir = URL(fileURLWithPath: result.bundleDir)
                try updateRunHostProfile(
                    bundleDir: bundleDir,
                    requestID: requestID,
                    captureMS: 0,
                    pythonMS: pythonMS,
                    totalMS: pythonMS,
                    result: result,
                    firstTokenAt: firstTokenAt,
                    streamCompletedAt: streamCompletedAt
                )
                emitEvent(
                    requestID: requestID,
                    type: "server_response_received",
                    allowLogging: allowEventLogging,
                    clientMetadata: clientMetadata,
                    details: [
                        "duration_ms": result.durationMS as Any,
                        "warnings": result.warnings,
                        "model": result.model as Any,
                        "reroll": true,
                    ]
                )

                DispatchQueue.main.async {
                    guard self.currentRequestID == requestID else { return }
                    let suggestionDetailsUnchanged = result.suggestions.isEmpty
                    if suggestionDetailsUnchanged {
                        self.currentSuggestions = priorSuggestions.map(\.text)
                        self.currentSuggestionDetails = priorSuggestions
                    } else {
                        self.currentSuggestionDetails = self.normalizedSuggestionDetails(
                            result.suggestionDetails,
                            fallbackSuggestions: result.suggestions,
                            draft: ""
                        )
                        self.currentSuggestions = self.currentSuggestionDetails.map(\.text)
                    }
                    self.currentBundleDir = bundleDir
                    self.resetChoiceState(suggestionCount: self.currentSuggestions.count)
                    self.wireOverlayCallbacks()
                    // Append this turn to model follow-up history (for next request's context).
                    let turnInstruction = followUpInstruction ?? ""
                    self.followUpHistory.append(FollowUpTurn(
                        instruction: turnInstruction,
                        tldr: result.tldr,
                        suggestions: self.currentSuggestionDetails
                    ))
                    // Append to TL;DR display history only when TL;DR actually changed.
                    let previousTldr = self.tldrHistory.last?.tldr ?? ""
                    if result.tldr != previousTldr {
                        self.tldrHistory.append(TLDREntry(tldr: result.tldr))
                        self.currentTldrIndex = self.tldrHistory.count - 1
                    }
                    // Apply TL;DR at completion only (Option A — no streaming partials).
                    if self.overlay.isStreamingActive {
                        if suggestionDetailsUnchanged {
                            self.overlay.updateSummaryForFinalResult(result.tldr)
                        } else {
                            if result.tldr != self.overlay.summaryFullText {
                                self.overlay.updateSummary(result.tldr)
                            }
                        }
                        if suggestionDetailsUnchanged {
                            self.overlay.endSuggestionRefresh()
                        } else {
                            self.overlay.updateSuggestionDetails(self.currentSuggestionDetails)
                        }
                    } else {
                        self.overlay.show(
                            tldr: result.tldr,
                            suggestionDetails: self.currentSuggestionDetails
                        )
                    }
                    self.overlay.setPager(count: self.tldrHistory.count, currentIndex: self.currentTldrIndex)
                    self.overlay.onTLDRDotTapped = { [weak self] index in
                        guard let self, index >= 0, index < self.tldrHistory.count else { return }
                        self.currentTldrIndex = index
                        self.overlay.updateSummaryFromHistory(self.tldrHistory[index].tldr)
                        self.overlay.setPager(count: self.tldrHistory.count, currentIndex: index)
                    }
                    // The submitted follow-up has now been answered, so clear the
                    // input box — deferred from submit time so the text stayed
                    // visible through the whole loading state. Only when a
                    // follow-up instruction was actually sent.
                    if followUpInstruction?.isEmpty == false {
                        self.overlay.clearCustomInputText()
                    }
                    self.soundEffects.play(.resultReady)
                    self.status("ready - press 1/2/3 to expand")
                    self.emitEvent(
                        requestID: requestID,
                        type: "overlay_shown",
                        allowLogging: allowEventLogging,
                        clientMetadata: clientMetadata,
                        details: ["suggestion_count": self.currentSuggestions.count, "reroll": true]
                    )
                }
            } catch {
                let wasAbandoned = DispatchQueue.main.sync { () -> Bool in
                    if self.cancelledSubmissionTokens.remove(token) != nil {
                        return true
                    }
                    return self.currentRequestID != requestID
                }
                if wasAbandoned { return }
                emitEvent(
                    requestID: requestID,
                    type: "request_upload_failed",
                    allowLogging: allowEventLogging,
                    clientMetadata: clientMetadata,
                    details: [
                        "reroll": true,
                        "error": shortErrorSummary(error),
                    ]
                )
                DispatchQueue.main.async {
                    self.overlay.endSuggestionRefresh()
                }
                reportFailure(
                    title: "Blink Failed",
                    statusText: "reroll failed: \(shortErrorSummary(error))",
                    detail: detailedErrorMessage(error)
                )
            }
        }
    }

    private func rerollScreenshotURLs(in bundleDir: URL) -> [URL] {
        if let frameLogs = JSONFiles.readArray(at: bundleDir.appendingPathComponent("frames.json")) {
            let urls = frameLogs.compactMap { item -> (Int, URL)? in
                guard let object = item as? [String: Any],
                      let index = object["index"] as? Int,
                      let filename = object["filename"] as? String
                else {
                    return nil
                }
                let url = bundleDir.appendingPathComponent(filename)
                return FileManager.default.fileExists(atPath: url.path) ? (index, url) : nil
            }
            let sorted = urls.sorted { $0.0 < $1.0 }.map(\.1)
            if !sorted.isEmpty {
                return sorted
            }
        }
        for name in ["screenshot.jpg", "screenshot.png"] {
            let fallback = bundleDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: fallback.path) {
                return [fallback]
            }
        }
        return []
    }

    private func normalizedSuggestionDetails(
        _ details: [SuggestionDetail],
        fallbackSuggestions: [String],
        draft: String
    ) -> [SuggestionDetail] {
        let source = details.isEmpty ? fallbackSuggestions.map(SuggestionDetail.plain) : details
        return Array(source.prefix(3)).enumerated().map { offset, detail in
            let text = SuggestionPrefixStripper.stripDuplicatedDraftPrefix(
                from: detail.text,
                draft: draft
            )
            return SuggestionDetail(
                text: text,
                tags: normalizedSuggestionTags(detail.tags, text: text, index: offset),
                attachments: detail.attachments
            )
        }
    }

    private func normalizedSuggestionTags(_ tags: [String], text: String, index: Int) -> [String] {
        let trimmed = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !trimmed.isEmpty {
            return Array(trimmed.prefix(2))
        }
        return [fallbackSuggestionTag(for: text, index: index)]
    }

    private func fallbackSuggestionTag(for text: String, index: Int) -> String {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized.contains("?")
            || normalized.hasPrefix("can you")
            || normalized.hasPrefix("could you")
            || normalized.hasPrefix("would you")
            || normalized.hasPrefix("please") {
            return "Ask"
        }
        if normalized.hasPrefix("wait")
            || normalized.hasPrefix("hold on")
            || normalized.hasPrefix("i don't")
            || normalized.hasPrefix("no,") {
            return "Pushback"
        }
        if normalized.hasPrefix("show me")
            || normalized.hasPrefix("check")
            || normalized.hasPrefix("fix")
            || normalized.hasPrefix("add")
            || normalized.hasPrefix("update")
            || normalized.hasPrefix("implement")
            || normalized.hasPrefix("push") {
            return "Next step"
        }
        return ["Reply", "Ask", "Next step"][min(max(index, 0), 2)]
    }

    private func recordFrameCaptured(_ active: CaptureSession, frame: CapturedFrame, mode: String) {
        updatePendingFrames(active, phase: "capture_succeeded")
        emitEvent(
            requestID: active.requestID,
            type: "capture_frame_added",
            allowLogging: active.runtime.allowEventLogging,
            clientMetadata: active.clientMetadata,
            details: [
                "capture_mode": mode,
                "frame_index": frame.index,
                "frame_count": active.frames.count,
                "capture_ms": frame.captureMS,
                "screenshot": frame.screenshotMeta,
                "image_diagnostics": frame.imageDiagnostics,
                "frontmost_app": frame.frontmostApp,
            ]
        )
    }

    private func updatePendingFrames(
        _ active: CaptureSession,
        focusedContext: [String: Any]? = nil,
        phase: String? = nil
    ) {
        PendingRunStore.update(requestID: active.requestID) { payload in
            if let phase {
                payload["last_phase"] = phase
            }
            payload["capture_mode"] = self.deriveCaptureMode(frames: active.frames)
            payload["frontmost_app"] = active.frontmostApp
            payload["screenshot"] = active.frames.first?.screenshotMeta
            payload["image_diagnostics"] = active.frames.first?.imageDiagnostics
            payload["frames"] = self.framePayloads(active.frames)
            if let focusedContext {
                payload["focused_context"] = focusedContext
            }
        }
    }

    private func framePayloads(_ frames: [CapturedFrame]) -> [[String: Any]] {
        frames.map { frame in
            [
                "index": frame.index,
                "screenshot": frame.screenshotMeta,
                "image_diagnostics": frame.imageDiagnostics,
                "captured_at": JSONFiles.isoString(frame.capturedAt),
                "sha256": frame.sha256,
                "frontmost_app": frame.frontmostApp,
            ]
        }
    }

    @MainActor
    func chooseSuggestion(index: Int) {
        guard currentBundleDir != nil else { return }
        // Picking a suggestion card via click while #4 is focused must drop
        // the field's first responder so the caret and selection tint clear.
        // The gesture recognizer that drives this code path doesn't transfer
        // first responder on its own.
        if index != 3 && choiceState.customInputActive {
            leaveCustomInput()
        }
        switch applyChoiceNumber(index) {
        case .ignored:
            return
        case .expand(let resolvedIndex):
            overlay.setCustomInputArmedHighlight(false)
            expandSuggestion(index: resolvedIndex)
            onSuggestionPicked?(resolvedIndex)
        case .commit(let resolvedIndex):
            overlay.setCustomInputArmedHighlight(false)
            insertSuggestion(index: resolvedIndex)
            onSuggestionPicked?(resolvedIndex)
        case .focusInput:
            overlay.focusCustomInput()
            status("type your own reply")
        }
    }

    @MainActor
    func insertExpandedSuggestion() -> Bool {
        guard currentBundleDir != nil else { return true }
        switch choiceState.pressReturn(insertsFirstIfNone: true) {
        case .propagate:
            return false
        case .insert(let index):
            insertSuggestion(index: index)
            return true
        case .focusCustomInput:
            // Arrow-armed custom-input slot: first Return focuses the textfield,
            // second Return (now customInputActive == true) submits.
            choiceState.clearCustomInputArmed()
            _ = choiceState.pressNumber(index: 3)
            setCustomInputActiveMirror(choiceState.customInputActive)
            setOverlayInsertConsumesReturn(choiceState.pressReturn() != .propagate)
            overlay.focusCustomInput()
            status("type your own reply")
            return true
        }
    }

    @MainActor
    func handleArrowNav(_ direction: OverlayArrowDirection) {
        guard currentBundleDir != nil, !currentSuggestions.isEmpty else { return }
        let navigableCount = min(currentSuggestions.count, 3)
        let stateDirection: SuggestionChoiceState.Direction = direction == .up ? .up : .down
        guard let slot = choiceState.moveSelection(stateDirection, navigableSuggestionCount: navigableCount) else { return }
        setCustomInputActiveMirror(choiceState.customInputActive)
        setOverlayInsertConsumesReturn(choiceState.pressReturn() != .propagate)
        switch slot {
        case .suggestion(let index):
            overlay.setCustomInputArmedHighlight(false)
            expandSuggestion(index: index)
        case .customInput:
            overlay.armCustomInput()
        }
    }

    @MainActor
    func submitCustomInputFromInput() -> Bool {
        guard currentBundleDir != nil else { return true }
        let text = overlay.customInputText
        guard !text.isEmpty else { return false }
        if overlay.customInputSubmitsFollowUp {
            rerollCurrentSuggestions(followUpInstruction: text)
        } else {
            insertCustomReply(text: text)
        }
        return true
    }

    @MainActor
    func insertCustomReplyFromInput() -> Bool {
        guard currentBundleDir != nil else { return true }
        let text = overlay.customInputText
        guard !text.isEmpty else { return false }
        insertCustomReply(text: text)
        return true
    }

    @MainActor
    func toggleOverlayPin() {
        guard overlay.isVisible else { return }
        overlay.setPinned(!overlay.isPinned)
    }

    /// ⌘T from the overlay: cycle the reasoning level for the app this capture
    /// came from and persist it. The change applies to the NEXT capture from
    /// that app — the current result keeps the level baked into its request —
    /// so we just confirm the new level rather than re-rolling.
    @MainActor
    func cycleThinkingForCurrentSurface() {
        guard overlay.isVisible else { return }
        guard let bundle = currentSurfaceBundleID, !bundle.isEmpty else {
            status("reasoning toggle: no app surface for this capture")
            return
        }
        let newLevel = runtimeStore.cycleThinkingLevel(forBundle: bundle)
        let title = ReasoningLevels.title(for: newLevel)
        overlay.flashReasoningLevel(title)
        status("reasoning for this app → \(title) (applies next capture)")
    }

    /// Set (or, with `nil`, clear) the per-app reasoning override for the
    /// current capture's surface. Like the ⌘T cycle, this applies to the next
    /// capture, not the current result. Driven by the overlay's right-click
    /// "Reasoning" submenu.
    @MainActor
    func setReasoningForCurrentSurface(_ level: String?) {
        guard overlay.isVisible else { return }
        guard let bundle = currentSurfaceBundleID, !bundle.isEmpty else {
            status("reasoning: no app surface for this capture")
            return
        }
        if let level {
            runtimeStore.appThinkingLevels[bundle] = level
        } else {
            runtimeStore.appThinkingLevels.removeValue(forKey: bundle)
        }
        let title = ReasoningLevels.title(for: runtimeStore.resolvedThinkingLevel(forBundle: bundle))
        overlay.flashReasoningLevel(title)
        status("reasoning for this app → \(title) (applies next capture)")
    }

    @MainActor
    func leaveCustomInput() {
        guard choiceState.customInputActive else { return }
        setCustomInputActive(false)
        overlay.leaveCustomInput()
        status("ready - press 1/2/3 to expand")
    }

    @MainActor
    func performCustomInputShortcut(_ shortcut: TextEditingShortcut) -> Bool {
        overlay.performCustomInputShortcut(shortcut)
    }

    @MainActor
    private func expandSuggestion(index: Int) {
        guard index >= 0 && index < currentSuggestions.count else { return }
        guard overlay.expandSuggestion(index: index) else { return }
        status("suggestion \(index + 1) expanded")
        if let requestID = currentRequestID {
            PendingRunStore.update(requestID: requestID) { payload in
                payload["last_phase"] = "suggestion_expanded"
                payload["expanded_index"] = index + 1
            }
            emitEvent(
                requestID: requestID,
                type: "suggestion_expanded",
                allowLogging: runtimeStore.allowEventLogging,
                clientMetadata: Self.clientMetadata(),
                details: ["chosen_index": index + 1]
            )
        }
    }

    @MainActor
    private func insertSuggestion(index: Int) {
        guard index >= 0 && index < currentSuggestions.count else { return }
        let text = currentSuggestions[index]
        let requestID = currentRequestID
        let clientMetadata = Self.clientMetadata()
        let pinned = overlay.isPinned
        recordChoice(index: index, text: text, action: "inserted")
        // Pinned panel: keep the run live so a follow-up pick / keyboard
        // nav from the same panel still works. The unpinned path tears
        // it all down via resetCurrentRun once dismissAnimated completes.
        if !pinned {
            currentBundleDir = nil
            resetChoiceState(suggestionCount: 0)
        }
        let finishingRequestID = requestID
        let attachmentRefs = index < currentSuggestionDetails.count ? overlay.activeAttachments(for: index) : []
        status("inserting suggestion \(index + 1)...")

        if let requestID {
            terminalEmittedRequestID = requestID
            PendingRunStore.update(requestID: requestID) { payload in
                payload["last_phase"] = "paste_started"
                payload["chosen_index"] = index + 1
            }
            emitEvent(
                requestID: requestID,
                type: "paste_started",
                allowLogging: runtimeStore.allowEventLogging,
                clientMetadata: clientMetadata,
                details: ["chosen_index": index + 1]
            )
        }

        overlay.confirmInsert { [weak self] in
            guard let self else { return }
            if let finishingRequestID {
                guard self.currentRequestID == finishingRequestID else { return }
            } else {
                guard self.currentRequestID == nil else { return }
            }
            let previousApp = self.overlay.previousFrontmost
            let runInsert: () -> Void = { [weak self] in
                guard let self else { return }
                let fileURLs = AttachmentLibrary.shared.resolveURLs(for: attachmentRefs) { [weak self] count in
                    self?.status("\(count) attachment(s) couldn't be found — skipped")
                }
                // Give NSRunningApplication.activate time to land on the previous
                // frontmost app before we synthesize Cmd+V — otherwise the paste
                // sometimes hits Blink's still-active panel context instead.
                Inserter.insert(text: text, fileURLs: fileURLs, activationDelay: 0.15, previousApp: previousApp) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success(let outcome):
                        switch outcome {
                        case .pasted:
                            self.status("inserted suggestion \(index + 1)")
                            self.soundEffects.play(.insert)
                            if let requestID {
                                self.emitEvent(
                                    requestID: requestID,
                                    type: "suggestion_inserted",
                                    allowLogging: self.runtimeStore.allowEventLogging,
                                    clientMetadata: clientMetadata,
                                    details: ["chosen_index": index + 1]
                                )
                                self.emitEvent(
                                    requestID: requestID,
                                    type: "run_completed",
                                    allowLogging: self.runtimeStore.allowEventLogging,
                                    clientMetadata: clientMetadata,
                                    details: ["outcome": "inserted", "chosen_index": index + 1]
                                )
                                PendingRunStore.finish(requestID: requestID)
                            }
                        case .skippedNoTextTarget:
                            self.status("paste skipped - still on clipboard")
                            self.overlay.confirmPasteFallback()
                            if let requestID {
                                self.emitEvent(
                                    requestID: requestID,
                                    type: "paste_skipped",
                                    allowLogging: self.runtimeStore.allowEventLogging,
                                    clientMetadata: clientMetadata,
                                    details: [
                                        "chosen_index": index + 1,
                                        "reason": "no_text_target",
                                    ]
                                )
                                self.emitEvent(
                                    requestID: requestID,
                                    type: "run_completed",
                                    allowLogging: self.runtimeStore.allowEventLogging,
                                    clientMetadata: clientMetadata,
                                    details: ["outcome": "paste_skipped", "chosen_index": index + 1]
                                )
                                PendingRunStore.finish(requestID: requestID)
                            }
                        }
                    case .failure(let error):
                        if let requestID {
                            self.emitEvent(
                                requestID: requestID,
                                type: "paste_failed",
                                allowLogging: self.runtimeStore.allowEventLogging,
                                clientMetadata: clientMetadata,
                                details: [
                                    "chosen_index": index + 1,
                                    "error": self.shortErrorSummary(error),
                                ]
                            )
                            self.emitEvent(
                                requestID: requestID,
                                type: "run_completed",
                                allowLogging: self.runtimeStore.allowEventLogging,
                                clientMetadata: clientMetadata,
                                details: ["outcome": "paste_failed", "chosen_index": index + 1]
                            )
                            PendingRunStore.finish(requestID: requestID)
                        }
                        self.reportFailure(
                            title: "Paste Failed",
                            statusText: "paste failed: \(self.shortErrorSummary(error))",
                            detail: self.detailedErrorMessage(error)
                        )
                    }
                }
            }
            if pinned {
                // Keep the panel exactly as it was — same suggestion
                // cards, same coordinator state — so the user can pick
                // another, copy text, or just leave it sitting. Esc
                // dismisses; ⌘P unpins.
                runInsert()
            } else {
                self.overlay.dismissAnimated {
                    runInsert()
                    self.resetCurrentRun()
                }
            }
        }
    }

    @MainActor
    private func insertCustomReply(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let requestID = currentRequestID
        let clientMetadata = Self.clientMetadata()
        recordCustomReply(text: trimmed)
        status("nice - inserting your reply...")

        if let requestID {
            PendingRunStore.update(requestID: requestID) { payload in
                payload["last_phase"] = "paste_started"
                payload["chosen_action"] = "user_typed"
                payload["custom_reply_at"] = JSONFiles.isoString()
            }
            emitEvent(
                requestID: requestID,
                type: "paste_started",
                allowLogging: runtimeStore.allowEventLogging,
                clientMetadata: clientMetadata,
                details: ["chosen_action": "user_typed"]
            )
        }

        let pasteRequestID = requestID
        let modalCaret = overlay.customInputCaretScreenPoint()
        let pinned = overlay.isPinned
        let previousApp = overlay.previousFrontmost
        let runInsert: () -> Void = { [weak self] in
            guard let self else { return }
            if let pasteRequestID, self.currentRequestID != pasteRequestID {
                return
            }
            if pasteRequestID == nil, self.currentRequestID != nil {
                return
            }
            Inserter.insert(text: trimmed, activationDelay: 0.15, previousApp: previousApp) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let outcome):
                    switch outcome {
                    case .pasted:
                        self.status("inserted your reply")
                        self.soundEffects.play(.insert)
                        self.celebrateAtDestinationCaret(modalFallback: modalCaret)
                        if let requestID {
                            self.emitEvent(
                                requestID: requestID,
                                type: "run_completed",
                                allowLogging: self.runtimeStore.allowEventLogging,
                                clientMetadata: clientMetadata,
                                details: ["outcome": "user_typed"]
                            )
                            PendingRunStore.finish(requestID: requestID)
                        }
                    case .skippedNoTextTarget:
                        self.status("paste skipped - still on clipboard")
                        self.overlay.confirmPasteFallback()
                        if let requestID {
                            self.emitEvent(
                                requestID: requestID,
                                type: "paste_skipped",
                                allowLogging: self.runtimeStore.allowEventLogging,
                                clientMetadata: clientMetadata,
                                details: [
                                    "chosen_action": "user_typed",
                                    "reason": "no_text_target",
                                ]
                            )
                            self.emitEvent(
                                requestID: requestID,
                                type: "run_completed",
                                allowLogging: self.runtimeStore.allowEventLogging,
                                clientMetadata: clientMetadata,
                                details: ["outcome": "paste_skipped", "chosen_action": "user_typed"]
                            )
                            PendingRunStore.finish(requestID: requestID)
                        }
                    }
                case .failure(let error):
                    if let requestID {
                        self.emitEvent(
                            requestID: requestID,
                            type: "paste_failed",
                            allowLogging: self.runtimeStore.allowEventLogging,
                            clientMetadata: clientMetadata,
                            details: [
                                "chosen_action": "user_typed",
                                "error": self.shortErrorSummary(error),
                            ]
                        )
                        self.emitEvent(
                            requestID: requestID,
                            type: "run_completed",
                            allowLogging: self.runtimeStore.allowEventLogging,
                            clientMetadata: clientMetadata,
                            details: ["outcome": "paste_failed", "chosen_action": "user_typed"]
                        )
                        PendingRunStore.finish(requestID: requestID)
                    }
                    self.reportFailure(
                        title: "Paste Failed",
                        statusText: "paste failed: \(self.shortErrorSummary(error))",
                        detail: self.detailedErrorMessage(error)
                    )
                }
            }
        }
        if pinned {
            // Keep the panel exactly as it was after a pinned custom
            // reply — user can keep typing follow-ups in the same panel.
            runInsert()
        } else {
            overlay.dismissAnimated {
                runInsert()
                self.resetCurrentRun()
            }
        }
    }

    @MainActor
    private func resetCurrentRun() {
        currentSuggestions = []
        currentSuggestionDetails = []
        currentBundleDir = nil
        currentRequestID = nil
        terminalEmittedRequestID = nil
        currentStreamingRun = nil
        resetChoiceState(suggestionCount: 0)
        overlay.onCustomInputFocusChanged = nil
        overlay.onCustomInsert = nil
        overlay.onCustomFollowUp = nil
        overlay.onCustomInsertKey = nil
        overlay.onLeaveCustomInputKey = nil
        overlay.onTextEditingKey = nil
        overlay.onRerollKey = nil
        overlay.onTogglePinKey = nil
        overlay.onOutsideClickDismiss = nil
        overlay.onChoiceKey = nil
        overlay.onArrowKey = nil
        overlay.onInsertKey = nil
        overlay.onDismissKey = nil
    }

    private func celebrateAtDestinationCaret(modalFallback: CGPoint? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            if let caret = FocusedContextCapture.caretScreenPoint() {
                ConfettiPanel.fire(at: caret)
            } else if let fallback = modalFallback {
                ConfettiPanel.fire(at: fallback)
            }
        }
    }

    private func isCurrentRequest(_ requestID: String) -> Bool {
        if Thread.isMainThread {
            return currentRequestID == requestID
        }
        return DispatchQueue.main.sync {
            currentRequestID == requestID
        }
    }

    @MainActor
    func dismissOverlay(implicit: Bool = false) {
        if isCollectingActive {
            cancelCollectingSession()
            return
        }
        // Tear down the glass loading even if the result panel never appeared
        // (glass mode suppresses the puck, so the guard below may skip).
        let glassWasActive = glassLoadingActive
        dismissGlassLoading()
        let pendingRequestID = pendingDoubleTapRequestID
        let overlayWasVisible = overlay.isVisible
        // `glassWasActive` keeps Esc working as a mid-stream cancel in glass
        // mode, where the result panel hasn't been shown yet so `isVisible`
        // is still false but an in-flight run needs terminating below.
        guard overlayWasVisible || pendingRequestID != nil || glassWasActive else { return }
        let resolvedRequestID = currentRequestID ?? pendingRequestID
        let alreadyTerminal = (resolvedRequestID != nil && resolvedRequestID == terminalEmittedRequestID)

        // Accident-recovery snapshot: a dismiss that wasn't from a pick
        // (`alreadyTerminal`) and that had real suggestions on screen is
        // a candidate for auto-resume on next hotkey. Only *implicit*
        // dismisses (outside-click) are eligible — Esc means "I'm done."
        // Auto-resume also requires same bundle + same window title at
        // the next hotkey press; both fingerprints are snapshotted here.
        if overlayWasVisible,
           !alreadyTerminal,
           !currentSuggestions.isEmpty {
            // For the bundle/title fingerprint, use the app Blink was
            // summoned over (`previousFrontmost`), not the live
            // frontmost at dismiss time. An outside-click dismiss moves
            // focus to whatever the click landed on first; if that's
            // another app (Chrome behind the panel), `frontmostAppMetadata()`
            // here would return Chrome and the next hotkey-in-Chrome
            // would wrongly auto-resume the Conductor chat. The
            // `previousFrontmost` reference was captured when the panel
            // opened, so it's stable across the dismiss path.
            let meta = frontmostAppMetadata()
            let previousFrontmostBundle = overlay.previousFrontmost?.bundleIdentifier
            let previousFrontmostTitle = overlay.previousFrontmost
                .flatMap { focusedWindowTitle(pid: $0.processIdentifier) }
            let snapshot = LastDismissedSession(
                dismissedAt: Date(),
                bundleDir: currentBundleDir,
                suggestions: currentSuggestions,
                suggestionDetails: currentSuggestionDetails,
                tldr: overlay.summaryFullText,
                customInputText: overlay.customInputText,
                frontmostApp: meta,
                priorRequestID: currentRequestID,
                dismissedExplicitly: !implicit,
                frontmostBundleID: previousFrontmostBundle,
                frontmostWindowTitle: previousFrontmostTitle,
                submittedRun: lastSubmittedRun
            )
            lastDismissedSession = snapshot
            armResumeExpiryTimer()
        }
        let streamingRun = currentStreamingRun
        let cancelledBundleDir = streamingRun?.bundleDir
        let cancelledFirstTokenAt = streamingRun?.firstTokenAt
        let cancelledMidStream = streamingRun?.isRunning == true
            && streamingRun?.finalReceived == false
        if let submission = currentSubmission {
            cancelledSubmissionTokens.insert(submission.token)
            submission.run?.terminate()
            currentSubmission = nil
        }
        streamingRun?.terminate()
        currentStreamingRun = nil
        let dismissedWithoutOverlay = !overlayWasVisible && (pendingRequestID != nil || glassWasActive)
        currentRequestID = nil
        pendingDoubleTapRequestID = nil
        currentBundleDir = nil
        currentSuggestions = []
        currentSuggestionDetails = []
        // The run is going away; drop the staged context too. A
        // subsequent modal multi-frame entry would have nothing prior to
        // extend from, which matches the user's intent on dismissal.
        lastSubmittedRun = nil
        modalChatSnapshot = nil
        if cancelledMidStream,
           let requestID = resolvedRequestID,
           let bundleDirString = cancelledBundleDir {
            recordStreamCancelled(
                bundleDir: URL(fileURLWithPath: bundleDirString),
                requestID: requestID,
                firstTokenAt: cancelledFirstTokenAt
            )
        }
        resetChoiceState(suggestionCount: 0)
        // Coordinator-side pending double-tap state lives on its own queue;
        // tear it down so a follow-on hotkey starts a fresh single-shot
        // session instead of trying to promote a session whose UI was
        // already dismissed.
        clearPendingDoubleTap()
        status("dismissed")
        if !alreadyTerminal && !dismissedWithoutOverlay {
            recordDismiss()
        }
        if let requestID = resolvedRequestID, !alreadyTerminal {
            let clientMetadata = Self.clientMetadata()
            // Esc inside the double-tap window cancels a submission that
            // never rendered a suggestion to the user. Reporting it as a
            // suggestion_dismissed misleads downstream analytics, so emit
            // the cancellation event family instead.
            if dismissedWithoutOverlay {
                emitEvent(
                    requestID: requestID,
                    type: "capture_cancelled",
                    allowLogging: runtimeStore.allowEventLogging,
                    clientMetadata: clientMetadata,
                    details: ["phase": pendingRequestID != nil ? "double_tap_window" : "loading"]
                )
                emitEvent(
                    requestID: requestID,
                    type: "run_completed",
                    allowLogging: runtimeStore.allowEventLogging,
                    clientMetadata: clientMetadata,
                    details: ["outcome": "cancelled"]
                )
            } else {
                emitEvent(
                    requestID: requestID,
                    type: "suggestion_dismissed",
                    allowLogging: runtimeStore.allowEventLogging,
                    clientMetadata: clientMetadata,
                    details: [:]
                )
                emitEvent(
                    requestID: requestID,
                    type: "run_completed",
                    allowLogging: runtimeStore.allowEventLogging,
                    clientMetadata: clientMetadata,
                    details: ["outcome": "dismissed"]
                )
            }
            PendingRunStore.finish(requestID: requestID)
        }
        overlay.dismissAnimated { [weak self] in
            self?.resetCurrentRun()
        }
    }

    private func makeStagingDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blink-\(ArtifactWriter.newBundleID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func makeThumbnail(from pngData: Data, maxHeight: CGFloat = 80) -> NSImage? {
        guard let source = NSImage(data: pngData) else { return nil }
        let size = source.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxHeight / size.height)
        let target = NSSize(width: size.width * scale, height: size.height * scale)
        let thumb = NSImage(size: target)
        thumb.lockFocus()
        source.draw(in: NSRect(origin: .zero, size: target))
        thumb.unlockFocus()
        return thumb
    }

    private func replaceFrameFile(at destination: URL, with source: URL) throws {
        _ = try FileManager.default.replaceItemAt(
            destination,
            withItemAt: source,
            backupItemName: nil,
            options: []
        )
    }

    private func makeRequestEnvelope(
        requestID: String,
        runtime: RuntimeConfigFile,
        clientMetadata: [String: Any],
        frontmostApp: [String: Any],
        screenshotMeta: [String: Any],
        diagnostics: [String: Any],
        focusedContext: [String: Any],
        axTree: String? = nil,
        axTreeNodes: Int? = nil,
        axTreeTruncated: Bool = false,
        mouseScreenPoint: CGPoint? = nil,
        captureMode: String = "frontmost_window",
        frames: [CapturedFrame] = [],
        attachmentsCatalog: [[String: Any]] = []
    ) -> [String: Any] {
        var preferences = requestPreferences(runtime: runtime)
        preferences["model"] = runtime.model
        preferences["supports_attachments"] = true
        var envelope: [String: Any] = [
            "schema_version": 1,
            "request_id": requestID,
            "client": clientMetadata,
            "capture_mode": captureMode,
            "preferences": preferences,
            "frontmost_app": frontmostApp,
            "input_mode": "screenshot",
            "screenshot": screenshotMeta,
            "frames": framePayloads(frames),
            "image_diagnostics": diagnostics,
            "ocr_packet": NSNull(),
            "focused_context": focusedContext,
            "consent": [
                "allow_event_logging": runtime.allowEventLogging,
                "allow_content_retention": runtime.allowContentRetention,
            ],
        ]
        if let axTree, !axTree.isEmpty {
            envelope["ax_tree"] = axTree
            if let axTreeNodes {
                envelope["ax_tree_nodes"] = axTreeNodes
            }
            // True when the client node cap stopped the walk — distinguishes
            // "tree genuinely small" from "tree hit the 4000-node ceiling".
            envelope["ax_tree_truncated"] = axTreeTruncated
        }
        if !attachmentsCatalog.isEmpty {
            envelope["attachments_catalog"] = attachmentsCatalog
        }
        if let mouseScreenPoint {
            envelope["mouse_screen_point"] = [
                "x": mouseScreenPoint.x,
                "y": mouseScreenPoint.y,
                "coordinate_space": "appkit_screen",
            ]
        }
        let selectionPayloads = frames.compactMap { frame in
            frame.selection?.uploadPayload()
        }
        if !selectionPayloads.isEmpty {
            envelope["selections"] = selectionPayloads
            // Convenience: the most recent non-nil selection. Lets the
            // server treat "selection" as the single primary text input
            // without iterating the per-frame list.
            if let latest = frames.reversed().lazy.compactMap(\.selection).first {
                envelope["selection"] = latest.uploadPayload()
            }
        }
        return envelope
    }

    private func requestPreferences(runtime: RuntimeConfigFile) -> [String: Any] {
        var preferences: [String: Any] = [
            "model": runtime.model,
            "style": "default",
        ]
        if let level = runtime.thinkingLevel, !level.isEmpty {
            preferences["thinking_level"] = level
        }
        if let format = runtime.outputFormat, !format.isEmpty {
            preferences["output_format"] = format
        }
        if let settingsPath = Paths.settingsPath,
           let settings = JSONFiles.readObject(at: settingsPath) {
            if let temperature = settings["temperature"] {
                preferences["temperature"] = temperature
            }
            if let maxOutputTokens = settings["max_output_tokens"] {
                preferences["max_output_tokens"] = maxOutputTokens
            }
        }
        return preferences
    }

    private func frontmostAppMetadata() -> [String: Any] {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return [:]
        }
        var meta: [String: Any] = [
            "bundle_id": app.bundleIdentifier as Any,
            "app_name": app.localizedName as Any,
            "pid": Int(app.processIdentifier),
        ]
        if let title = focusedWindowTitle(pid: app.processIdentifier), !title.isEmpty {
            meta["window_title"] = title
        }
        return meta
    }

    /// Best-effort focused window title for a given pid via AX. Returns
    /// nil when AX is denied, the app has no focused window, or the
    /// window has no title. Used to fingerprint "same window" for the
    /// auto-resume gate.
    private func focusedWindowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.1)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedRef
        ) == .success, let focusedRef else { return nil }
        let windowElement = focusedRef as! AXUIElement
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            windowElement,
            kAXTitleAttribute as CFString,
            &titleRef
        ) == .success else { return nil }
        return titleRef as? String
    }

    private func failureEventType(for error: Error, lastPhase: String) -> String {
        if let captureError = error as? ScreenCapture.CaptureError,
           case .permissionDenied = captureError {
            return "capture_permission_denied"
        }
        if lastPhase == "request_upload_started" {
            return "request_upload_failed"
        }
        return "capture_failed"
    }

    private func recordStreamCancelled(
        bundleDir: URL,
        requestID: String,
        firstTokenAt: Date?
    ) {
        let path = bundleDir.appendingPathComponent("host_profile.json")
        var payload = JSONFiles.readObject(at: path) ?? [:]
        payload["request_id"] = requestID
        payload["cancelled_at"] = JSONFiles.isoString()
        if let firstTokenAt {
            payload["first_token_at"] = JSONFiles.isoString(firstTokenAt)
        }
        try? JSONFiles.writeObject(payload, to: path)
    }

    private func updateRunHostProfile(
        bundleDir: URL,
        requestID: String,
        captureMS: Int,
        pythonMS: Int,
        totalMS: Int,
        result: PythonRunner.ResultPayload,
        firstTokenAt: Date?,
        streamCompletedAt: Date?
    ) throws {
        let path = bundleDir.appendingPathComponent("host_profile.json")
        var payload = JSONFiles.readObject(at: path) ?? [:]
        payload["request_id"] = requestID
        payload["host_capture_ms"] = captureMS
        payload["host_python_wall_ms"] = pythonMS
        payload["host_total_ms"] = totalMS
        payload["server_duration_ms"] = result.durationMS as Any
        payload["model"] = result.model as Any
        payload["warnings"] = result.warnings
        payload["finished_at"] = JSONFiles.isoString()
        if let firstTokenAt {
            payload["first_token_at"] = JSONFiles.isoString(firstTokenAt)
        }
        if let streamCompletedAt {
            payload["stream_completed_at"] = JSONFiles.isoString(streamCompletedAt)
        }
        try JSONFiles.writeObject(payload, to: path)
    }

    @MainActor
    private func recordChoice(index: Int, text: String, action: String) {
        guard let bundleDir = currentBundleDir else { return }
        let path = bundleDir.appendingPathComponent("run.json")
        var payload = JSONFiles.readObject(at: path) ?? [:]
        payload["chosen_index"] = index + 1
        payload["chosen_text"] = text
        payload["chosen_at"] = JSONFiles.isoString()
        payload["chosen_action"] = action
        try? JSONFiles.writeObject(payload, to: path)
    }

    @MainActor
    private func recordCustomReply(text: String) {
        guard let bundleDir = currentBundleDir else { return }
        let path = bundleDir.appendingPathComponent("run.json")
        var payload = JSONFiles.readObject(at: path) ?? [:]
        payload["chosen_index"] = NSNull()
        payload["chosen_text"] = NSNull()
        payload["chosen_at"] = JSONFiles.isoString()
        payload["chosen_action"] = "user_typed"
        payload["custom_reply_text"] = text
        payload["custom_reply_at"] = payload["chosen_at"]
        try? JSONFiles.writeObject(payload, to: path)
    }

    private func recordDismiss() {
        guard let bundleDir = currentBundleDir else { return }
        let path = bundleDir.appendingPathComponent("run.json")
        var payload = JSONFiles.readObject(at: path) ?? [:]
        payload["dismissed_at"] = JSONFiles.isoString()
        try? JSONFiles.writeObject(payload, to: path)
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func emitEvent(
        requestID: String,
        type: String,
        createdAt: String? = nil,
        allowLogging: Bool,
        clientMetadata: [String: Any],
        details: [String: Any] = [:]
    ) {
        eventClient.send(
            requestID: requestID,
            eventType: type,
            allowLogging: allowLogging,
            clientMetadata: clientMetadata,
            details: details,
            createdAt: createdAt
        )
    }

    private func status(_ text: String) {
        DispatchQueue.main.async {
            self.onStatusChange?(text)
            self.statusSubject.send(text)
        }
    }

    private func reportFailure(
        title: String,
        statusText: String,
        detail: String,
        file: String = #fileID,
        line: Int = #line
    ) {
        // Dogfood diagnostic for the "Funk boop on hotkey" report:
        // every code path that plays the hardError chime logs its
        // source location and the detail. Once the boop reproduces,
        // `log show --predicate 'subsystem == "com.henryz2004.blink"' --info`
        // pinpoints which `reportFailure` call site fired.
        latencyLogger.error(
            "report_failure at \(file, privacy: .public):\(line, privacy: .public) title=\(title, privacy: .public) status=\(statusText, privacy: .public) detail=\(detail, privacy: .public)"
        )
        status(statusText)
        DispatchQueue.main.async {
            self.soundEffects.play(.hardError)
            self.onFailureNotice?(title, detail)
        }
    }

    private func shortErrorSummary(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription {
            return localized
        }
        return error.localizedDescription
    }

    private func detailedErrorMessage(_ error: Error) -> String {
        shortErrorSummary(error)
    }

    private func durationMS(since start: DispatchTime) -> Int {
        durationMS(from: start, to: monotonicNow())
    }

    private func durationMS(from start: DispatchTime, to end: DispatchTime) -> Int {
        Int(Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0)
    }

    private func monotonicNow() -> DispatchTime {
        DispatchTime.now()
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
