#if os(macOS)
import AppKit

/// The supported scrolling-document contract for every Mac authoring editor.
/// Callers create their own text view/text system; a factory's existing text
/// container must never be transplanted into a replacement document view.
@MainActor
public enum NativeTextEditorPolicy {
    public static func makeScrollView(for textView: NSTextView, inset: NSSize) -> NSScrollView {
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = inset

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.documentView = textView
        return scroll
    }
}
#endif
