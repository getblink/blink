#if DEBUG
import SwiftUI

// Design prototypes for the *subtle* capture-confirmation → loading-puck flow.
// NOT shipped UI (the real thing is AppKit: CaptureConfirmationOverlay in
// ScreenCapture.swift + the puck in SuggestionsOverlay.swift). Open this file
// and use the canvas (⌥⌘↩) to play them.
//
// Direction: the puck is the main event — a calm frosted pill with the Blink
// mascot that *blinks* as the loading animation (on-brand: the app is "Blink").
// It arrives quietly at the window corner. A subtle window indicator confirms
// which surface was captured. Three indicator options to compare:
//   1. corner glint   — soft glow blooms at the dock corner (recommended)
//   2. puck ripple     — soft rings emanate from the puck
//   3. edge breath     — gentle single outline of the whole window

// MARK: - easing helpers (file-private)

private func pClamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { min(hi, max(lo, x)) }
private func pLerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(pClamp(t)) }
private func pEaseOut(_ t: Double) -> Double { 1 - pow(1 - pClamp(t), 3) }
private func pSeg(_ p: Double, _ a: Double, _ b: Double) -> Double { pClamp((p - a) / (b - a)) }
private func pSpring(_ t: Double) -> Double { let t = pClamp(t); return 1 - exp(-5.0 * t) * cos(4.6 * t) }
private func pBump(_ t: Double) -> Double { sin(.pi * pClamp(t)) }   // 0 → 1 → 0

private let brandCharcoal = Color(red: 0.21, green: 0.21, blue: 0.26)
private let brandCream = Color(red: 0.96, green: 0.94, blue: 0.89)
private let brandSky = Color(red: 0.29, green: 0.71, blue: 0.95)
private let protoWIN = CGSize(width: 460, height: 300)
private let protoInset: CGFloat = 14

// MARK: - the Blink mascot (vector, so the eyes can blink)

private struct ProtoSmile: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(); p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.midX, y: r.maxY + r.height)); return p
    }
}

/// blink: 0 = eyes open, 1 = eyes closed.
struct ProtoBlinkMascot: View {
    var blink: Double = 0
    var size: CGFloat = 24
    var body: some View {
        let eyeH = pLerp(size * 0.17, size * 0.045, blink)
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous).fill(brandCream)
            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous).strokeBorder(brandCharcoal, lineWidth: size * 0.095)
            HStack(spacing: size * 0.22) {
                Capsule().fill(brandCharcoal).frame(width: size * 0.10, height: eyeH)
                Capsule().fill(brandCharcoal).frame(width: size * 0.10, height: eyeH)
            }
            .offset(y: -size * 0.05)
            ProtoSmile().stroke(brandCharcoal, style: StrokeStyle(lineWidth: size * 0.085, lineCap: .round))
                .frame(width: size * 0.36, height: size * 0.12).offset(y: size * 0.17)
        }
        .frame(width: size, height: size)
    }
}

private struct ProtoMascotPuck: View {
    var blink: Double = 0
    var body: some View {
        HStack(spacing: 9) {
            ProtoBlinkMascot(blink: blink, size: 24)
            Text("Reading…").font(.system(size: 13.5, weight: .medium)).foregroundStyle(brandCharcoal.opacity(0.85))
        }
        .padding(.leading, 12).padding(.trailing, 15).padding(.vertical, 8)
        .background(Capsule().fill(.white.opacity(0.74)))
        .overlay(Capsule().stroke(.white.opacity(0.85), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 10, y: 3)
    }
}

// MARK: - mock captured window (light content — the hard case)

private struct ProtoMockWindow: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 11, height: 11)
                Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: 11, height: 11)
                Circle().fill(Color(red: 0.21, green: 0.79, blue: 0.35)).frame(width: 11, height: 11)
                Spacer()
            }.padding(.horizontal, 14).padding(.vertical, 11).background(Color(white: 0.95))
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                ForEach(0..<5) { i in
                    HStack(alignment: .top, spacing: 10) {
                        Circle().fill(Color(white: 0.82)).frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 5) {
                            Capsule().fill(Color(white: 0.86)).frame(width: CGFloat(70 + (i*37)%140), height: 8)
                            Capsule().fill(Color(white: 0.91)).frame(width: CGFloat(180 + (i*53)%150), height: 8)
                        }
                        Spacer()
                    }
                }
            }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Color.white)
        }.frame(width: protoWIN.width, height: protoWIN.height).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// the quiet corner arrival, shared by all indicators
private func arrivingPuck(_ progress: Double, blink: Double) -> some View {
    let inAmt = pSeg(progress, 0.22, 0.64)
    return ProtoMascotPuck(blink: blink)
        .scaleEffect(0.86 + 0.14 * pSpring(inAmt), anchor: .bottomTrailing)
        .opacity(pEaseOut(inAmt))
        .frame(width: protoWIN.width - protoInset*2, height: protoWIN.height - protoInset*2, alignment: .bottomTrailing)
}

// MARK: - corner specular streak (light-first: a sharp highlight slides across
// the glossy window corner, à la Liquid Glass + holographic foil)

private let brandGlint = Color(red: 0.46, green: 0.80, blue: 1.0)

