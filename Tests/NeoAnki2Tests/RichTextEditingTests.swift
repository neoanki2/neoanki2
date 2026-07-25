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

@Test @MainActor func toggleBoldSetsTypingAttributesWhenNothingSelected() {
    let textView = makeTextView(text: "Hello", selection: NSRange(location: 5, length: 0))

    RichTextEditing.toggleStyle(.bold, in: textView)

    let typingStyles = SpanFormatting.spans(
        from: NSAttributedString(string: "x", attributes: textView.typingAttributes)
    ).first?.styles
    #expect(typingStyles == [.bold])
}
