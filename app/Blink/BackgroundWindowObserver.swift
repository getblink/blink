import ApplicationServices
import AppKit
import Foundation
import OSLog

/// Watches a BOUNDED set of background apps (Slack, Messages, Mail, …) for
/// *content* changes — new messages arriving in windows the user is NOT looking
/// at — and emits a debounced delta when a watched window's content actually
/// changes. The catch-up counterpart to the hotkey path: instead of the user
/// invoking a capture, a background thread updating triggers one.
///
/// New content arrives WITHOUT moving the window or (always) changing the
/// title, so we detect it via content-change AX notifications plus a cheap
/// content *signature* — not rect or title.
///
/// Bounded by design: only the configured bundle IDs are observed, the
/// frontmost app is suppressed (the hotkey path owns it), and each app is
/// trailing-debounced so the burst of AX events for one incoming message
/// collapses to a single delta once things settle.
///
/// Detection only — it emits a `Delta`; the caller decides whether to fire a
/// background capture (`BlinkCoordinator.prefetchBackgroundWindow`). Requires
/// the same Accessibility trust the rest of the app needs; the only new surface
/// is that AX reads now touch background apps too.
@MainActor
final class BackgroundWindowObserver {
    /// A watched background window's content changed.
    struct Delta {
        let bundleID: String
        let pid: pid_t
        let windowTitle: String?
        /// Which AX notification ultimately triggered the settled delta.
        let signal: String
    }

