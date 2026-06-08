import SwiftUI
import AppKit

// Production port of the chosen capture-loading prototype (LGProto15): a clear
// Liquid Glass lens over the captured window that drains immediately toward the
// bottom-right corner, condensing into a glass "blinking…" pill. The Blink
// mascot greets with a happy ^_^, then the label retracts so the capsule
// contracts to a round face that idles for the rest of the wait — blinking
// periodically, glancing around, and gently bobbing. Hosted in a transparent,
// click-through NSPanel laid over the live window, so the glass refracts the
// real screen. Opt-in via BLINK_GLASS_LOADING; the default puck path is unchanged.

// MARK: - easing

private func glClamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { min(hi, max(lo, x)) }
private func glSeg(_ p: Double, _ a: Double, _ b: Double) -> Double { glClamp((p - a) / (b - a)) }
private func glEaseOut(_ t: Double) -> Double { 1 - pow(1 - glClamp(t), 3) }
private func glEaseOutQuart(_ t: Double) -> Double { 1 - pow(1 - glClamp(t), 4) }   // soft settle
private func glSmooth(_ t: Double) -> Double { let t = glClamp(t); return t * t * (3 - 2 * t) }  // ease-in-out: gentle start + soft settle
private func glSpring(_ t: Double) -> Double { let t = glClamp(t); return 1 - exp(-5 * t) * cos(4.6 * t) }

/// Cheap deterministic hash → [0,1). Lets the idle loop pick "random-looking"
/// flourishes straight from the elapsed-time clock, with no real RNG (which
/// would break the frame-pure TimelineView and not survive a re-render).
private func glHash(_ n: Double) -> Double {
    let x = sin(n * 12.9898) * 43758.5453
    return x - floor(x)
}

/// Everything the idling mascot is doing at a moment, derived purely from
/// `idle` (seconds since it settled into the round badge). Each ~2.4s "beat"
/// blinks; with a fixed chance — from the very first beat, not gated by how
/// long the wait runs — it adds a flourish: glance, head tilt, hop, wobble,
/// happy flash, or a full spin.
private struct GLIdle {
    var blink = 0.0       // eyelid squash, 0…1
    var look = 0.0        // pupil dart, -1…1
    var rotation = 0.0    // mascot rotation, degrees
    var squash = 0.0      // + wider/shorter, - taller/narrower
    var hop = 0.0         // vertical offset, points (up positive)
    var happy = 0.0       // momentary ^_^ flash, 0…1
}

private func glIdle(_ idle: Double) -> GLIdle {
    guard idle > 0 else { return GLIdle() }
    var out = GLIdle()
    let beatLen = 2.4
    let beat = floor(idle / beatLen)
    let phase = idle - beat * beatLen
    let start = 0.22

    // Always: a soft breathing bob and a blink at the top of each beat.
    out.hop = sin(idle * 1.7)
    if phase < 0.16 { out.blink = sin(.pi * phase / 0.16) }

    // Each beat has a fixed chance of a flourish, drawn from the full set from
    // the very first beat — the wait length gates none of it.
    guard glHash(beat) < 0.5 else { return out }

    let pick = glHash(beat * 7 + 3)

    if pick < 0.25 {
        // SPIN — a full, settling 360 with a little squash through the turn.
        let x = glClamp((phase - start) / 0.9)
        out.rotation = 360 * glEaseOutQuart(x)
        out.squash = sin(.pi * x) * 0.12
        out.blink = max(out.blink, 0.15)
    } else if pick < 0.42 {
        // HOP — anticipate, launch, land.
        let x = glClamp((phase - start) / 0.5)
        out.hop -= sin(.pi * x) * 6
        out.squash = (x < 0.15 || x > 0.85) ? 0.18 : -0.10 * sin(.pi * x)
    } else if pick < 0.62 {
        // TILT — curious head tilt, eyes leading.
        let x = glClamp((phase - start) / 0.8)
        let dir: Double = glHash(beat * 3 + 1) < 0.5 ? -1 : 1
        out.rotation = dir * 12 * sin(.pi * x)
        out.look = dir * 0.6 * sin(.pi * x)
    } else if pick < 0.80 {
        // GLANCE — dart the eyes and hold a beat.
        let x = glClamp((phase - start) / 0.9)
        let dir: Double = glHash(beat * 5 + 2) < 0.5 ? -1 : 1
        out.look = dir * sin(.pi * x)
    } else if pick < 0.91 {
        // WOBBLE — quick damped shimmy.
        let x = glClamp((phase - start) / 0.6)
        out.rotation = sin(x * .pi * 3) * 8 * (1 - x)
    } else {
        // HAPPY FLASH — a fleeting ^_^.
        let x = glClamp((phase - start) / 0.6)
        out.happy = sin(.pi * x)
    }
    return out
}

