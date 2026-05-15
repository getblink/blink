import AppKit
import SwiftUI

/// `NSViewRepresentable` wrapping `NSTextView` for the Style ▸ About me box.
///
/// Why not SwiftUI's `TextEditor`: About me feeds the prompt sent to the model.
/// On macOS 14, `TextEditor` exposes no toggle for smart-quote / dash
/// substitution, so curly quotes and en-dashes would silently leak in. The
/// previous AppKit implementation explicitly disabled both; preserve that here.
@available(macOS 14.0, *)
struct AboutMeTextEditor: NSViewRepresentable {
    @Binding var text: String
    let maxChars: Int
    var onCommit: ((String) -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let textView = NSTextView()
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = NSFont.systemFont(ofSize: 12)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.allowsUndo = true
        textView.delegate = context.coordinator
        textView.string = text

        // Let the text view grow with the scroll view.
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            // Preserve selection across external updates so binding-driven
            // resets (e.g. presets) don't drop the caret.
            let selected = textView.selectedRange()
            textView.string = text
            let safeLocation = min(selected.location, text.utf16.count)
            textView.setSelectedRange(NSRange(location: safeLocation, length: 0))
        }
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AboutMeTextEditor

        init(parent: AboutMeTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            var value = view.string
            if value.unicodeScalars.count > parent.maxChars {
                let truncated = value.unicodeScalars.prefix(parent.maxChars)
                value = String(String.UnicodeScalarView(truncated))
                view.string = value
            }
            if parent.text != value {
                parent.text = value
            }
            parent.onCommit?(value)
        }
    }
}