    private let watchedBundleIDs: Set<String>
    private let onDelta: (Delta) -> Void
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.henryz2004.blink",
        category: "bg_observer"
    )

    private struct Binding {
        let pid: pid_t
        let bundleID: String
        let observer: AXObserver
        let element: AXUIElement
        /// Hash of the focused window's bounded content text at the last emit.
        /// In-memory only (Hasher isn't stable across processes), which is all
        /// we need — we only compare within one running session.
        var lastSignature: Int?
    }

    private var bindings: [pid_t: Binding] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Per-pid generation counter for trailing-edge debounce: each AX event
    /// bumps the gen and schedules a settle check; only the latest survives.
    private var pendingGen: [pid_t: Int] = [:]

    /// Content-change notifications. Deliberately NOT focused-element /
    /// selected-text (those are user-driven — the hotkey path's job).
    private let notifications: [String] = [
        kAXRowCountChangedNotification,   // new row in a list/table = new message
        kAXValueChangedNotification,      // unread badge / text value changed
        kAXCreatedNotification,           // new UI element appeared
        kAXLayoutChangedNotification,     // content reflow
    ]

    private static let debounceSeconds: TimeInterval = 0.8
    private static let nodeBudget = 400    // AX nodes walked when signing content
    private static let charBudget = 4000   // chars folded into the signature
    private static let titleLogLimit = 60

    init(watchedBundleIDs: Set<String>, onDelta: @escaping (Delta) -> Void) {
        self.watchedBundleIDs = watchedBundleIDs
        self.onDelta = onDelta
    }

    deinit {
        // Not MainActor-isolated; AXObserver* and CFRunLoop* are thread-safe per
        // AX/CF conventions. Remove run-loop sources here too as a backstop:
        // otherwise a queued AX callback could fire into the freed instance via
        // the passUnretained refcon (use-after-free). stop()/unbind do this on
        // the normal path; this covers release-without-stop().
        let main = CFRunLoopGetMain()
        for b in bindings.values {
            for name in notifications {
                AXObserverRemoveNotification(b.observer, b.element, name as CFString)
            }
            CFRunLoopRemoveSource(main, AXObserverGetRunLoopSource(b.observer), .defaultMode)
        }
    }

    // MARK: - Lifecycle

    func start() {
        for app in NSWorkspace.shared.runningApplications {
            if let bid = app.bundleIdentifier, watchedBundleIDs.contains(bid) {
                bind(pid: app.processIdentifier, bundleID: bid)
            }
        }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            let obs = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bid = app.bundleIdentifier else { return }
                MainActor.assumeIsolated {
                    guard let self, self.watchedBundleIDs.contains(bid) else { return }
                    if name == NSWorkspace.didLaunchApplicationNotification {
                        self.bind(pid: app.processIdentifier, bundleID: bid)
                    } else {
                        self.unbind(pid: app.processIdentifier)
                    }
                }
            }
            workspaceObservers.append(obs)
        }
        logger.notice("bg_observer_started watched=\(self.watchedBundleIDs.sorted().joined(separator: ","), privacy: .public) bound=\(self.bindings.count)")
    }

    func stop() {
        for pid in Array(bindings.keys) { unbind(pid: pid) }
        let nc = NSWorkspace.shared.notificationCenter
        for obs in workspaceObservers { nc.removeObserver(obs) }
        workspaceObservers.removeAll()
    }

    // MARK: - Bind / unbind (per pid)

    private func bind(pid: pid_t, bundleID: String) {
        guard pid > 0, bindings[pid] == nil else { return }
        var rawObserver: AXObserver?
        guard AXObserverCreate(pid, BackgroundWindowObserver.axCallback, &rawObserver) == .success,
              let observer = rawObserver else {
            logger.notice("bg_observer_create_failed pid=\(pid) bundle=\(bundleID, privacy: .public)")
            return
        }
        let element = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var registered: [String] = []
        for name in notifications {
            let err = AXObserverAddNotification(observer, element, name as CFString, refcon)
            if err == .success {
                registered.append(name)
            } else if err != .notificationUnsupported {
                logger.notice("bg_observer_register_failed pid=\(pid) name=\(name, privacy: .public) err=\(err.rawValue)")
            }
        }
        guard !registered.isEmpty else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        bindings[pid] = Binding(
            pid: pid, bundleID: bundleID, observer: observer, element: element,
            lastSignature: Self.contentSignature(forApp: element)  // seed so the first real change is a delta
        )
        logger.notice("bg_observer_bound pid=\(pid) bundle=\(bundleID, privacy: .public) signals=\(registered.count)")
    }

    private func unbind(pid: pid_t) {
        guard let b = bindings.removeValue(forKey: pid) else { return }
        for name in notifications {
            AXObserverRemoveNotification(b.observer, b.element, name as CFString)
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(b.observer), .defaultMode)
        pendingGen[pid] = nil
    }

    // MARK: - Notification → (debounce) → content-delta

    fileprivate func handleNotification(_ name: String, pid: pid_t) {
        // The hotkey path owns the frontmost app; don't double-report.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != pid else { return }
        guard bindings[pid] != nil else { return }
        // Trailing-edge debounce: coalesce the burst one incoming message
        // produces, and only sign/emit once the app goes quiet.
        let gen = (pendingGen[pid] ?? 0) + 1
        pendingGen[pid] = gen
        let signal = Self.shortName(name)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceSeconds) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pendingGen[pid] == gen else { return }  // superseded
                self.emitIfChanged(pid: pid, signal: signal)
            }
        }
    }

    private func emitIfChanged(pid: pid_t, signal: String) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != pid else { return }
        guard var b = bindings[pid] else { return }
        // No real content change (layout jitter / cursor blink / unchanged
        // value) → not worth a capture. This is what makes "new message in an
        // unmoved window" detectable where rect/title checks are blind.
        guard let sig = Self.contentSignature(forApp: b.element), sig != b.lastSignature else { return }
        b.lastSignature = sig
        bindings[pid] = b
        let title = Self.focusedWindowTitle(forApp: b.element)
        logger.notice("bg_delta bundle=\(b.bundleID, privacy: .public) signal=\(signal, privacy: .public) window=\(Self.truncate(title), privacy: .public)")
        onDelta(Delta(bundleID: b.bundleID, pid: pid, windowTitle: title, signal: signal))
    }

    private static let axCallback: AXObserverCallback = { _, element, name, refcon in
        guard let refcon else { return }
        let me = Unmanaged<BackgroundWindowObserver>.fromOpaque(refcon).takeUnretainedValue()
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let nameString = name as String
        MainActor.assumeIsolated {
            me.handleNotification(nameString, pid: pid)
        }
    }

    // MARK: - Content signature (bounded DFS of the focused window's text)

    private static func contentSignature(forApp app: AXUIElement) -> Int? {
        guard let window = primaryWindow(forApp: app) else { return nil }
        var hasher = Hasher()
        var nodes = nodeBudget
        var chars = charBudget
        var stack: [AXUIElement] = [window]
        while let el = stack.popLast(), nodes > 0, chars > 0 {
            nodes -= 1
            for attr in [kAXValueAttribute, kAXTitleAttribute] {
                if let s = stringAttribute(el, attr), !s.isEmpty {
                    let slice = String(s.prefix(chars))
                    hasher.combine(slice)
                    chars -= slice.count
                }
            }
            stack.append(contentsOf: children(el))
        }
        return hasher.finalize()
    }

    // MARK: - AX helpers

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw) == .success,
              let arr = raw as? [AXUIElement] else { return [] }
        return arr
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? String
    }

    /// Focused window → main window → first window. A background app may have
    /// no AX "focused" window.
    private static func primaryWindow(forApp app: AXUIElement) -> AXUIElement? {
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var raw: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, attr as CFString, &raw) == .success,
               let w = raw, CFGetTypeID(w) == AXUIElementGetTypeID() {
                return (w as! AXUIElement)
            }
        }
        var raw: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
           let windows = raw as? [AXUIElement], let first = windows.first {
            return first
        }
        return nil
    }

    private static func focusedWindowTitle(forApp app: AXUIElement) -> String? {
        guard let window = primaryWindow(forApp: app) else { return nil }
        return stringAttribute(window, kAXTitleAttribute)
    }

    private static func shortName(_ axNotification: String) -> String {
        switch axNotification {
        case kAXRowCountChangedNotification: return "row_count"
        case kAXValueChangedNotification: return "value"
        case kAXCreatedNotification: return "created"
        case kAXLayoutChangedNotification: return "layout"
        default: return axNotification
        }
    }

    private static func truncate(_ title: String?) -> String {
        guard let title, !title.isEmpty else { return "<nil>" }
        return title.count <= titleLogLimit ? title : "\(title.prefix(titleLogLimit))…"
    }
}