private let glInk = Color(red: 0.090, green: 0.125, blue: 0.200)   // #172033

// MARK: - mascot (eyes animate normal → happy ^_^)

private struct GLSmile: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(); p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.midX, y: r.maxY + r.height)); return p
    }
}
private struct GLHappyEye: Shape {
    var openness: Double
    func path(in r: CGRect) -> Path {
        var p = Path(); let arch = r.height * CGFloat(glClamp(openness))
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.midX, y: r.maxY - 2 * arch)); return p
    }
}
private struct BlinkLoadingMascot: View {
    var happy: Double            // 0 = normal round eyes, 1 = happy ^_^
    var blink: Double = 0        // 0 = eyes open, 1 = eyelids shut
    var look: Double = 0         // -1 = glance left, +1 = glance right
    var size: CGFloat = 30
    var body: some View {
        let s = size, outerH = s * 0.958, border = s * 0.108, h = glClamp(happy)
        ZStack {
            RoundedRectangle(cornerRadius: s * 0.29, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.204, green: 0.231, blue: 0.290),
                                              Color(red: 0.169, green: 0.196, blue: 0.251)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: s, height: outerH)
            RoundedRectangle(cornerRadius: s * 0.215, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 1.0, green: 0.976, blue: 0.941),
                                              Color(red: 0.976, green: 0.945, blue: 0.906)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: s - 2 * border, height: outerH - 2 * border)
            HStack(spacing: s * 0.215) { eye(h); eye(h) }.offset(y: -s * 0.01)
            GLSmile().stroke(glInk, style: StrokeStyle(lineWidth: s * 0.066, lineCap: .round))
                .frame(width: s * 0.22, height: s * 0.085).offset(y: s * 0.18)
        }
        .frame(width: size, height: size)
    }
    @ViewBuilder private func eye(_ h: Double) -> some View {
        let s = size
        ZStack {
            Circle().fill(glInk).frame(width: s * 0.128, height: s * 0.128)
                .scaleEffect(1 - 0.18 * CGFloat(h))
                .offset(x: s * 0.05 * CGFloat(look), y: s * 0.018 * CGFloat(h))
                .opacity(1 - glClamp(h * 1.8))
            GLHappyEye(openness: 1).stroke(glInk, style: StrokeStyle(lineWidth: s * 0.052, lineCap: .round))
                .frame(width: s * 0.16, height: s * 0.085).opacity(glClamp((h - 0.45) * 1.8))
        }
        .frame(width: s * 0.16, height: s * 0.128)
        // Eyelid: squash the eye toward a closed line on a blink.
        .scaleEffect(x: 1, y: CGFloat(1 - 0.9 * glClamp(blink)), anchor: .center)
    }
}

private struct GLPill: View {
    var happy: Double
    var blink: Double = 0
    var look: Double = 0
    var rotation: Double = 0      // mascot rotation (tilt / spin), degrees
    var squash: Double = 0        // + wider/shorter, - taller/narrower
    var textReveal: Double = 1    // 1 = "blinking…" shown, 0 = collapsed to the mascot
    var mascotSize: CGFloat = 34

