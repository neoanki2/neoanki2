import Foundation
import Testing
@testable import NeoAnkiCore

@Test func legacyRichTextPayloadDecodesWithoutNewFormattingMembers() throws {
    let data = Data(
        #"{"rich":{"_0":[{"text":"Legacy","styles":["bold"]}]}}"#.utf8
    )

    let value = try JSONDecoder().decode(ContentValue.self, from: data)

    #expect(value == .rich([Span("Legacy", styles: [.bold])]))
}

@Test func richTextLinkValidationAllowsOnlySafePortableSchemes() {
    #expect(RichTextValidation.isValidLink("https://neoanki.app/docs"))
    #expect(RichTextValidation.isValidLink("http://localhost:8080"))
    #expect(RichTextValidation.isValidLink("mailto:study@example.com"))
    #expect(!RichTextValidation.isValidLink("javascript:alert(1)"))
    #expect(!RichTextValidation.isValidLink("https://example.com/a path"))
    #expect(!RichTextValidation.isValidLink("https:///missing-host"))
}

@Test func spanNormalizesMutuallyExclusiveStyles() {
    var span = Span(
        "Legacy",
        styles: [.bold, .highlight, .code, .superscript, .subscriptText]
    )

    #expect(span.styles == [.bold, .highlight, .superscript])

    span.styles.insert(.code)
    span.styles.insert(.subscriptText)
    #expect(span.styles == [.bold, .highlight, .superscript])
}

@Test func spanCodableNormalizesLegacyConflictingStyles() throws {
    let data = Data(
        #"{"text":"Legacy","styles":["highlight","code","superscript","subscript"]}"#.utf8
    )

    let span = try JSONDecoder().decode(Span.self, from: data)
    let encoded = try JSONEncoder().encode(span)
    let roundTripped = try JSONDecoder().decode(Span.self, from: encoded)

    #expect(span.styles == [.highlight, .superscript])
    #expect(roundTripped == span)
}
