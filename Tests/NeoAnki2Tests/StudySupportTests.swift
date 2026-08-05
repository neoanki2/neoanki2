import Foundation
import NeoAnkiCore
import Testing

@testable import NeoAnki2

private let promptFieldID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
private let answerFieldID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
private let recallSkill = Skill(input: .text, output: .freeResponse, operation: .recall)

private func supportCard(
    interaction: Interaction,
    prompt: ContentValue = .text("Capital of France"),
    answer: ContentValue = .text("Paris"),
    extraValues: [ContentValue] = [.text("Lyon"), .text("Berlin")]
) -> DueCard {
    let extraFields = extraValues.enumerated().map { index, value in
        FieldValue(
            fieldID: UUID(uuidString: "20000000-0000-0000-0000-\(String(format: "%012d", index + 1))")!,
            value: value
        )
    }
    let item = Item(
        id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
        itemTypeID: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
        fields: [
            FieldValue(fieldID: promptFieldID, value: prompt),
            FieldValue(fieldID: answerFieldID, value: answer),
        ] + extraFields
    )
    let template = Template(
        id: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!,
        name: "Test",
        prompt: Side(slots: [Slot(source: .field(promptFieldID))]),
        answer: Side(slots: [Slot(source: .field(answerFieldID))]),
        interaction: interaction,
        skill: recallSkill
    )
    let type = ItemType(id: item.itemTypeID, name: "Test", fields: [], templates: [template])
    return DueCard(
        card: Card(itemID: item.id, templateID: template.id, skill: recallSkill),
        item: item,
        itemType: type,
        template: template
    )
}

@Test func everyInteractionIsSupported() {
    for interaction in [Interaction.reveal, .type, .choose, .record, .cloze, .arrange] {
        #expect(StudySupport.isSupportedInteraction(interaction))
    }
}

@Test func typedAnswersNormalizeCaseWhitespaceAndDiacritics() {
    let card = supportCard(interaction: .type, answer: .text("  Café au lait "))

    #expect(StudySupport.evaluate("cafe   AU LAIT", for: card) == .correct)
    #expect(StudySupport.evaluate("tea", for: card) == .incorrect)
}

@Test func choicesAreDeterministicAndIncludeCorrectAnswer() {
    let card = supportCard(interaction: .choose)

    let first = StudySupport.choiceOptions(for: card)
    let second = StudySupport.choiceOptions(for: card)

    #expect(first == second)
    #expect(first.contains("Paris"))
    #expect(Set(first).count == first.count)
}

@Test func choicesRecoverWhenOnlyAnswerContentExists() {
    let card = supportCard(
        interaction: .choose,
        prompt: .empty,
        answer: .text("Paris"),
        extraValues: []
    )

    let options = StudySupport.choiceOptions(for: card)

    #expect(options.count == 2)
    #expect(options.contains("Paris"))
}

@Test func arrangementIsDeterministicAndCompletable() {
    let card = supportCard(interaction: .arrange, answer: .text("one two three"))

    let arrangement = StudySupport.arrangement(for: card)

    #expect(arrangement?.expected == ["one", "two", "three"])
    #expect(arrangement?.initial != arrangement?.expected)
    #expect(StudySupport.isCorrectArrangement(["one", "two", "three"], for: card) == .correct)
}

@Test func malformedAndMissingAnswersDegradeToSelfGrade() {
    let emptyCard = supportCard(interaction: .type, answer: .empty)
    let singleUnit = supportCard(interaction: .arrange, answer: .text("🧠"))

    #expect(StudySupport.evaluate("anything", for: emptyCard) == .unavailable)
    #expect(StudySupport.choiceOptions(for: emptyCard).isEmpty)
    #expect(StudySupport.arrangement(for: singleUnit) == nil)
}

@Test func referenceAudioDetectionDoesNotInventAudioForTextAnswers() {
    let textCard = supportCard(interaction: .record, answer: .text("кача́лка", lang: "uk"))
    let audioReference = MediaRef(
        kind: .audio,
        assetHash: String(repeating: "a", count: 64),
        fileExtension: "m4a",
        altText: "Ukrainian pronunciation"
    )
    let audioCard = supportCard(interaction: .record, answer: .media(audioReference))

    #expect(StudySupport.hasReferenceAudio(for: textCard) == false)
    #expect(StudySupport.hasReferenceAudio(for: audioCard))
}