    private static let labelText = "blinking…"
    // Measured once so the label's frame can collapse to zero width as it
    // retracts, contracting the capsule down to a round mascot badge.
    private static let labelWidth: CGFloat = {
        let attrs = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 14, weight: .medium)]
        return ceil((labelText as NSString).size(withAttributes: attrs).width)
    }()

    var body: some View {
        // No fixed text color: the default foreground is the adaptive label color,
        // and on glass the system renders it with vibrancy so it stays legible
        // over light or dark windows. (The mascot keeps its own drawn colors since
        // it carries its own light face.)
        let reveal = glClamp(textReveal)
        let content = HStack(spacing: 9 * reveal) {
            BlinkLoadingMascot(happy: happy, blink: blink, look: look, size: mascotSize)
                .rotationEffect(.degrees(rotation))
                .scaleEffect(x: 1 + CGFloat(squash), y: 1 - CGFloat(squash))
            Text(Self.labelText).font(.system(size: 14, weight: .medium))
                .fixedSize()
                .frame(width: Self.labelWidth * reveal, alignment: .leading)
                .opacity(glClamp((reveal - 0.25) / 0.75))
                .clipped()
        }
        // Equal padding on every side so the collapsed badge is a true circle
        // (square content + equal insets → a capsule with equal width/height).
        .padding(.leading, 11)
        .padding(.trailing, 11 + 5 * reveal)
        .padding(.vertical, 11)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().stroke(.white.opacity(0.3), lineWidth: 1))
        }
    }
}

// MARK: - the loading view (elapsed-time driven intro, then steady "Reading…")

struct GlassCaptureLoadingView: View {
    var size: CGSize
    var cornerRadius: CGFloat = 12
    private let lensStrength: Double = 0.48
    private let drainDur: Double = 0.6
    /// Width of the drain's soft edge as a fraction of the diagonal sweep — the
    /// feather between fully-drained (clear) and not-yet-drained (glass). Larger
    /// = a longer, gentler gradient; smaller = a crisper wipe line.
    private let drainFeather: Double = 0.34
    /// Intro pace. 1.0 = original timing; higher = snappier. The elapsed clock
    /// is multiplied by this, so every phase below (lens drain, pill grow, eye
    /// smile) tightens together — one number tunes the whole sequence rather
    /// than re-balancing each segment. At the 1.25 default, the ~0.6s drain
    /// runs in ~0.48s and the full intro lands in just under a second. Injected
    /// from `RuntimeConfigStore`
    /// (Settings → Advanced); the default here is the fallback for previews and
    /// the launch prewarm.
    var speed: Double = RuntimeConfigFile.defaultLensAnimationSpeed
    /// When re-anchoring the live lens to a new rect mid-drain (the precise
    /// captured rect can arrive after the instant-ack guess — notably in
    /// fullscreen), the controller passes the original drain start here so the
    /// animation CONTINUES from where it was instead of replaying from frame zero.
    /// nil on a fresh present.
    var startOverride: Date? = nil
    /// Reports the resolved drain start back to the controller on first appear, so
    /// it can be replayed into a later re-anchor.
    var onStart: ((Date) -> Void)? = nil
    // Anchored to the first rendered frame (.onAppear), not view init — the glass
    // surface has a first-composite warmup, and starting the clock at init meant
    // the first visible frame already landed mid-drain.
    @State private var start: Date? = nil

