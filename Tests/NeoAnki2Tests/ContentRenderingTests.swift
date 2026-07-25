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

@Test func renderingPolicyCoversEveryContentRevealCombinationWithoutAccessibilityLeaks() {
    let secret = "ANSWER_SECRET"
    let fixtures = renderingFixtures(secret: secret)
    var combinationCount = 0

    for fixture in fixtures {
        for revealMode in RevealMode.allCases {
            for isAnswerRevealed in [false, true] {
                combinationCount += 1
                let decision = ContentRenderingPolicy.decision(
                    for: fixture.value,
                    revealMode: revealMode,
                    isAnswerRevealed: isAnswerRevealed
                )
                let isConcealed = !fixture.isEmpty
                    && !isAnswerRevealed
                    && revealMode != .always

                if isConcealed {
                    let canSafelyBlur = revealMode == .blurred && fixture.canRenderBlurredMedia
                    #expect(decision.rendering == (canSafelyBlur ? .blurredMedia : .placeholder))
                    #expect(decision.shouldResolveMedia == canSafelyBlur)
                    #expect(decision.accessibilityLabel != nil)
                    #expect(decision.accessibilityLabel?.contains(secret) == false)
                } else {
                    #expect(decision.rendering == .content)
                    #expect(decision.shouldResolveMedia == fixture.isMedia)
                    #expect(decision.accessibilityLabel == nil)
                }
            }
        }
    }

    #expect(combinationCount == fixtures.count * RevealMode.allCases.count * 2)
    #expect(combinationCount == 54)
}

@Test func concealedTimeBasedMediaCannotResolveOrExposePlayback() {
    let secret = "spoken answer"

    for kind in [MediaKind.audio, .video] {
        let value = ContentValue.media(mediaRef(kind: kind, altText: secret))
        for revealMode in [RevealMode.hiddenUntilAnswer, .blurred] {
            let decision = ContentRenderingPolicy.decision(
                for: value,
                revealMode: revealMode,
                isAnswerRevealed: false
            )

            #expect(decision.rendering == .placeholder)
            #expect(decision.shouldResolveMedia == false)
            #expect(decision.accessibilityLabel?.contains(secret) == false)
        }
    }
}

private struct RenderingFixture {
    let value: ContentValue
    var isMedia = false
    var canRenderBlurredMedia = false
    var isEmpty = false
}

private func renderingFixtures(secret: String) -> [RenderingFixture] {
    [
        RenderingFixture(value: .text(secret, lang: "en")),
        RenderingFixture(value: .rich([Span(secret, styles: [.bold])])),
        RenderingFixture(value: .number(42)),
        RenderingFixture(
            value: .cloze(
                secret,
                blanks: [ClozeSpan(group: 1, start: 0, length: secret.count)]
            )
        ),
        RenderingFixture(
            value: .media(mediaRef(kind: .audio, altText: secret)),
            isMedia: true
        ),
        RenderingFixture(
            value: .media(mediaRef(kind: .image, altText: secret)),
            isMedia: true,
            canRenderBlurredMedia: true
        ),
        RenderingFixture(
            value: .media(mediaRef(kind: .gif, altText: secret)),
            isMedia: true,
            canRenderBlurredMedia: true
        ),
        RenderingFixture(
            value: .media(mediaRef(kind: .video, altText: secret)),
            isMedia: true
        ),
        RenderingFixture(value: .empty, isEmpty: true),
    ]
}

private func mediaRef(kind: MediaKind, altText: String) -> MediaRef {
    let fileExtension: String = switch kind {
    case .audio: "m4a"
    case .image: "png"
    case .gif: "gif"
    case .video: "mp4"
    }
    return MediaRef(
        kind: kind,
        assetHash: String(repeating: "a", count: 64),
        fileExtension: fileExtension,
        altText: altText
    )
}
