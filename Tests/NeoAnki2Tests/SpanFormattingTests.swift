import NeoAnkiCore
import Testing

@testable import NeoAnki2

@Test func spanFormattingRoundTripsPlainText() {
    let spans = [Span("Hello"), Span(" world")]
    let roundTripped = SpanFormatting.spans(from: SpanFormatting.attributedString(from: spans))

    #expect(roundTripped == [Span("Hello world")])
}

@Test func spanFormattingRoundTripsStyledRuns() {
    let spans = [
        Span("Bold", styles: [.bold]),
        Span(" and ", styles: []),
        Span("italic", styles: [.italic]),
    ]
    let roundTripped = SpanFormatting.spans(from: SpanFormatting.attributedString(from: spans))

    #expect(roundTripped == spans)
}

@Test func spanFormattingPlainTextTrimsWhitespace() {
    let spans = [Span("  France  ")]
    #expect(SpanFormatting.plainText(from: spans) == "France")
}

@Test func spanFormattingRoundTripsEachStyle() {
    for style in [Span.Style.bold, .italic, .underline, .strikethrough, .highlight, .code] {
        let spans = [Span("styled", styles: [style])]
        let roundTripped = SpanFormatting.spans(from: SpanFormatting.attributedString(from: spans))
        #expect(roundTripped == spans)
    }
}

@Test func spanFormattingSwiftUIAttributedStringPreservesText() {
    let spans = [
        Span("Bold", styles: [.bold]),
        Span(" plain", styles: []),
    ]
    let attributed = SpanFormatting.swiftUIAttributedString(from: spans)

    #expect(String(attributed.characters) == "Bold plain")
}

@Test func spanFormattingTestingDescriptionSummarizesStyledRuns() {
    let description = SpanFormatting.testingDescription(from: [
        Span("Bold", styles: [.bold]),
        Span(" plain", styles: []),
    ])

    #expect(description == "bold:Bold|plain: plain")
}

@Test func richTextFieldContentValueAlwaysStoresRich() {
    let field = FieldDef(name: "Notes", type: .richText, isRequired: false)
    let value = field.contentValue(from: [Span("Plain")])

    #expect(value == .rich([Span("Plain")]))
}

@Test func textFieldContentValueKeepsPlainTextWithoutStyles() {
    let field = FieldDef(name: "Front", type: .text, isRequired: true)
    #expect(field.contentValue(from: [Span("Paris")]) == .text("Paris"))
}

@Test func textFieldContentValueStoresRichTextWhenStyled() {
    let field = FieldDef(name: "Front", type: .text, isRequired: true)
    let value = field.contentValue(from: [Span("Paris", styles: [.bold])])

    #expect(value == .rich([Span("Paris", styles: [.bold])]))
}
