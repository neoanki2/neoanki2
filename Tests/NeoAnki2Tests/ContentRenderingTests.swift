import Foundation
import NeoAnkiCore
import Testing

@testable import NeoAnki2

@Test func numberRenderingUsesLocaleSeparatorsAndOmitsIntegerFraction() {
    #expect(
        ContentNumberRendering.string(from: 1_234.5, locale: Locale(identifier: "en_US"))
            == "1,234.5"
    )
    #expect(
        ContentNumberRendering.string(from: 42, locale: Locale(identifier: "en_US"))
            == "42"
    )

    let french = ContentNumberRendering.string(
        from: 1_234.5,
        locale: Locale(identifier: "fr_FR")
    )
    #expect(french.hasSuffix(",5"))
    #expect(french != "1234.5")
}

@Test func numberRenderingRejectsNonFiniteValues() {
    let locale = Locale(identifier: "en_US")
    #expect(ContentNumberRendering.string(from: .nan, locale: locale) == "Invalid number")
    #expect(ContentNumberRendering.string(from: .infinity, locale: locale) == "Invalid number")
    #expect(ContentNumberRendering.string(from: -.infinity, locale: locale) == "Invalid number")
}

@Test func languageMetadataNormalizesSafeBCP47Tags() {
    #expect(LanguageMetadata.accessibilityTag(from: "es-MX") == "es-MX")
    #expect(LanguageMetadata.accessibilityTag(from: " zh_Hant_TW ") == "zh-Hant-TW")
    #expect(LanguageMetadata.accessibilityTag(from: nil) == nil)
    #expect(LanguageMetadata.accessibilityTag(from: "not valid!") == nil)
    #expect(LanguageMetadata.accessibilityTag(from: "e") == nil)

    let spokenText = LanguageMetadata.attributedString("Hola", language: "es-MX")
    #expect(spokenText.languageIdentifier == "es-MX")
}