    var body: some View {
        TimelineView(.animation) { ctx in
            // Scale the elapsed clock by `speed` so the whole intro sequence
            // tightens uniformly; segment boundaries below stay in nominal time.
            // Floor the multiplier so a stray 0/negative from a hand-edited
            // config can't freeze or reverse the drain.
            // Prefer the persisted @State start; fall back to the controller's
            // startOverride so an in-place re-anchor (which swaps rootView without
            // a fresh .onAppear) keeps a continuous clock even if @State is reset.
            let clockStart = start ?? startOverride
            let t = (clockStart.map { ctx.date.timeIntervalSince($0) } ?? 0) * max(0.25, speed)
            let appear = glEaseOut(glSeg(t, 0.0, 0.05))
            let drain = glSmooth(glSeg(t, 0.0, drainDur))                  // ease-in: gentle start so a warmup hitch isn't mid-sweep
            let grow = glSpring(glSeg(t, 0.18, 0.70))
            let pillScale = 0.18 + 0.82 * grow
            let pillOpacity = glEaseOut(glSeg(t, 0.18, 0.55))
            // Greet with a smile, then relax back to open, attentive eyes.
            let smile = glEaseOut(glSeg(t, 0.70, 1.10))
            let relax = glSmooth(glSeg(t, 1.25, 1.75))
            let happy = smile * (1 - relax)
            // "blinking…" reveals with the pill, then retracts to leave the mascot.
            let textIn = glEaseOut(glSeg(t, 0.32, 0.66))
            let textOut = glSmooth(glSeg(t, 1.55, 2.0))
            let textReveal = textIn * (1 - textOut)
            // Idle loop once the label is gone: blink + escalating flourishes
            // (glance, tilt, hop, wobble, happy flash, and spins on long waits).
            let idle = max(0, t - 2.0)
            let mv = glIdle(idle)

            ZStack {
                lens(drain: drain).opacity(appear * lensStrength)
                ZStack(alignment: .bottomTrailing) {
                    Color.clear
                    GLPill(happy: max(happy, mv.happy), blink: mv.blink, look: mv.look,
                           rotation: mv.rotation, squash: mv.squash, textReveal: textReveal)
                        .scaleEffect(pillScale)
                        .opacity(pillOpacity)
                        .offset(y: -CGFloat(mv.hop))
                }
                .frame(width: size.width - 32, height: size.height - 32, alignment: .bottomTrailing)
            }
            .frame(width: size.width, height: size.height)
            .onAppear {
                if start == nil {
                    let s = startOverride ?? ctx.date
                    start = s
                    onStart?(s)
                }
            }
        }
    }

    @ViewBuilder private func lens(drain: Double) -> some View {
        let mask = LinearGradient(
            stops: [.init(color: .clear, location: min(drain, 0.999)),
                    .init(color: .black, location: min(drain + drainFeather, 1.0))],
            startPoint: .topLeading, endPoint: .bottomTrailing)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            Color.clear.frame(width: size.width, height: size.height)
                .glassEffect(.clear, in: shape).mask(mask)
        } else {
            shape.fill(.ultraThinMaterial).frame(width: size.width, height: size.height).mask(mask)
        }
    }
}

// MARK: - controller (transparent click-through panel over the captured window)

final class GlassCaptureLoadingController {
    private var panel: NSPanel?
    private var backstop: DispatchWorkItem?
    /// Drain start of the live presentation, reported by the view on first appear.
    /// Replayed into a `reanchor` so the move continues the animation instead of
    /// restarting it. Reset on every fresh `show`.
    private var animationStart: Date?
    /// The live hosting view, retained so `reanchor` can resize it IN PLACE rather
    /// than rebuild the panel — reusing the same glass surface avoids the
    /// first-composite warmup (a visible stutter) a fresh panel would pay.
    private var host: NSHostingView<GlassCaptureLoadingView>?
    /// Invoked (on the main thread) only when the 90s backstop fires — i.e. the
    /// panel was torn down without the normal coordinator dismiss path. Lets the
    /// coordinator clear any state it armed for the loading session (e.g. the
    /// overlay-active key-tap mirror) so a hung request can't leave it stuck.
    var onBackstop: (() -> Void)?

    /// Present the glass loading over `windowRect` (AppKit screen coords) with a
    /// fresh drain. Safe to call repeatedly; replaces any existing presentation.
    func show(
        windowRect: NSRect,
        cornerRadius: CGFloat = 12,
        speed: Double = RuntimeConfigFile.defaultLensAnimationSpeed
    ) {
        animationStart = nil
        present(windowRect: windowRect, cornerRadius: cornerRadius, speed: speed, startOverride: nil)
    }

