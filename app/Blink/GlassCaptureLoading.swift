import SwiftUI
import AppKit

// Production port of the chosen capture-loading prototype (LGProto15): a clear
// Liquid Glass lens over the captured window that drains immediately toward the
// bottom-right corner, condensing into a glass "Reading…" pill whose Blink
// mascot animates from normal eyes to a happy ^_^. Hosted in a transparent,
// click-through NSPanel laid over the live window, so the glass refracts the
// real screen. Opt-in via BLINK_GLASS_LOADING; the default puck path is unchanged.

// MARK: - easing

private func glClamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { min(hi, max(lo, x)) }
private func glSeg(_ p: Double, _ a: Double, _ b: Double) -> Double { glClamp((p - a) / (b - a)) }
private func glEaseOut(_ t: Double) -> Double { 1 - pow(1 - glClamp(t), 3) }
private func glEaseOutQuart(_ t: Double) -> Double { 1 - pow(1 - glClamp(t), 4) }   // soft settle
private func glSmooth(_ t: Double) -> Double { let t = glClamp(t); return t * t * (3 - 2 * t) }  // ease-in-out: gentle start + soft settle
private func glSpring(_ t: Double) -> Double { let t = glClamp(t); return 1 - exp(-5 * t) * cos(4.6 * t) }

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
    var size: CGFloat = 24
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
                .scaleEffect(1 - 0.18 * CGFloat(h)).offset(y: s * 0.018 * CGFloat(h))
                .opacity(1 - glClamp(h * 1.8))
            GLHappyEye(openness: 1).stroke(glInk, style: StrokeStyle(lineWidth: s * 0.052, lineCap: .round))
                .frame(width: s * 0.16, height: s * 0.085).opacity(glClamp((h - 0.45) * 1.8))
        }
        .frame(width: s * 0.16, height: s * 0.128)
    }
}

private struct GLPill: View {
    var happy: Double
    var body: some View {
        // No fixed text color: the default foreground is the adaptive label color,
        // and on glass the system renders it with vibrancy so it stays legible
        // over light or dark windows. (The mascot keeps its own drawn colors since
        // it carries its own light face.)
        let content = HStack(spacing: 9) {
            BlinkLoadingMascot(happy: happy, size: 24)
            Text("Reading…").font(.system(size: 13.5, weight: .medium))
        }
        .padding(.leading, 12).padding(.trailing, 15).padding(.vertical, 8)
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
    private let lensStrength: Double = 0.62
    private let drainDur: Double = 0.6
    /// Intro pace. 1.0 = original timing; higher = snappier. The elapsed clock
    /// is multiplied by this, so every phase below (lens drain, pill grow, eye
    /// smile) tightens together — one number tunes the whole sequence rather
    /// than re-balancing each segment. At 2.0 the ~0.6s drain runs in ~0.3s and
    /// the full intro lands in ~0.6s. Injected from `RuntimeConfigStore`
    /// (Settings → Advanced); the default here is the fallback for previews and
    /// the launch prewarm.
    var speed: Double = 2.0
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
            let t = (start.map { ctx.date.timeIntervalSince($0) } ?? 0) * max(0.25, speed)
            let appear = glEaseOut(glSeg(t, 0.0, 0.05))
            let drain = glSmooth(glSeg(t, 0.0, drainDur))                  // ease-in: gentle start so a warmup hitch isn't mid-sweep
            let grow = glSpring(glSeg(t, 0.18, 0.70))
            let pillScale = 0.18 + 0.82 * grow
            let pillOpacity = glEaseOut(glSeg(t, 0.18, 0.55))
            let happy = glEaseOut(glSeg(t, 0.70, 1.15))                    // eyes normal → happy, then hold

            ZStack {
                lens(drain: drain).opacity(appear * lensStrength)
                ZStack(alignment: .bottomTrailing) {
                    Color.clear
                    GLPill(happy: happy).scaleEffect(pillScale).opacity(pillOpacity)
                }
                .frame(width: size.width - 32, height: size.height - 32, alignment: .bottomTrailing)
            }
            .frame(width: size.width, height: size.height)
            .onAppear { if start == nil { start = ctx.date } }
        }
    }

    @ViewBuilder private func lens(drain: Double) -> some View {
        let mask = LinearGradient(
            stops: [.init(color: .clear, location: min(drain, 0.999)),
                    .init(color: .black, location: min(drain + 0.16, 1.0))],
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
    /// Invoked (on the main thread) only when the 90s backstop fires — i.e. the
    /// panel was torn down without the normal coordinator dismiss path. Lets the
    /// coordinator clear any state it armed for the loading session (e.g. the
    /// overlay-active key-tap mirror) so a hung request can't leave it stuck.
    var onBackstop: (() -> Void)?

    /// Present the glass loading over `windowRect` (AppKit screen coords). Safe to
    /// call repeatedly; replaces any existing presentation.
    func show(windowRect: NSRect, cornerRadius: CGFloat = 12, speed: Double = 2.0) {
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
            GlassCaptureLoadingView(size: windowRect.size, cornerRadius: cornerRadius, speed: speed))
        host.frame = NSRect(origin: .zero, size: windowRect.size)
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        p.orderFrontRegardless()
        panel = p

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
    }

    /// Warm the SwiftUI runtime + Liquid Glass view graph at launch so the first
    /// real `show()` on the hot path doesn't pay first-render bootstrap — which
    /// otherwise lands as a late / stuttered lens on the first capture after
    /// launch. Renders the lens once into an offscreen bitmap; the hosting view
    /// is never attached to a window, so nothing is ever visible. Cheap; call
    /// once at launch, off the hot path.
    func prewarm() {
        let size = CGSize(width: 480, height: 320)
        let host = NSHostingView(rootView: GlassCaptureLoadingView(size: size))
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
    }
}
