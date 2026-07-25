import Foundation
import Testing
@testable import NeoAnkiCore

private func makeItemType() -> (ItemType, front: FieldDef, back: FieldDef, audio: FieldDef) {
    let front = FieldDef(name: "Front", type: .text)
    let back = FieldDef(name: "Back", type: .text)
    let audio = FieldDef(name: "Audio", type: .audio)

    let recall = Template(
        name: "Recall",
        prompt: Side(slots: [Slot(source: .field(front.id))]),
        answer: Side(slots: [Slot(source: .field(back.id))]),
        interaction: .reveal,
        skill: Skill(input: .text, output: .freeResponse, operation: .recall)
    )
    let listening = Template(
        name: "Listening",
        prompt: Side(slots: [
            Slot(source: .field(audio.id), presentation: Presentation(media: .autoplay)),
        ]),
        answer: Side(slots: [Slot(source: .field(back.id))]),
        interaction: .reveal,
        skill: Skill(input: .audio, output: .freeResponse, operation: .recognize),
        generateWhen: .fieldNotEmpty(audio.id)
    )

    let type = ItemType(
        name: "Basic",
        fields: [front, back, audio],
        templates: [recall, listening]
    )
    return (type, front, back, audio)
}

@Test func gatedTemplateIsSkippedWhenFieldEmpty() {
    let (type, front, back, _) = makeItemType()
    let item = Item(itemTypeID: type.id, fields: [
        FieldValue(fieldID: front.id, value: .text("Q")),
        FieldValue(fieldID: back.id, value: .text("A")),
    ])

    let cards = CardGenerator.cards(for: item, type: type)

    #expect(cards.count == 1)
    #expect(cards.first?.skill.operation == .recall)
}

@Test func gatedTemplateGeneratesWhenFieldPresent() {
    let (type, front, back, audio) = makeItemType()
    let item = Item(itemTypeID: type.id, fields: [
        FieldValue(fieldID: front.id, value: .text("Q")),
        FieldValue(fieldID: back.id, value: .text("A")),
        FieldValue(
            fieldID: audio.id,
            value: .media(MediaRef(kind: .audio, assetHash: String(repeating: "a", count: 64), fileExtension: "m4a"))
        ),
    ])

    let cards = CardGenerator.cards(for: item, type: type)

    #expect(cards.count == 2)
    #expect(cards.allSatisfy { $0.memory.phase == .new })
}

@Test func itemPreservesMediaThroughCoding() throws {
    let (type, front, back, audio) = makeItemType()
    let item = Item(itemTypeID: type.id, fields: [
        FieldValue(fieldID: front.id, value: .text("Q")),
        FieldValue(fieldID: back.id, value: .rich([Span("A", styles: [.bold])])),
        FieldValue(
            fieldID: audio.id,
            value: .media(MediaRef(kind: .audio, assetHash: String(repeating: "a", count: 64), fileExtension: "m4a"))
        ),
    ])

    let data = try JSONEncoder().encode(item)
    let decoded = try JSONDecoder().decode(Item.self, from: data)

    #expect(decoded == item)
}

@Test func nestedGenerationConditionsEvaluateAllAndAnyBranches() {
    let (type, front, back, audio) = makeItemType()
    var nestedType = type
    nestedType.templates = [
        Template(
            name: "Nested",
            prompt: Side(slots: [Slot(source: .literal("Prompt")), Slot(source: .field(front.id))]),
            answer: Side(slots: [Slot(source: .field(back.id))]),
            interaction: .choose,
            skill: Skill(input: .text, output: .selection, operation: .discriminate),
            generateWhen: .all([
                .fieldNotEmpty(front.id),
                .any([.fieldEmpty(audio.id), .fieldNotEmpty(back.id)]),
            ])
        ),
    ]
    let matching = Item(itemTypeID: type.id, fields: [
        FieldValue(fieldID: front.id, value: .text("Q")),
        FieldValue(fieldID: back.id, value: .text("A")),
    ])
    let failing = Item(itemTypeID: type.id, fields: [
        FieldValue(fieldID: front.id, value: .empty),
        FieldValue(fieldID: back.id, value: .text("A")),
    ])

    #expect(CardGenerator.cards(for: matching, type: nestedType).count == 1)
    #expect(CardGenerator.cards(for: failing, type: nestedType).isEmpty)
}

@Test func clozeTemplateGeneratesOneCardPerDistinctGroup() {
    let field = FieldDef(name: "Text", type: .cloze)
    let template = Template(
        name: "Cloze",
        prompt: Side(slots: [
            Slot(
                source: .field(field.id),
                presentation: Presentation(reveal: .hiddenUntilAnswer)
            ),
        ]),
        answer: Side(slots: [Slot(source: .field(field.id))]),
        interaction: .cloze,
        skill: Skill(input: .text, output: .freeResponse, operation: .recall)
    )
    let type = ItemType(name: "Cloze", fields: [field], templates: [template])
    let item = Item(itemTypeID: type.id, fields: [
        FieldValue(
            fieldID: field.id,
            value: .cloze(
                "Mercury Venus Earth",
                blanks: [
                    ClozeSpan(group: 2, start: 0, length: 7),
                    ClozeSpan(group: 1, start: 8, length: 5),
                    ClozeSpan(group: 1, start: 14, length: 5),
                ]
            )
        ),
    ])

    let cards = CardGenerator.cards(for: item, type: type)

    #expect(cards.map(\.clozeGroup) == [1, 2])
    #expect(Set(cards.map(\.templateID)) == [template.id])
}
