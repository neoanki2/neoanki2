import AppKit
import NeoAnkiCore
import Testing

@testable import NeoAnki2

@MainActor
private func makeTextView(text: String, selection: NSRange) -> NSTextView {
    let scrollView = NSTextView.scrollableTextView()
    let textView = try! #require(scrollView.documentView as? NSTextView)
    textView.textStorage?.setAttributedString(SpanFormatting.attributedString(from: [Span(text)]))
    textView.setSelectedRange(selection)
    return textView
}

@MainActor
private func spans(in textView: NSTextView) -> [Span] {
    SpanFormatting.spans(from: textView.attributedString())
}

private final class UndoableTextView: NSTextView {
    private let formattingUndoManager = UndoManager()

    override var undoManager: UndoManager? {
        formattingUndoManager
    }
}

@MainActor
private func makeUndoableTextView(text: String, selection: NSRange) -> NSTextView {
    let textView = UndoableTextView(frame: .zero)
    textView.allowsUndo = true
    textView.textStorage?.setAttributedString(
        SpanFormatting.attributedString(from: [Span(text)])
    )
    textView.setSelectedRange(selection)
    return textView
}

@Test @MainActor func toggleBoldAppliesToSelectedText() {
    let textView = makeTextView(text: "Hello", selection: NSRange(location: 0, length: 5))

    RichTextEditing.toggleStyle(.bold, in: textView)

    #expect(spans(in: textView) == [Span("Hello", styles: [.bold])])
}

@Test func richTextTabCommandsNavigateFormFocus() {
    #expect(
        RichTextFocusNavigation.direction(for: #selector(NSResponder.insertTab(_:)))
            == .forward
    )
    #expect(
        RichTextFocusNavigation.direction(for: #selector(NSResponder.insertBacktab(_:)))
            == .backward
    )
    #expect(
        RichTextFocusNavigation.direction(for: #selector(NSResponder.insertNewline(_:)))
            == nil
    )
}

@Test func clozeTabCommandsNavigateFormFocus() {
    #expect(
        ClozeFocusNavigation.direction(for: #selector(NSResponder.insertTab(_:)))
            == .forward
    )
    #expect(
        ClozeFocusNavigation.direction(for: #selector(NSResponder.insertBacktab(_:)))
            == .backward
    )
    #expect(
        ClozeFocusNavigation.direction(for: #selector(NSResponder.insertNewline(_:)))
            == nil
    )
}

@Test @MainActor func toggleBoldRemovesFromSelectedText() {
    let textView = makeTextView(text: "Hello", selection: NSRange(location: 0, length: 5))
    textView.textStorage?.setAttributedString(
        SpanFormatting.attributedString(from: [Span("Hello", styles: [.bold])])
    )
    textView.setSelectedRange(NSRange(location: 0, length: 5))

    RichTextEditing.toggleStyle(.bold, in: textView)

    #expect(spans(in: textView) == [Span("Hello")])
}

@Test @MainActor func toggleItalicAppliesToPartialSelection() {
    let textView = makeTextView(text: "Hello world", selection: NSRange(location: 6, length: 5))

    RichTextEditing.toggleStyle(.italic, in: textView)

    #expect(spans(in: textView) == [
        Span("Hello "),
        Span("world", styles: [.italic]),
    ])
}

@Test @MainActor func toggleUnderlineAppliesToSelection() {
    let textView = makeTextView(text: "Note", selection: NSRange(location: 0, length: 4))

    RichTextEditing.toggleStyle(.underline, in: textView)

    #expect(spans(in: textView) == [Span("Note", styles: [.underline])])
}

@Test @MainActor func toggleStrikethroughAppliesToSelection() {
    let textView = makeTextView(text: "Done", selection: NSRange(location: 0, length: 4))

    RichTextEditing.toggleStyle(.strikethrough, in: textView)

    #expect(spans(in: textView) == [Span("Done", styles: [.strikethrough])])
}

@Test @MainActor func toggleHighlightAppliesToSelection() {
    let textView = makeTextView(text: "Key", selection: NSRange(location: 0, length: 3))

    RichTextEditing.toggleStyle(.highlight, in: textView)

    #expect(spans(in: textView) == [Span("Key", styles: [.highlight])])
}

@Test @MainActor func toggleCodeAppliesToSelection() {
    let textView = makeTextView(text: "fn()", selection: NSRange(location: 0, length: 4))

    RichTextEditing.toggleStyle(.code, in: textView)

    #expect(spans(in: textView) == [Span("fn()", styles: [.code])])
}

