import AppKit
import NeoAnkiCore
import SwiftUI

private final class TextViewHolder {
    weak var textView: NSTextView?
    var lastSelectedRange = NSRange(location: NSNotFound, length: 0)
}

struct RichTextFieldEditor: View {
    let label: String
    @Binding var spans: [Span]
    var accessibilityIdentifier: String?

    @State private var textViewHolder = TextViewHolder()

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.rowTight) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            formattingToolbar

            RichTextEditorRepresentable(
                spans: $spans,
                accessibilityIdentifier: accessibilityIdentifier,
                textViewHolder: textViewHolder
            )
            .frame(minHeight: 72)
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            }

            if ProcessInfo.processInfo.environment["NEOANKI_TESTING"] == "1",
               let accessibilityIdentifier {
                Text(SpanFormatting.testingDescription(from: spans))
                    .accessibilityIdentifier("\(accessibilityIdentifier)-spans")
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
            }
        }
    }

    private var formattingToolbar: some View {
        HStack(spacing: 2) {
            FormatButton(title: "Bold", systemImage: "bold", accessibilityIdentifier: formatButtonID("formatBold")) {
                RichTextEditing.toggleStyle(.bold, in: textViewHolder.textView, preferredRange: textViewHolder.lastSelectedRange)
            }
            FormatButton(title: "Italic", systemImage: "italic", accessibilityIdentifier: formatButtonID("formatItalic")) {
                RichTextEditing.toggleStyle(.italic, in: textViewHolder.textView, preferredRange: textViewHolder.lastSelectedRange)
            }
            FormatButton(title: "Underline", systemImage: "underline", accessibilityIdentifier: formatButtonID("formatUnderline")) {
                RichTextEditing.toggleStyle(.underline, in: textViewHolder.textView, preferredRange: textViewHolder.lastSelectedRange)
            }
            FormatButton(title: "Strikethrough", systemImage: "strikethrough", accessibilityIdentifier: formatButtonID("formatStrikethrough")) {
                RichTextEditing.toggleStyle(.strikethrough, in: textViewHolder.textView, preferredRange: textViewHolder.lastSelectedRange)
            }
            FormatButton(title: "Highlight", systemImage: "highlighter", accessibilityIdentifier: formatButtonID("formatHighlight")) {
                RichTextEditing.toggleStyle(.highlight, in: textViewHolder.textView, preferredRange: textViewHolder.lastSelectedRange)
            }
            FormatButton(title: "Code", systemImage: "chevron.left.forwardslash.chevron.right", accessibilityIdentifier: formatButtonID("formatCode")) {
                RichTextEditing.toggleStyle(.code, in: textViewHolder.textView, preferredRange: textViewHolder.lastSelectedRange)
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private func formatButtonID(_ suffix: String) -> String? {
        guard let accessibilityIdentifier else { return nil }
        return "\(accessibilityIdentifier)-\(suffix)"
    }
}

private struct FormatButton: View {
    let title: String
    let systemImage: String
    var accessibilityIdentifier: String?
    let action: () -> Void

    var body: some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .help(title)
            .accessibilityIdentifier(accessibilityIdentifier ?? title)
    }
}

private struct RichTextEditorRepresentable: NSViewRepresentable {
    @Binding var spans: [Span]
    var accessibilityIdentifier: String?
    var textViewHolder: TextViewHolder

    func makeCoordinator() -> Coordinator {
        Coordinator(spans: $spans, textViewHolder: textViewHolder)
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
        textViewHolder.textView = textView

        context.coordinator.setAttributedString(
            SpanFormatting.attributedString(from: spans),
            preservingSelection: false
        )

        return scrollView
    }

    @MainActor
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.textView = textView
        textViewHolder.textView = textView

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
        var isProgrammaticUpdate = false
        let textViewHolder: TextViewHolder

        init(spans: Binding<[Span]>, textViewHolder: TextViewHolder) {
            _spans = spans
            self.textViewHolder = textViewHolder
        }

        func textDidChange(_ notification: Notification) {
            guard let textView, !isProgrammaticUpdate else { return }
            Task { @MainActor in
                publishSpans(from: textView)
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            let range = textView.selectedRange()
            if range.length > 0 {
                textViewHolder.lastSelectedRange = range
            }
        }

        @MainActor
        func setAttributedString(_ attributedString: NSAttributedString, preservingSelection: Bool) {
            guard let textView else { return }
            isProgrammaticUpdate = true
            defer { isProgrammaticUpdate = false }

            let selectedRange = preservingSelection ? textView.selectedRange() : NSRange(location: 0, length: 0)
            textView.textStorage?.setAttributedString(attributedString)
            let length = textView.textStorage?.length ?? 0
            let clampedLocation = min(selectedRange.location, length)
            let clampedLength = min(selectedRange.length, length - clampedLocation)
            textView.setSelectedRange(NSRange(location: clampedLocation, length: clampedLength))
            syncTestingAccessibilityValue(on: textView)
        }

        @MainActor
        private func publishSpans(from textView: NSTextView) {
            let newSpans = SpanFormatting.spans(from: textView.attributedString())
            if SpanFormatting.plainText(from: newSpans).isEmpty {
                textView.typingAttributes = [
                    .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                ]
            }
            guard newSpans != spans else {
                syncTestingAccessibilityValue(on: textView)
                return
            }

            isUpdatingFromView = true
            defer { isUpdatingFromView = false }
            spans = newSpans
            syncTestingAccessibilityValue(on: textView)
        }

        @MainActor
        private func syncTestingAccessibilityValue(on textView: NSTextView) {
            guard ProcessInfo.processInfo.environment["NEOANKI_TESTING"] == "1" else { return }
            let description = SpanFormatting.testingDescription(
                from: SpanFormatting.spans(from: textView.attributedString())
            )
            if textView.accessibilityLabel() as? String != description {
                textView.setAccessibilityLabel(description)
                textView.setAccessibilityValue(description)
            }
        }
    }
}

enum RichTextEditing {
    @MainActor
    static func toggleStyle(
        _ style: Span.Style,
        in textView: NSTextView?,
        preferredRange: NSRange = NSRange(location: NSNotFound, length: 0)
    ) {
        guard let textView, let textStorage = textView.textStorage else { return }

        var range = textView.selectedRange()
        if range.length == 0 {
            if preferredRange.length > 0, preferredRange.location != NSNotFound {
                textView.setSelectedRange(preferredRange)
                range = preferredRange
            } else if textStorage.length > 0, range.location == 0 {
                let allText = NSRange(location: 0, length: textStorage.length)
                textView.setSelectedRange(allText)
                range = allText
            }
        }
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
