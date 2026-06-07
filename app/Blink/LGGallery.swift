#if DEBUG
import SwiftUI

// All ten Liquid Glass capture-gesture prototypes in one scrolling grid, so you
// can compare them at a glance in a single preview canvas. Each tile is a live,
// self-looping LGProtoNN scaled down. Open this file and hit ⌥⌘↩.
// (10 simultaneous glass animations is heavy — if the canvas chugs, open an
// individual LGProtoNN file to view one at full size/perf.)

@available(macOS 26.0, *)
struct LGGallery: View {
    private struct Item: Identifiable { let id = UUID(); let title: String; let view: AnyView }
    private var items: [Item] {
        [
            Item(title: "01 · morph circle→puck", view: AnyView(LGProto01())),
            Item(title: "02 · morph + blue tint", view: AnyView(LGProto02())),
            Item(title: "03 · full-window lens", view: AnyView(LGProto03())),
            Item(title: "04 · puck materialize", view: AnyView(LGProto04())),
            Item(title: "05 · two blobs merge", view: AnyView(LGProto05())),
            Item(title: "06 · edge rail → puck", view: AnyView(LGProto06())),
            Item(title: "07 · zoom big→small", view: AnyView(LGProto07())),
            Item(title: "08 · tint flush glint", view: AnyView(LGProto08())),
            Item(title: "09 · warm pop → puck", view: AnyView(LGProto09())),
            Item(title: "10 · clear corner panel", view: AnyView(LGProto10())),
        ]
    }

    // Each LGProtoNN renders at lgWinSize (480×320) + LGDesktop's 56pt padding
    // → 592×432. Scale the tile down and pin the layout box to the scaled size.
    private let cellW: CGFloat = 592, cellH: CGFloat = 432
    private let scale: CGFloat = 0.5

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16),
                                GridItem(.flexible(), spacing: 16)], spacing: 20) {
                ForEach(items) { item in
                    VStack(spacing: 6) {
                        item.view
                            .frame(width: cellW, height: cellH)
                            .scaleEffect(scale)
                            .frame(width: cellW * scale, height: cellH * scale)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text(item.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 720, height: 920)
        .background(Color(white: 0.07))
    }
}

#Preview("★ All 10 (gallery)") {
    if #available(macOS 26.0, *) { LGGallery() }
}
#endif
