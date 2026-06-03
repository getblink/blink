#if DEBUG
import SwiftUI

// The three "lens fades in place + pill buds out" takes, side by side, so you can
// compare the blob character: metaball bud (A) vs condense (B) vs droplet pinch (C).
// Open this file and hit ⌥⌘↩.

@available(macOS 26.0, *)
struct LGLensGallery: View {
    private struct Item: Identifiable { let id = UUID(); let title: String; let view: AnyView }
    private var items: [Item] {
        [
            Item(title: "A · metaball bud (11)", view: AnyView(LGProto11())),
            Item(title: "B · condense (12)", view: AnyView(LGProto12())),
            Item(title: "C · droplet pinch (13)", view: AnyView(LGProto13())),
        ]
    }
    private let cellW: CGFloat = 592, cellH: CGFloat = 432
    private let scale: CGFloat = 0.62

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ForEach(items) { item in
                    VStack(spacing: 6) {
                        item.view
                            .frame(width: cellW, height: cellH)
                            .scaleEffect(scale)
                            .frame(width: cellW * scale, height: cellH * scale)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text(item.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
        }
        .frame(width: cellW * scale + 56, height: 980)
        .background(Color(white: 0.07))
    }
}

#Preview("★ Lens A/B/C") {
    if #available(macOS 26.0, *) { LGLensGallery() }
}
#endif
