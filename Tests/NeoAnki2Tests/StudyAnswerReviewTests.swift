import Foundation
import NeoAnkiCore
import NeoAnkiSharedUI
import Testing

@Test func answerReviewSeparatesAnswerOnlyNotesFromContext() {
    func component(_ purpose: ComponentPurpose, _ reveal: RevealMode = .always) -> ResolvedTemplateComponent {
        .init(id: UUID(), region: .supporting, purpose: purpose,
              value: .text("Content"), presentation: .init(reveal: reveal))
    }
    let question = component(.question)
    let context = component(.supporting)
    let answer = component(.expectedAnswer, .hiddenUntilAnswer)
    let note = component(.supporting, .hiddenUntilAnswer)
    let components = [question, context, answer, note]
    let review = StudyAnswerReviewProjection(components: components)
    #expect(review.prompt == [question, context])
    #expect(review.answer == [answer])
    #expect(review.explanation == [note])
    // Review sections remain lossless, and no answer-only note leaks before checking.
    #expect(Set((review.prompt + review.answer + review.explanation).map(\.id)) == Set(components.map(\.id)))
    for layout in CardLayoutID.allCases {
        let concealed = CardWireframeDescriptor.descriptor(for: layout)
            .renderedComponents(from: components, answerRevealed: false)
        #expect(concealed.map(\.id) == [question.id, context.id])
    }
}

@Test func answerDifferenceHighlightsMissingArticleWithoutMarkingRestOfSentence() {
    let diff = StudyAnswerDifference(response: "They canceled meeting.", answer: "They canceled the meeting.")
    #expect(diff.response.allSatisfy { !$0.changed })
    #expect(diff.answer.filter(\.changed).map(\.text) == ["the"])
    #expect(diff.answer.map(\.text).joined() == "They canceled the meeting.")
}

@Test func answerDifferencePreservesWhitespaceAndMarksBothSidesOfReplacement() {
    let response = "They\t canceled  a meeting.\n"
    let answer = "They canceled the meeting."
    let diff = StudyAnswerDifference(response: response, answer: answer)
    #expect(diff.response.map(\.text).joined() == response)
    #expect(diff.answer.map(\.text).joined() == answer)
    #expect(diff.response.filter(\.changed).map(\.text) == ["a"])
    #expect(diff.answer.filter(\.changed).map(\.text) == ["the"])
}

@Test func answerDifferenceHandlesRepeatedWordsAndEmptyResponses() {
    let repeated = StudyAnswerDifference(response: "the the meeting", answer: "the meeting")
    #expect(repeated.response.filter(\.changed).map(\.text) == ["the"])
    #expect(repeated.answer.allSatisfy { !$0.changed })
    let empty = StudyAnswerDifference(response: "", answer: "Зустріч 👋")
    #expect(empty.response.isEmpty)
    #expect(empty.answer.filter(\.changed).map(\.text) == ["Зустріч", "👋"])
}
