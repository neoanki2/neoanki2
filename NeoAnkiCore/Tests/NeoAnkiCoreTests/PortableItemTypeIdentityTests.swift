import Foundation
import Testing
@testable import NeoAnkiCore

@Test func portableItemTypeDigestIgnoresAllUUIDs() throws {
    let first = makePortableIdentityItemType()
    let second = replacingUUIDs(in: first)

    #expect(first.id != second.id)
    #expect(first.fields.map(\.id) != second.fields.map(\.id))
    #expect(first.templates.map(\.id) != second.templates.map(\.id))
    #expect(
        try PortableItemTypeIdentity.canonicalRepresentation(of: first)
            == PortableItemTypeIdentity.canonicalRepresentation(of: second)
    )
    #expect(try first.portableSchemaDigest() == second.portableSchemaDigest())
}

@Test func portableItemTypeDigestIncludesSemanticPropertiesAndOrder() throws {
    let original = makePortableIdentityItemType()
    let originalDigest = try original.portableSchemaDigest()

    var renamed = original
    renamed.templates[0].name = "Renamed"

    var reorderedFields = original
    reorderedFields.fields.swapAt(0, 1)

    var changedPresentation = original
    changedPresentation.templates[0].prompt.slots[0].presentation.reveal = .blurred

    var changedCondition = original
    changedCondition.templates[0].generateWhen = .fieldEmpty(original.fields[0].id)

    #expect(try renamed.portableSchemaDigest() != originalDigest)
    #expect(try reorderedFields.portableSchemaDigest() != originalDigest)
    #expect(try changedPresentation.portableSchemaDigest() != originalDigest)
    #expect(try changedCondition.portableSchemaDigest() != originalDigest)
}

@Test func portableItemTypeDigestNormalizesUnicodeToNFC() throws {
    var composed = makePortableIdentityItemType()
    composed.name = "Café"
    composed.fields[0].name = "Résumé"
    composed.templates[0].prompt.slots[0].source = .literal("Voilà")

    var decomposed = composed
    decomposed.name = "Cafe\u{301}"
    decomposed.fields[0].name = "Re\u{301}sume\u{301}"
    decomposed.templates[0].prompt.slots[0].source = .literal("Voila\u{300}")

    #expect(try composed.portableSchemaDigest() == decomposed.portableSchemaDigest())
}

@Test func portableItemTypeCanonicalDataUsesNormativePortableShape() throws {
    let itemType = makePortableIdentityItemType()
    let json = String(decoding: try PortableItemTypeIdentity.canonicalData(of: itemType), as: UTF8.self)

    #expect(json.contains(#""fields":[{"kind":"richText","name":"Front","required":true}"#))
    #expect(json.contains(#""source":{"field":1}"#))
    #expect(json.contains(#""source":{"literal":"Listen / recall"}"#))
    #expect(json.contains(#""generateWhen":{"all":[{"fieldNotEmpty":1},{"any":[{"fieldNotEmpty":0},{"fieldEmpty":2}]}]}"#))
    #expect(!json.contains(#""fieldOrdinal""#))
    #expect(!json.contains(#""slots""#))
}

@Test func portableItemTypeCanonicalizationRejectsUnknownFieldReferences() {
    var itemType = makePortableIdentityItemType()
    let unknownID = UUID()
    itemType.templates[0].generateWhen = .fieldNotEmpty(unknownID)

    #expect(throws: PortableItemTypeIdentityError.unknownFieldReference(unknownID)) {
        try itemType.portableSchemaDigest()
    }
}

private func makePortableIdentityItemType() -> ItemType {
    let front = FieldDef(name: "Front", type: .richText, isRequired: true)
    let sound = FieldDef(name: "Sound", type: .audio)
    let score = FieldDef(name: "Score", type: .number)
    let template = Template(
        name: "Recall",
        prompt: Side(slots: [
            Slot(
                source: .literal("Listen / recall"),
                presentation: Presentation(reveal: .always, media: .default)
            ),
            Slot(
                source: .field(sound.id),
                presentation: Presentation(reveal: .hiddenUntilAnswer, media: .autoplay)
            ),
        ]),
        answer: Side(slots: [
            Slot(
                source: .field(front.id),
                presentation: Presentation(reveal: .blurred, media: .default)
            ),
            Slot(source: .field(score.id)),
        ]),
        interaction: .type,
        skill: Skill(input: .audio, output: .freeResponse, operation: .recall),
        generateWhen: .all([
            .fieldNotEmpty(sound.id),
            .any([
                .fieldNotEmpty(front.id),
                .fieldEmpty(score.id),
            ]),
        ])
    )
    return ItemType(name: "Vocabulary", fields: [front, sound, score], templates: [template])
}

private func replacingUUIDs(in itemType: ItemType) -> ItemType {
    let fields = itemType.fields.map {
        FieldDef(name: $0.name, type: $0.type, isRequired: $0.isRequired)
    }
    let replacements = Dictionary(
        uniqueKeysWithValues: zip(itemType.fields.map(\.id), fields.map(\.id))
    )
    let templates = itemType.templates.map { template in
        Template(
            name: template.name,
            prompt: replacingUUIDs(in: template.prompt, using: replacements),
            answer: replacingUUIDs(in: template.answer, using: replacements),
            interaction: template.interaction,
            skill: template.skill,
            generateWhen: template.generateWhen.map {
                replacingUUIDs(in: $0, using: replacements)
            }
        )
    }
    return ItemType(name: itemType.name, fields: fields, templates: templates)
}

private func replacingUUIDs(in side: Side, using replacements: [UUID: UUID]) -> Side {
    Side(slots: side.slots.map { slot in
        let source: SlotSource
        switch slot.source {
        case let .field(id):
            source = .field(replacements[id]!)
        case let .literal(value):
            source = .literal(value)
        }
        return Slot(source: source, presentation: slot.presentation)
    })
}

private func replacingUUIDs(
    in condition: SlotCondition,
    using replacements: [UUID: UUID]
) -> SlotCondition {
    switch condition {
    case let .fieldNotEmpty(id):
        return .fieldNotEmpty(replacements[id]!)
    case let .fieldEmpty(id):
        return .fieldEmpty(replacements[id]!)
    case let .all(conditions):
        return .all(conditions.map { replacingUUIDs(in: $0, using: replacements) })
    case let .any(conditions):
        return .any(conditions.map { replacingUUIDs(in: $0, using: replacements) })
    }
}
