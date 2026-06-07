#if DEBUG
import SwiftUI

// The three refined-B branches side by side: all snap the lens in instantly and
// condense the pill; they differ only in how the lens LEAVES (fade / drain / flare).
// Open this file and hit ⌥⌘↩.

@available(macOS 26.0, *)
struct LGBranchGallery: View {
    private struct Item: Identifiable { let id = UUID(); let title: String; let view: AnyView }
    private var items: [Item] {
        [
            Item(title: "B2 · drain (15)", view: AnyView(LGProto15())),
            Item(title: "B3 · flash & fade (16)", view: AnyView(LGProto16())),
            Item(title: "B2+B3 · flare → drain (17)", view: AnyView(LGProto17())),
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

#Preview("★ Finalists (drain / flare / combo)") {
    if #available(macOS 26.0, *) { LGBranchGallery() }
}
#endif
