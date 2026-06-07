#if DEBUG
import SwiftUI

// Shared foundation for the Liquid Glass capture-gesture prototypes (LGProto01…10).
// These use REAL `glassEffect` so they only render correctly in Xcode's preview
// canvas (not headless snapshots). The backdrop is deliberately busy/colorful so
// the glass refraction is visible — over flat white there's nothing to bend.
//
// NOT shipped UI. Everything here is #if DEBUG and lives only for the canvas.

// MARK: - palette + window size

let lgInk = Color(red: 0.090, green: 0.125, blue: 0.200)   // #172033 (eyes / mouth / text)
let lgCream = Color(red: 0.96, green: 0.94, blue: 0.89)
let lgBlue = Color(red: 0.29, green: 0.71, blue: 0.95)
let lgGold = Color(red: 1.0, green: 0.84, blue: 0.52)
let lgWinSize = CGSize(width: 480, height: 320)
let lgCorner: CGFloat = 12

// MARK: - easing helpers

func lgClamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { min(hi, max(lo, x)) }
func lgSeg(_ p: Double, _ a: Double, _ b: Double) -> Double { lgClamp((p - a) / (b - a)) }
func lgEaseOut(_ t: Double) -> Double { 1 - pow(1 - lgClamp(t), 3) }
func lgSpring(_ t: Double) -> Double { let t = lgClamp(t); return 1 - exp(-5 * t) * cos(4.6 * t) }
func lgBump(_ t: Double) -> Double { sin(.pi * lgClamp(t)) }
/// A quick periodic blink value (0 open → 1 closed) derived from a wall-clock time.
func lgBlink(_ t: TimeInterval, period: Double = 2.4, dur: Double = 0.16) -> Double {
    let bt = t.truncatingRemainder(dividingBy: period)
    return bt > period - dur ? lgBump((bt - (period - dur)) / dur) : 0
}
/// Eye expression 0 (normal) → 1 (happy ^_^), on a loop: briefly normal, ease up
/// to happy, hold happy, then relax back — so you see the normal→happy animation.
func lgExpr(_ t: TimeInterval, period: Double = 3.0) -> Double {
    let x = t.truncatingRemainder(dividingBy: period)
    if x < 0.4 { return 0 }
    if x < 0.9 { return lgEaseOut((x - 0.4) / 0.5) }
    if x < period - 0.35 { return 1 }
    return 1 - lgEaseOut((x - (period - 0.35)) / 0.35)
}

// MARK: - busy, colorful mock window (so glass refraction reads)

struct LGBusyBackdrop: View {
    var body: some View {
        VStack(spacing: 0) {
            // title bar
            HStack(spacing: 7) {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 11, height: 11)
                Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: 11, height: 11)
                Circle().fill(Color(red: 0.21, green: 0.79, blue: 0.35)).frame(width: 11, height: 11)
                Spacer()
                Capsule().fill(.white.opacity(0.5)).frame(width: 70, height: 9)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(Color(white: 0.96))
            Divider()
            HStack(spacing: 0) {
                // colorful sidebar
                VStack(spacing: 12) {
                    ForEach(0..<6) { i in
                        RoundedRectangle(cornerRadius: 7)
                            .fill([Color.pink, .orange, .green, .blue, .purple, .teal][i].gradient)
                            .frame(width: 30, height: 30)
                    }
                    Spacer()
                }
                .padding(12)
                .background(Color(white: 0.93))
                // main content: a vivid hero + cards + text
                VStack(alignment: .leading, spacing: 12) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(colors: [.indigo, .pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(height: 88)
                        .overlay(alignment: .bottomLeading) {
                            VStack(alignment: .leading, spacing: 6) {
                                Capsule().fill(.white.opacity(0.9)).frame(width: 130, height: 10)
                                Capsule().fill(.white.opacity(0.6)).frame(width: 90, height: 8)
                            }.padding(14)
                        }
                    HStack(spacing: 12) {
                        ForEach(0..<3) { i in
                            RoundedRectangle(cornerRadius: 10)
                                .fill([Color.mint, .yellow, .cyan][i].gradient)
                                .frame(height: 64).overlay(
                                    Circle().fill(.white.opacity(0.85)).frame(width: 22, height: 22).padding(8),
                                    alignment: .topLeading)
                        }
                    }
                    ForEach(0..<3) { i in
                        HStack(spacing: 10) {
                            Circle().fill([Color.red, .blue, .green][i].opacity(0.8)).frame(width: 22, height: 22)
                            Capsule().fill(Color(white: 0.85)).frame(width: CGFloat(150 + i*40), height: 9)
                            Spacer()
                        }
                    }
                    Spacer()
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.white)
            }
        }
        .frame(width: lgWinSize.width, height: lgWinSize.height)
        .clipShape(RoundedRectangle(cornerRadius: lgCorner, style: .continuous))
    }
}

