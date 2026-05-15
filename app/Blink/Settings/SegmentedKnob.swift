import AppKit
import SwiftUI

/// `NSViewRepresentable` wrapping `NSSegmentedControl` so the Style pane can
/// pin every knob row to the same width.
///
/// Why not SwiftUI's `Picker(.segmented)`: on macOS the segmented picker style
/// sizes intrinsically and ignores `.frame(width:)` / `.frame(maxWidth:)` —
/// each picker's three segments size to the widest *of those three* labels, so
/// rows like "Casual | Balanced | Formal" and "Diplomatic | Balanced | Direct"
/// end up visibly different widths. `NSSegmentedControl` honors SwiftUI frame
/// modifiers, so the caller can apply `.frame(width:)` once and every row
/// renders identically. The escape-hatch pattern matches `AboutMeTextEditor`.
@available(macOS 14.0, *)
struct SegmentedKnob: NSViewRepresentable {
    @Binding var selection: String
    let segments: [Segment]

    struct Segment {
        let title: String
        let value: String
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentStyle = .rounded
        control.trackingMode = .selectOne
        control.segmentDistribution = .fillEqually
        control.segmentCount = segments.count
        for (index, segment) in segments.enumerated() {
            control.setLabel(segment.title, forSegment: index)
        }
        control.target = context.coordinator
        control.action = #selector(Coordinator.segmentChanged(_:))
        context.coordinator.parent = self
        applySelection(to: control)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        if control.segmentCount != segments.count {
            control.segmentCount = segments.count
        }
        for (index, segment) in segments.enumerated() {
            if control.label(forSegment: index) != segment.title {
                control.setLabel(segment.title, forSegment: index)
            }
        }
        applySelection(to: control)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    private func applySelection(to control: NSSegmentedControl) {
        let index = segments.firstIndex { $0.value == selection } ?? 0
        if control.selectedSegment != index {
            control.selectedSegment = index
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: SegmentedKnob

        init(parent: SegmentedKnob) {
            self.parent = parent
        }

        @objc func segmentChanged(_ sender: NSSegmentedControl) {
            let index = sender.selectedSegment
            guard parent.segments.indices.contains(index) else { return }
            let newValue = parent.segments[index].value
            if parent.selection != newValue {
                parent.selection = newValue
            }
        }
    }
}
