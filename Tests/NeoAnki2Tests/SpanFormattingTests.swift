import NeoAnkiCore
import Testing
import AppKit

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
    for style in [
        Span.Style.bold,
        .italic,
        .underline,
        .strikethrough,
        .highlight,
        .code,
        .superscript,
        .subscriptText,
    ] {
        let spans = [Span("styled", styles: [style])]
        let roundTripped = SpanFormatting.spans(from: SpanFormatting.attributedString(from: spans))
        #expect(roundTripped == spans)
    }
}

@Test func spanFormattingRoundTripsNativeInlineFormatting() {
    let spans = [
        Span(
            "NeoAnki",
            styles: [.bold, .underline],
            textColor: .purple,
            textSize: .large,
            link: "https://neoanki.app"
        ),
        Span(" note", textColor: .green, textSize: .small),
    ]

    let roundTripped = SpanFormatting.spans(
        from: SpanFormatting.attributedString(from: spans)
    )

    #expect(roundTripped == spans)
}

@Test func semanticTextColorsMeetContrastInLightAndDarkAppearances() throws {
    func luminance(_ color: NSColor) throws -> CGFloat {
        let rgb = try #require(color.usingColorSpace(.sRGB))
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent)
            + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
    }

    for name in [NSAppearance.Name.aqua, .darkAqua] {
        let appearance = try #require(NSAppearance(named: name))
        var background = NSColor.textBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            background = NSColor.textBackgroundColor.usingColorSpace(.sRGB)
                ?? .textBackgroundColor
        }
        for color in Span.TextColor.allCases {
            var foreground = SpanFormatting.nsColor(for: color)
            appearance.performAsCurrentDrawingAppearance {
                foreground = SpanFormatting.nsColor(for: color).usingColorSpace(.sRGB)
                    ?? SpanFormatting.nsColor(for: color)
            }
            let lighter = max(try luminance(foreground), try luminance(background))
            let darker = min(try luminance(foreground), try luminance(background))
            #expect((lighter + 0.05) / (darker + 0.05) >= 4.5)
        }
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

@Test func textFieldContentValueStoresRichTextWhenOnlyColorIsApplied() {
    let field = FieldDef(name: "Front", type: .text, isRequired: true)
    let value = field.contentValue(from: [Span("Paris", textColor: .blue)])

    #expect(value == .rich([Span("Paris", textColor: .blue)]))
}