// MARK: - mascot + puck inner content (NO glass background — each proto adds glass)

struct LGSmile: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(); p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.midX, y: r.maxY + r.height)); return p
    }
}
/// A happy, upward-arched eye (⌒). `openness`: 1 = full arch (^_^), 0 = flat (blink-closed).
struct LGHappyEye: Shape {
    var openness: Double
    func path(in r: CGRect) -> Path {
        var p = Path()
        let arch = r.height * CGFloat(lgClamp(openness))
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.midX, y: r.maxY - 2 * arch))
        return p
    }
}
// Proportions taken from blink-logo-no-surprise.svg (mark ≈ 474×454 in its
// viewBox): dark rounded-square frame (navy gradient), cream inset face, a thick
// smile, and eyes that animate between NORMAL (round dots, the logo's resting
// look) and HAPPY (upward ^_^ arches) via the `happy` value.
struct LGMascotFace: View {
    var happy: Double = 1            // 0 = normal round eyes, 1 = happy ^_^ arches
    var size: CGFloat = 24
    var body: some View {
        let s = size
        let outerH = s * 0.958           // mark is slightly wider than tall
        let border = s * 0.108           // dark frame thickness
        let h = lgClamp(happy)
        ZStack {
            // dark rounded-square frame
            RoundedRectangle(cornerRadius: s * 0.29, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.204, green: 0.231, blue: 0.290),
                             Color(red: 0.169, green: 0.196, blue: 0.251)],
                    startPoint: .top, endPoint: .bottom))
                .frame(width: s, height: outerH)
            // cream face
            RoundedRectangle(cornerRadius: s * 0.215, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 1.0, green: 0.976, blue: 0.941),
                             Color(red: 0.976, green: 0.945, blue: 0.906)],
                    startPoint: .top, endPoint: .bottom))
                .frame(width: s - 2*border, height: outerH - 2*border)
            // eyes — crossfade from normal round dots to happy arches
            HStack(spacing: s * 0.215) { eye(h); eye(h) }
                .offset(y: -s * 0.01)
            // smile
            LGSmile().stroke(lgInk, style: StrokeStyle(lineWidth: s * 0.066, lineCap: .round))
                .frame(width: s * 0.22, height: s * 0.085)
                .offset(y: s * 0.18)
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder private func eye(_ h: Double) -> some View {
        let s = size
        ZStack {
            // normal: round dot (fades + lifts as it becomes the arch).
            // Staggered crossfade (dot out by ~0.55, arch in from ~0.45) so the two
            // shapes barely overlap — avoids a ghosted double-image mid-transition.
            Circle().fill(lgInk)
                .frame(width: s * 0.128, height: s * 0.128)
                .scaleEffect(1 - 0.18 * CGFloat(h))
                .offset(y: s * 0.018 * CGFloat(h))
                .opacity(1 - lgClamp(h * 1.8))
            // happy: upward ^_^ arch
            LGHappyEye(openness: 1)
                .stroke(lgInk, style: StrokeStyle(lineWidth: s * 0.052, lineCap: .round))
                .frame(width: s * 0.16, height: s * 0.085)
                .opacity(lgClamp((h - 0.45) * 1.8))
        }
        .frame(width: s * 0.16, height: s * 0.128)
    }
}
/// Mascot that emotes on its own timeline (normal → happy → hold → relax, looping)
/// — drop into any proto without managing the expression.
struct LGBlinkingMascot: View {
    var size: CGFloat = 24
    var body: some View {
        TimelineView(.animation) { ctx in
            LGMascotFace(happy: lgExpr(ctx.date.timeIntervalSinceReferenceDate), size: size)
        }
    }
}
/// The puck's inner content (blinking mascot + "Reading…"), with padding but NO
/// background. Wrap this in `.glassEffect(...)` inside each prototype.
struct LGPuckContent: View {
    /// nil = self-animating expression loop; a value = caller-driven, e.g. start
    /// normal as the pill appears, then ease to happy and hold.
    var happy: Double? = nil
    var body: some View {
        HStack(spacing: 9) {
            if let happy {
                LGMascotFace(happy: happy, size: 24)
            } else {
                LGBlinkingMascot(size: 24)
            }
            Text("Reading…").font(.system(size: 13.5, weight: .medium)).foregroundStyle(lgInk.opacity(0.9))
        }
        .padding(.leading, 12).padding(.trailing, 15).padding(.vertical, 8)
    }
}

// MARK: - consistent desktop frame for previews

struct LGDesktop<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(width: lgWinSize.width, height: lgWinSize.height)
            .shadow(color: .black.opacity(0.32), radius: 20, y: 12)
            .padding(56)
            .background(LinearGradient(colors: [Color(white: 0.26), Color(white: 0.11)], startPoint: .top, endPoint: .bottom))
    }
}
#endif