@Test @MainActor func toggleCodeRemovesHighlightFromSelection() {
    let textView = makeTextView(
        text: "term",
        selection: NSRange(location: 0, length: 4)
    )
    textView.textStorage?.setAttributedString(
        SpanFormatting.attributedString(from: [Span("term", styles: [.highlight])])
    )
    textView.setSelectedRange(NSRange(location: 0, length: 4))

    RichTextEditing.toggleStyle(.code, in: textView)

    #expect(spans(in: textView) == [Span("term", styles: [.code])])
}

@Test @MainActor func superscriptAndSubscriptAreMutuallyExclusive() {
    let textView = makeTextView(text: "2", selection: NSRange(location: 0, length: 1))

    RichTextEditing.toggleStyle(.superscript, in: textView)
    RichTextEditing.toggleStyle(.subscriptText, in: textView)

    #expect(spans(in: textView) == [Span("2", styles: [.subscriptText])])
}

@Test @MainActor func nativeInlineFormattingAppliesToSelection() {
    let textView = makeTextView(text: "NeoAnki", selection: NSRange(location: 0, length: 7))

    RichTextEditing.setTextColor(.indigo, in: textView)
    RichTextEditing.setTextSize(.large, in: textView)
    RichTextEditing.setLink("https://neoanki.app", in: textView)

    #expect(spans(in: textView) == [
        Span(
            "NeoAnki",
            textColor: .indigo,
            textSize: .large,
            link: "https://neoanki.app"
        ),
    ])
}

@Test @MainActor func clearFormattingRemovesAllNativeInlineFormatting() {
    let textView = makeTextView(text: "Term", selection: NSRange(location: 0, length: 4))
    textView.textStorage?.setAttributedString(
        SpanFormatting.attributedString(from: [
            Span(
                "Term",
                styles: [.bold, .superscript],
                textColor: .red,
                textSize: .small,
                link: "mailto:study@example.com"
            ),
        ])
    )
    textView.setSelectedRange(NSRange(location: 0, length: 4))

    RichTextEditing.clearFormatting(in: textView)

    #expect(spans(in: textView) == [Span("Term")])
}

@Test @MainActor func invalidLinkIsIgnored() {
    let textView = makeTextView(text: "Unsafe", selection: NSRange(location: 0, length: 6))

    RichTextEditing.setLink("javascript:alert(1)", in: textView)

    #expect(spans(in: textView) == [Span("Unsafe")])
}

@Test @MainActor func toggleBoldSetsTypingAttributesWhenNothingSelected() {
    let textView = makeTextView(text: "Hello", selection: NSRange(location: 5, length: 0))

    RichTextEditing.toggleStyle(.bold, in: textView)

    let typingStyles = SpanFormatting.spans(
        from: NSAttributedString(string: "x", attributes: textView.typingAttributes)
    ).first?.styles
    #expect(typingStyles == [.bold])
}

@Test @MainActor func formattingAtStartUpdatesTypingAttributesWithoutSelectingAllText() {
    let textView = makeTextView(text: "Hello", selection: NSRange(location: 0, length: 0))

    RichTextEditing.toggleStyle(.bold, in: textView)

    #expect(spans(in: textView) == [Span("Hello")])
    #expect(textView.selectedRange() == NSRange(location: 0, length: 0))
    let typingStyles = SpanFormatting.spans(
        from: NSAttributedString(string: "x", attributes: textView.typingAttributes)
    ).first?.styles
    #expect(typingStyles == [.bold])
}

@Test @MainActor func selectionStateDistinguishesUniformAndMixedFormatting() {
    let textView = makeTextView(text: "AB", selection: NSRange(location: 0, length: 2))
    textView.textStorage?.setAttributedString(
        SpanFormatting.attributedString(from: [
            Span("A", styles: [.bold], textColor: .blue),
            Span("B", textColor: .blue),
        ])
    )
    textView.setSelectedRange(NSRange(location: 0, length: 2))

    let mixed = RichTextEditing.selectionState(in: textView)
    #expect(mixed.activeStyles.isEmpty)
    #expect(mixed.mixedStyles == [.bold])
    #expect(mixed.textColor == .blue)
    #expect(!mixed.textColorIsMixed)

    textView.setSelectedRange(NSRange(location: 0, length: 1))
    let uniform = RichTextEditing.selectionState(in: textView)
    #expect(uniform.activeStyles == [.bold])
    #expect(uniform.mixedStyles.isEmpty)
}

