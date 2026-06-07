#if DEBUG
import SwiftUI

@available(macOS 26.0, *)
struct LGProto01: View {
    @Namespace private var ns
    @State private var open = false

    var body: some View {
        LGDesktop {
            ZStack {
                LGBusyBackdrop()
                GlassEffectContainer(spacing: 28) {
                    if open {
                        LGPuckContent()
                            .glassEffect(.regular, in: .capsule)
                            .glassEffectID("e", in: ns)
                    } else {
                        Color.clear
                            .frame(width: 46, height: 46)
                            .glassEffect(.regular, in: .circle)
                            .glassEffectID("e", in: ns)
                    }
                }
                .frame(
                    width: lgWinSize.width - 32,
                    height: lgWinSize.height - 32,
                    alignment: .bottomTrailing
                )
            }
            .frame(width: lgWinSize.width, height: lgWinSize.height)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                withAnimation(.bouncy(duration: 0.7)) { open = true }
            }
            Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
                withAnimation(.bouncy(duration: 0.7)) { open.toggle() }
            }
        }
    }
}

#Preview("01 · morph circle→puck") {
    if #available(macOS 26.0, *) { LGProto01() }
}
#endif