/// Liquid-glass edge highlight: a bright specular rim tracing the window border,
/// brightest at the bottom-right corner and fading toward the top-left. The
/// bevel pair (a cool refraction line + a bright specular line) is what makes
/// the rim read even on white content. `g` = intensity.
private struct ProtoEdgeGlint: View {
    var g: Double
    var body: some View {
        let R = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let diag = sqrt(protoWIN.width*protoWIN.width + protoWIN.height*protoWIN.height)
        let darkEdge = Color(red: 0.12, green: 0.28, blue: 0.42)
        ZStack {
            // 1. cool refraction line at the very edge — gives the bevel contrast
            R.strokeBorder(
                RadialGradient(colors: [darkEdge.opacity(0.55*g), darkEdge.opacity(0.10*g), .clear],
                               center: .bottomTrailing, startRadius: 0, endRadius: diag*0.5),
                lineWidth: 1.4)
            // 2. bright specular line just inside it — the catch of light, hot at BR
            R.inset(by: 1.4).strokeBorder(
                RadialGradient(colors: [.white.opacity(1.0*g), brandGlint.opacity(0.85*g), .clear],
                               center: .bottomTrailing, startRadius: 0, endRadius: diag*0.52),
                lineWidth: 1.8)
            // 3. faint inner thickness glow
            R.inset(by: 3.4).strokeBorder(
                RadialGradient(colors: [brandGlint.opacity(0.30*g), .clear],
                               center: .bottomTrailing, startRadius: 0, endRadius: diag*0.24),
                lineWidth: 1)
        }
        .frame(width: protoWIN.width, height: protoWIN.height)
        .clipShape(R)
        // soft outer glow onto the desktop (light bleeding past the edge)
        .background(R.fill(.clear).shadow(color: brandGlint.opacity(0.4*g), radius: 12))
    }
}

struct ProtoEdgeGlintStage: View {
    var progress: Double
    var blink: Double = 0
    var body: some View {
        // a glint pulse on capture, settling to a faint persistent rim while reading
        let glint = pBump(pSeg(progress, 0.0, 0.5))
        let steady = 0.16 * pEaseOut(pSeg(progress, 0.30, 0.70))
        let g = max(glint, steady)
        let pIn = pSeg(progress, 0.30, 0.78)
        ZStack {
            ProtoMockWindow()
            ProtoEdgeGlint(g: g)
            ProtoMascotPuck(blink: blink)
                .scaleEffect(0.9 + 0.1 * pSpring(pIn), anchor: .bottomTrailing)
                .opacity(pEaseOut(pIn))
                .offset(x: (1 - pEaseOut(pIn)) * 12, y: (1 - pEaseOut(pIn)) * 12)
                .frame(width: protoWIN.width - 28, height: protoWIN.height - 28, alignment: .bottomTrailing)
        }
        .frame(width: protoWIN.width, height: protoWIN.height)
    }
}

// MARK: - edge breath (alone)

struct ProtoBreathStage: View {
    var progress: Double; var blink: Double = 0
    var body: some View {
        let b = pBump(pSeg(progress, 0.0, 0.55))
        ZStack {
            ProtoMockWindow()
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(brandSky.opacity(0.55 * b), lineWidth: 2)
                .shadow(color: brandSky.opacity(0.5 * b), radius: 10)
                .frame(width: protoWIN.width, height: protoWIN.height)
            arrivingPuck(progress, blink: blink)
        }.frame(width: protoWIN.width, height: protoWIN.height).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - looping driver (gesture progress + an independent periodic blink)

private struct ProtoLoop<Content: View>: View {
    var cycle: Double = 3.6         // gesture (~0.9s) then docked hold (blinks)
    var active: Double = 0.9
    @ViewBuilder var content: (_ progress: Double, _ blink: Double) -> Content
    var body: some View {
        TimelineView(.animation) { ctx in
            let abs = ctx.date.timeIntervalSinceReferenceDate
            let progress = min(1.0, abs.truncatingRemainder(dividingBy: cycle) / active)
            // a quick blink every ~2.2s, independent of the arrival loop
            let bt = abs.truncatingRemainder(dividingBy: 2.2)
            let blink = bt > 2.02 ? pBump((bt - 2.02) / 0.18) : 0
            content(progress, blink)
                .frame(width: protoWIN.width, height: protoWIN.height)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white))
                .shadow(color: .black.opacity(0.25), radius: 14, y: 7)
                .padding(40)
                .background(LinearGradient(colors: [Color(white: 0.30), Color(white: 0.15)], startPoint: .top, endPoint: .bottom))
        }
    }
}

// MARK: - Previews

#Preview("Edge glint — bottom-right (recommended)") {
    ProtoLoop { ProtoEdgeGlintStage(progress: $0, blink: $1) }
}

#Preview("Edge breath (whole window)") {
    ProtoLoop { ProtoBreathStage(progress: $0, blink: $1) }
}

#Preview("Mascot puck (blink close-up)") {
    TimelineView(.animation) { ctx in
        let bt = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8)
        let blink = bt > 1.6 ? pBump((bt - 1.6) / 0.18) : 0
        ProtoMascotPuck(blink: blink)
            .padding(60)
            .background(LinearGradient(colors: [Color(white: 0.32), Color(white: 0.16)], startPoint: .top, endPoint: .bottom))
    }
}
#endif