@Test @MainActor func outOfBoundsPreferredSelectionIsIgnored() {
    let textView = makeTextView(text: "Hello", selection: NSRange(location: 5, length: 0))

    RichTextEditing.setTextColor(
        .blue,
        in: textView,
        preferredRange: NSRange(location: 20, length: 4)
    )

    #expect(spans(in: textView) == [Span("Hello")])
    #expect(textView.selectedRange() == NSRange(location: 5, length: 0))
}

@Test @MainActor func formattingChangesParticipateInUndoAndRedo() {
    let textView = makeUndoableTextView(
        text: "Hello",
        selection: NSRange(location: 0, length: 5)
    )

    RichTextEditing.toggleStyle(.bold, in: textView)
    #expect(spans(in: textView) == [Span("Hello", styles: [.bold])])

    textView.undoManager?.undo()
    #expect(spans(in: textView) == [Span("Hello")])

    textView.undoManager?.redo()
    #expect(spans(in: textView) == [Span("Hello", styles: [.bold])])
}

@Test func pastedContentIsCanonicalizedToSupportedFormatting() {
    let input = NSMutableAttributedString(
        attributedString: SpanFormatting.attributedString(from: [
            Span(
                "Paste",
                styles: [.bold],
                textColor: .blue,
                link: "https://neoanki.app"
            ),
        ])
    )
    input.addAttributes(
        [
            .kern: 12,
            .expansion: 0.5,
            .obliqueness: 0.25,
        ],
        range: NSRange(location: 0, length: input.length)
    )

    let sanitized = RichTextEditing.sanitizedAttributedString(input)

    #expect(SpanFormatting.spans(from: sanitized) == [
        Span(
            "Paste",
            styles: [.bold],
            textColor: .blue,
            link: "https://neoanki.app"
        ),
    ])
    #expect(sanitized.attribute(.kern, at: 0, effectiveRange: nil) == nil)
    #expect(sanitized.attribute(.expansion, at: 0, effectiveRange: nil) == nil)
    #expect(sanitized.attribute(.obliqueness, at: 0, effectiveRange: nil) == nil)
}

@Test func pastedInlineAttachmentsAreRemovedAndSelectionIsPreserved() {
    let input = NSMutableAttributedString(string: "A")
    input.append(NSAttributedString(attachment: NSTextAttachment()))
    input.append(NSAttributedString(string: "B"))
    let originalSelection = NSRange(location: input.length, length: 0)

    let sanitized = RichTextEditing.sanitizedAttributedString(input)
    let sanitizedSelection = RichTextEditing.sanitizedSelection(
        originalSelection,
        from: input
    )

    #expect(sanitized.string == "AB")
    #expect(sanitizedSelection == NSRange(location: 2, length: 0))
}

@Test @MainActor func pasteSanitizationCanonicalizesNextInsertionAttributes() {
    let textView = makeTextView(text: "Paste", selection: NSRange(location: 5, length: 0))
    textView.textStorage?.setAttributedString(
        SpanFormatting.attributedString(from: [Span("Paste", styles: [.italic], textColor: .blue)])
    )
    textView.typingAttributes[.kern] = 12

    RichTextEditing.synchronizeTypingAttributes(in: textView)

    #expect(textView.typingAttributes[.kern] == nil)
    let typingSpan = SpanFormatting.spans(
        from: NSAttributedString(string: "x", attributes: textView.typingAttributes)
    ).first
    #expect(typingSpan == Span("x", styles: [.italic], textColor: .blue))
}

@Test @MainActor func emptyEditorUsesAdaptiveTextColorForNextInsertion() {
    let textView = makeTextView(text: "", selection: NSRange(location: 0, length: 0))
    textView.typingAttributes = [
        .font: DesignSystem.Typography.richTextFont,
        .foregroundColor: NSColor.black,
    ]

    RichTextEditing.resetTypingAttributes(in: textView)
    textView.insertText("Next", replacementRange: textView.selectedRange())

    let insertedColor = textView.attributedString().attribute(
        .foregroundColor,
        at: 0,
        effectiveRange: nil
    ) as? NSColor
    #expect(insertedColor?.isEqual(NSColor.textColor) == true)
}
