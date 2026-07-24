import AppKit
import NeoAnkiCore
import SwiftUI

struct RichTextFieldEditor: View {
    let label: String
    @Binding var spans: [Span]
    var accessibilityIdentifier: String?

    @State private var textView: NSTextView?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.rowTight) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            formattingToolbar

            RichTextEditorRepresentable(
                spans: $spans,
                accessibilityIdentifier: accessibilityIdentifier
            ) { view in
                textView = view
            }
            .frame(minHeight: 72)
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            }
        }
    }

    private var formattingToolbar: some View {
        HStack(spacing: 2) {
            FormatButton(title: "Bold", systemImage: "bold") {
                RichTextEditing.toggleStyle(.bold, in: textView)
            }
            FormatButton(title: "Italic", systemImage: "italic") {
                RichTextEditing.toggleStyle(.italic, in: textView)
            }
            FormatButton(title: "Underline", systemImage: "underline") {
                RichTextEditing.toggleStyle(.underline, in: textView)
            }
            FormatButton(title: "Strikethrough", systemImage: "strikethrough") {
                RichTextEditing.toggleStyle(.strikethrough, in: textView)
            }
            FormatButton(title: "Highlight", systemImage: "highlighter") {
                RichTextEditing.toggleStyle(.highlight, in: textView)
            }
            FormatButton(title: "Code", systemImage: "chevron.left.forwardslash.chevron.right") {
                RichTextEditing.toggleStyle(.code, in: textView)
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }
}

private struct FormatButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .help(title)
    }
}

private struct RichTextEditorRepresentable: NSViewRepresentable {
    @Binding var spans: [Span]
    var accessibilityIdentifier: String?
    var onTextViewCreated: (NSTextView) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(spans: $spans)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.isRichText = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.delegate = context.coordinator
        textView.setAccessibilityIdentifier(accessibilityIdentifier)
        context.coordinator.textView = textView
        onTextViewCreated(textView)

        context.coordinator.setAttributedString(
            SpanFormatting.attributedString(from: spans),
            preservingSelection: false
        )

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.textView = textView

        guard !context.coordinator.isUpdatingFromView else { return }

        let currentSpans = SpanFormatting.spans(from: textView.attributedString())
        if currentSpans != spans {
            context.coordinator.setAttributedString(
                SpanFormatting.attributedString(from: spans),
                preservingSelection: true
            )
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var spans: [Span]
        weak var textView: NSTextView?
        var isUpdatingFromView = false

        init(spans: Binding<[Span]>) {
            _spans = spans
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            isUpdatingFromView = true
            spans = SpanFormatting.spans(from: textView.attributedString())
            isUpdatingFromView = false
        }

        @MainActor
        func setAttributedString(_ attributedString: NSAttributedString, preservingSelection: Bool) {
            guard let textView else { return }
            let selectedRange = preservingSelection ? textView.selectedRange() : NSRange(location: 0, length: 0)
            textView.textStorage?.setAttributedString(attributedString)
            let length = textView.textStorage?.length ?? 0
            let clampedLocation = min(selectedRange.location, length)
            let clampedLength = min(selectedRange.length, length - clampedLocation)
            textView.setSelectedRange(NSRange(location: clampedLocation, length: clampedLength))
        }
    }
}

enum RichTextEditing {
    @MainActor
    static func toggleStyle(_ style: Span.Style, in textView: NSTextView?) {
        guard let textView, let textStorage = textView.textStorage else { return }

        let range = textView.selectedRange()
        let targetRange = range.length > 0 ? range : NSRange(location: range.location, length: 0)
        let isActive = styleIsActive(style, in: textStorage, range: targetRange, typingAttributes: textView.typingAttributes)
        let applying = !isActive

        if range.length == 0 {
            var typingAttributes = textView.typingAttributes
            applyStyle(style, active: applying, to: &typingAttributes)
            textView.typingAttributes = typingAttributes
            return
        }

        textStorage.beginEditing()
        textStorage.enumerateAttributes(in: range) { attributes, subrange, _ in
            var updated = attributes
            let currentlyActive = styleIsActive(style, in: textStorage, range: subrange, typingAttributes: attributes)
            applyStyle(style, active: !currentlyActive, to: &updated)
            textStorage.setAttributes(updated, range: subrange)
        }
        textStorage.endEditing()

        textView.didChangeText()
    }

    private static func styleIsActive(
        _ style: Span.Style,
        in textStorage: NSTextStorage,
        range: NSRange,
        typingAttributes: [NSAttributedString.Key: Any]
    ) -> Bool {
        if range.length == 0 {
            return SpanFormatting.spans(from: NSAttributedString(string: "x", attributes: typingAttributes))
                .first?.styles.contains(style) == true
        }

        var found = false
        var allActive = true
        textStorage.enumerateAttributes(in: range) { attributes, _, stop in
            found = true
            let styles = SpanFormatting.spans(from: NSAttributedString(string: "x", attributes: attributes))
                .first?.styles ?? []
            if !styles.contains(style) {
                allActive = false
                stop.pointee = true
            }
        }
        return found && allActive
    }

    private static func applyStyle(
        _ style: Span.Style,
        active: Bool,
        to attributes: inout [NSAttributedString.Key: Any]
    ) {
        var span = Span("x", styles: SpanFormatting.spans(from: NSAttributedString(string: "x", attributes: attributes)).first?.styles ?? [])
        if active {
            span.styles.insert(style)
        } else {
            span.styles.remove(style)
        }

        if style == .code, active {
            span.styles.remove(.highlight)
        }
        if style == .highlight, active {
            span.styles.remove(.code)
        }

        let replacement = SpanFormatting.attributedString(from: [span]).attributes(at: 0, effectiveRange: nil)
        attributes[.font] = replacement[.font]
        attributes[.underlineStyle] = replacement[.underlineStyle]
        attributes[.strikethroughStyle] = replacement[.strikethroughStyle]
        attributes[.backgroundColor] = replacement[.backgroundColor]
    }
}