    /// Re-anchor the live lens to a new rect WITHOUT restarting the drain. The
    /// precise captured rect can differ from the instant-ack guess (notably in
    /// fullscreen, where CGWindowList reports the window minus the menu bar while
    /// the capture is the full display); continuing from the original start makes
    /// the reposition read as one uninterrupted drain rather than a visible replay.
    func reanchor(
        to windowRect: NSRect,
        cornerRadius: CGFloat = 12,
        speed: Double = RuntimeConfigFile.defaultLensAnimationSpeed
    ) {
        guard let panel, let host, windowRect.width > 16, windowRect.height > 16 else {
            present(windowRect: windowRect, cornerRadius: cornerRadius, speed: speed, startOverride: animationStart)
            return
        }
        // A LARGE size change can't be resized in place: the glass surface
        // re-samples at the old bounds and leaves a visible seam at the old edge.
        // This happens when the instant-ack anchored to the wrong window — e.g.
        // Edge fullscreen reports a thin top strip as frontmost, so the re-anchor
        // jumps ~8x to the full display. Rebuild the panel fresh for big jumps
        // (clean surface, brief warmup), but still continue the drain via
        // startOverride so it doesn't replay. Small adjustments (the common
        // menu-bar-strip case, ~1.03x) resize in place: smooth and warmup-free.
        let big = windowRect.height > panel.frame.height * 1.5
            || panel.frame.height > windowRect.height * 1.5
            || windowRect.width > panel.frame.width * 1.5
            || panel.frame.width > windowRect.width * 1.5
        if big {
            present(windowRect: windowRect, cornerRadius: cornerRadius, speed: speed, startOverride: animationStart)
            return
        }
        // Resize the existing panel + glass surface in place. No new NSPanel/
        // NSHostingView means no first-composite warmup, so the move is a smooth
        // continuation. The rootView swap keeps the same view identity (so @State
        // start persists); `startOverride` re-seeds the clock as a belt-and-braces
        // in case it doesn't.
        panel.setFrame(windowRect, display: true)
        host.frame = NSRect(origin: .zero, size: windowRect.size)
        host.rootView = GlassCaptureLoadingView(
            size: windowRect.size,
            cornerRadius: cornerRadius,
            speed: speed,
            startOverride: animationStart,
            onStart: { [weak self] start in self?.animationStart = start })
    }

    private func present(
        windowRect: NSRect,
        cornerRadius: CGFloat,
        speed: Double,
        startOverride: Date?
    ) {
        dismiss()
        guard windowRect.width > 16, windowRect.height > 16 else { return }

        let p = NSPanel(contentRect: windowRect,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true   // never block the user's window

        let host = NSHostingView(rootView:
            GlassCaptureLoadingView(
                size: windowRect.size,
                cornerRadius: cornerRadius,
                speed: speed,
                startOverride: startOverride,
                onStart: { [weak self] start in self?.animationStart = start }))
        host.frame = NSRect(origin: .zero, size: windowRect.size)
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        p.orderFrontRegardless()
        panel = p
        self.host = host

        // Backstop: never let the panel linger if a dismiss hook is missed.
        let work = DispatchWorkItem { [weak self] in
            self?.dismiss()
            self?.onBackstop?()
        }
        backstop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: work)
    }

    func dismiss() {
        backstop?.cancel(); backstop = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        host = nil
        // `animationStart` is deliberately NOT cleared here: `present()` calls
        // dismiss() mid-reanchor, and the next `show()` resets it for a fresh
        // drain anyway, so there is no stale-read path.
    }

    /// Warm the SwiftUI runtime + Liquid Glass view graph at launch so the first
    /// real `show()` on the hot path doesn't pay first-render bootstrap — which
    /// otherwise lands as a late / stuttered lens on the first capture after
    /// launch. Renders the lens once into an offscreen bitmap; the hosting view
    /// is never attached to a window, so nothing is ever visible. Cheap; call
    /// once at launch, off the hot path.
    func prewarm(speed: Double = RuntimeConfigFile.defaultLensAnimationSpeed) {
        let size = CGSize(width: 480, height: 320)
        let host = NSHostingView(rootView: GlassCaptureLoadingView(size: size, speed: speed))
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
    }
}
