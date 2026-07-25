import Foundation
import Testing
@testable import NeoAnkiCore

private func makeValidItemType() -> ItemType {
    let front = FieldDef(name: "Front", type: .text, isRequired: true)
    let back = FieldDef(name: "Back", type: .text, isRequired: true)
    let template = Template(
        name: "Card",
        prompt: Side(slots: [Slot(source: .field(front.id))]),
        answer: Side(slots: [Slot(source: .field(back.id))]),
        interaction: .reveal,
        skill: Skill(input: .text, output: .text, operation: .recognize)
    )
    return ItemType(name: "Test", fields: [front, back], templates: [template])
}

@Test func validateNameTrimsWhitespace() throws {
    let name = try ItemTypeValidation.validateName("  Geography  ")
    #expect(name == "Geography")
}

@Test func validateNameRejectsEmpty() async {
    await #expect(throws: DatabaseError.invalidItemType("Item type name is required.")) {
        try ItemTypeValidation.validateName("   ")
    }
}

@Test func validateFieldsRejectsEmptyList() async {
    await #expect(throws: DatabaseError.invalidItemType("An item type needs at least one field.")) {
        try ItemTypeValidation.validateFields([])
    }
}

@Test func validateFieldsRejectsBlankFieldName() async {
    let field = FieldDef(name: "  ", type: .text)
    await #expect(throws: DatabaseError.invalidItemType("Every field needs a name.")) {
        try ItemTypeValidation.validateFields([field])
    }
}

@Test func validateFieldsRejectsDuplicateNamesCaseInsensitive() async {
    let fields = [
        FieldDef(name: "Front", type: .text),
        FieldDef(name: "front", type: .text),
    ]
    await #expect(throws: DatabaseError.invalidItemType("Field names must be unique.")) {
        try ItemTypeValidation.validateFields(fields)
    }
}

@Test func validateRejectsMissingTemplates() async {
    let front = FieldDef(name: "Front", type: .text)
    let back = FieldDef(name: "Back", type: .text)
    let itemType = ItemType(name: "Empty", fields: [front, back], templates: [])

    await #expect(throws: DatabaseError.invalidItemType("An item type must have at least one template.")) {
        try ItemTypeValidation.validate(itemType)
    }
}

@Test func validateRejectsBlankTemplateName() async {
    let front = FieldDef(name: "Front", type: .text)
    let back = FieldDef(name: "Back", type: .text)
    let template = Template(
        name: "  ",
        prompt: Side(slots: [Slot(source: .field(front.id))]),
        answer: Side(slots: [Slot(source: .field(back.id))]),
        interaction: .reveal,
        skill: Skill(input: .text, output: .text, operation: .recognize)
    )
    let itemType = ItemType(name: "Test", fields: [front, back], templates: [template])

    await #expect(throws: DatabaseError.invalidItemType("Every template needs a name.")) {
        try ItemTypeValidation.validate(itemType)
    }
}

@Test func validateRejectsUnknownFieldReference() async {
    let front = FieldDef(name: "Front", type: .text)
    let unknownID = UUID()
    let template = Template(
        name: "Card",
        prompt: Side(slots: [Slot(source: .field(unknownID))]),
        answer: Side(slots: [Slot(source: .field(front.id))]),
        interaction: .reveal,
        skill: Skill(input: .text, output: .text, operation: .recognize)
    )
    let itemType = ItemType(name: "Test", fields: [front], templates: [template])

    await #expect(throws: DatabaseError.invalidItemType("Template \"Card\" references an unknown field.")) {
        try ItemTypeValidation.validate(itemType)
    }
}

@Test func validateAcceptsValidItemType() throws {
    let itemType = makeValidItemType()
    try ItemTypeValidation.validate(itemType)
}

@Test func validateFieldRemovalRejectsUsedField() throws {
    let itemType = makeValidItemType()
    let removedID = try #require(itemType.fields.first?.id)

    #expect(throws: DatabaseError.invalidItemType("Can't remove \"Front\" because a template uses it.")) {
        try ItemTypeValidation.validateFieldRemoval(removedIDs: [removedID], in: itemType)
    }
}

@Test func validateFieldRemovalAllowsUnusedField() throws {
    let extra = FieldDef(name: "Extra", type: .text)
    var itemType = makeValidItemType()
    itemType.fields.append(extra)

    try ItemTypeValidation.validateFieldRemoval(removedIDs: [extra.id], in: itemType)
}

@Test func fieldIDsReferencedCollectsPromptAnswerAndGenerateWhen() {
    let front = FieldDef(name: "Front", type: .text)
    let back = FieldDef(name: "Back", type: .text)
    let map = FieldDef(name: "Map", type: .image)
    let template = Template(
        name: "Card",
        prompt: Side(slots: [Slot(source: .field(front.id))]),
        answer: Side(slots: [Slot(source: .field(back.id))]),
        interaction: .reveal,
        skill: Skill(input: .text, output: .text, operation: .recognize),
        generateWhen: .fieldNotEmpty(map.id)
    )

    let ids = ItemTypeValidation.fieldIDsReferenced(by: template)
    #expect(ids.contains(front.id))
    #expect(ids.contains(back.id))
    #expect(ids.contains(map.id))
}

@Test func itemTypeBuilderRejectsSingleTextField() async {
    await #expect(throws: DatabaseError.invalidItemType("Add at least two text fields.")) {
        try ItemTypeBuilder.makeItemType(
            name: "Solo",
            fields: [FieldDef(name: "Only", type: .text, isRequired: true)]
        )
    }
}

@Test func itemTypeBuilderCreatesDefaultTemplate() throws {
    let itemType = try ItemTypeBuilder.makeItemType(
        name: "Pairs",
        fields: [
            FieldDef(name: "A", type: .text, isRequired: true),
            FieldDef(name: "B", type: .text, isRequired: true),
        ]
    )

    #expect(itemType.name == "Pairs")
    #expect(itemType.templates.count == 1)
    #expect(itemType.templates.first?.name == "Card")
}
