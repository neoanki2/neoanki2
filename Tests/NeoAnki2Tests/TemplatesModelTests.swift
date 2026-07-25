import Foundation
import NeoAnkiCore
import Testing

@testable import NeoAnki2

@MainActor
private func makeTemplatesModel() async throws -> (TemplatesModel, ItemStore) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-template-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let databaseURL = url.appendingPathComponent("test.sqlite")
    let store = try ItemStore(databaseURL: databaseURL)
    try await store.bootstrap()
    return (TemplatesModel(store: store), store)
}

@Test @MainActor func templatesModelLoadsBasicItemType() async throws {
    let (model, _) = try await makeTemplatesModel()

    await model.load()

    #expect(model.isLoading == false)
    #expect(model.itemTypes.count == 2)
    #expect(model.itemTypes.first?.name == "Basic")
    #expect(model.selectedItemType?.templates.count == 1)
    #expect(model.errorMessage == nil)
}

@Test @MainActor func templatesModelSavesNewTemplate() async throws {
    let (model, store) = try await makeTemplatesModel()
    await model.load()

    let saved = await model.saveTemplate(
        TemplateDraft(
            name: "Reverse",
            promptFieldID: BuiltInItemTypes.backFieldID,
            answerFieldID: BuiltInItemTypes.frontFieldID
        ),
        editingID: nil
    )

    #expect(saved == true)
    #expect(model.selectedItemType?.templates.count == 2)
    #expect(model.selectedItemType?.templates.map(\.name).contains("Reverse") == true)

    let reloaded = try await store.itemType(id: BuiltInItemTypes.basicID)
    #expect(reloaded.templates.count == 2)
}

@Test @MainActor func templatesModelEditsTemplateName() async throws {
    let (model, store) = try await makeTemplatesModel()
    await model.load()

    guard let template = model.selectedItemType?.templates.first else {
        Issue.record("Expected default template.")
        return
    }

    var draft = TemplateDraft(template: template, in: model.selectedItemType!)
    draft.name = "Front to Back"

    let saved = await model.saveTemplate(draft, editingID: template.id)

    #expect(saved == true)
    #expect(model.selectedItemType?.templates.first?.name == "Front to Back")

    let reloaded = try await store.itemType(id: BuiltInItemTypes.basicID)
    #expect(reloaded.templates.first?.name == "Front to Back")
}

@Test @MainActor func newTemplateDraftKeepsAdvancedSettingsCollapsedWithoutChangingExistingIntent() async throws {
    let (model, _) = try await makeTemplatesModel()
    await model.load()
    let itemType = try #require(model.selectedItemType)
    let template = try #require(itemType.templates.first)

    let newDraft = TemplateDraft()
    #expect(newDraft.hasAdvancedSettings == false)

    let existingDraft = TemplateDraft(template: template, in: itemType)
    #expect(existingDraft.usesAutomaticSkill == false)
    #expect(existingDraft.hasAdvancedSettings)
}

@Test func existingTemplateDraftPreservesManualSkillWhenFieldsChange() throws {
    let cue = FieldDef(name: "Cue", type: .text)
    let response = FieldDef(name: "Response", type: .text)
    let image = FieldDef(name: "Image", type: .image)
    let originalSkill = Skill(input: .text, output: .text, operation: .recognize)
    let template = Template(
        name: "Manual",
        prompt: Side(slots: [Slot(source: .field(cue.id))]),
        answer: Side(slots: [Slot(source: .field(response.id))]),
        interaction: .reveal,
        skill: originalSkill
    )
    let itemType = ItemType(
        name: "Mixed",
        fields: [cue, response, image],
        templates: [template]
    )

    var draft = TemplateDraft(template: template, in: itemType)
    draft.promptSlots[0].fieldID = image.id
    let updated = try draft.template(id: template.id, in: itemType)

    #expect(draft.usesAutomaticSkill == false)
    #expect(updated.skill == originalSkill)
}

@Test func templateDraftAdvancedSettingsCoverEveryDisclosureTrigger() {
    let fieldID = UUID()
    let baseline = TemplateDraft(
        name: "Baseline",
        promptFieldID: fieldID,
        answerFieldID: fieldID
    )
    #expect(baseline.hasAdvancedSettings == false)

    var manualSkill = baseline
    manualSkill.usesAutomaticSkill = false
    #expect(manualSkill.hasAdvancedSettings)

    var conditional = baseline
    conditional.generateWhen = .fieldNotEmpty(fieldID)
    #expect(conditional.hasAdvancedSettings)

    var literal = baseline
    literal.promptSlots[0] = SlotDraft(sourceKind: .literal, literal: "Context")
    #expect(literal.hasAdvancedSettings)

    var concealed = baseline
    concealed.promptSlots[0].reveal = .blurred
    #expect(concealed.hasAdvancedSettings)

    var mediaBehavior = baseline
    mediaBehavior.promptSlots[0].media = .playOnTap
    #expect(mediaBehavior.hasAdvancedSettings)
}

@Test @MainActor func templatesModelSurfacesValidationErrors() async throws {
    let (model, _) = try await makeTemplatesModel()
    await model.load()

    let saved = await model.saveTemplate(
        TemplateDraft(name: "   "),
        editingID: nil
    )

    #expect(saved == false)
    #expect(model.errorMessage == "Enter a name and complete every prompt, answer, and generation rule.")
    #expect(model.selectedItemType?.templates.count == 1)
}

@Test func templateDraftBuildsEveryInteractionAndModelFeature() throws {
    let cue = FieldDef(name: "Cue", type: .text)
    let response = FieldDef(name: "Response", type: .richText)
    let picture = FieldDef(name: "Animation", type: .gif, isRequired: false)
    let cloze = FieldDef(name: "Sentence", type: .cloze)
    let base = try TemplateBuilder.makeRevealTemplate(
        name: "Base",
        promptFieldID: cue.id,
        answerFieldID: response.id,
        in: ItemType(name: "Builder", fields: [cue, response, picture, cloze], templates: [])
    )
    let itemType = ItemType(
        name: "Builder",
        fields: [cue, response, picture, cloze],
        templates: [base]
    )

    for interaction in Interaction.allCases {
        let promptField = interaction == .cloze ? cloze.id : picture.id
        let draft = TemplateDraft(
            name: "\(interaction.rawValue) practice",
            interaction: interaction,
            skill: Skill(input: .diagram, output: .spatial, operation: .apply),
            usesAutomaticSkill: false,
            generateWhen: .all([
                .fieldNotEmpty(cue.id),
                .any([.fieldEmpty(picture.id), .fieldNotEmpty(response.id)]),
            ]),
            promptSlots: [
                SlotDraft(sourceKind: .literal, literal: "Study:"),
                SlotDraft(
                    fieldID: promptField,
                    reveal: interaction == .cloze ? .hiddenUntilAnswer : .blurred,
                    media: interaction == .cloze ? .default : .autoplay
                ),
            ],
            answerSlots: [
                SlotDraft(fieldID: picture.id, reveal: .always, media: .playOnTap),
                SlotDraft(sourceKind: .literal, literal: "Complete"),
            ]
        )

        let template = try draft.template(id: UUID(), in: itemType)
        #expect(template.interaction == interaction)
        #expect(template.skill == Skill(input: .diagram, output: .spatial, operation: .apply))
        #expect(template.prompt.slots.count == 2)
        #expect(template.answer.slots.count == 2)
        #expect(template.prompt.slots[0].source == .literal("Study:"))
        #expect(
            template.prompt.slots[1].presentation.media
                == (interaction == .cloze ? .default : .autoplay)
        )
        #expect(template.generateWhen == .all([
            .fieldNotEmpty(cue.id),
            .any([.fieldEmpty(picture.id), .fieldNotEmpty(response.id)]),
        ]))
    }
}

@Test @MainActor func templatesModelPersistsGeneralTemplate() async throws {
    let (model, store) = try await makeTemplatesModel()
    await model.load()

    let draft = TemplateDraft(
        name: "Typed with context",
        interaction: .type,
        skill: Skill(input: .text, output: .freeResponse, operation: .recall),
        usesAutomaticSkill: false,
        generateWhen: .fieldNotEmpty(BuiltInItemTypes.frontFieldID),
        promptSlots: [
            SlotDraft(sourceKind: .literal, literal: "Answer:"),
            SlotDraft(fieldID: BuiltInItemTypes.frontFieldID, reveal: .blurred),
        ],
        answerSlots: [SlotDraft(fieldID: BuiltInItemTypes.backFieldID)]
    )

    #expect(await model.saveTemplate(draft, editingID: nil))
    let reloaded = try await store.itemType(id: BuiltInItemTypes.basicID)
    let template = try #require(reloaded.templates.first { $0.name == "Typed with context" })
    #expect(template.interaction == .type)
    #expect(template.skill.operation == .recall)
    #expect(template.prompt.slots.map(\.source) == [
        .literal("Answer:"),
        .field(BuiltInItemTypes.frontFieldID),
    ])
    #expect(template.generateWhen == .fieldNotEmpty(BuiltInItemTypes.frontFieldID))
}

@Test func clozeBlankBuilderUsesCurrentSelectionAndRequestedGroup() {
    let text = "Alpha beta gamma"
    let blank = ClozeBlankBuilder.blank(
        text: text,
        selectionStart: 6,
        selectionLength: 4,
        group: 7
    )

    #expect(blank == ClozeSpan(group: 7, start: 6, length: 4))
    let hidden = ClozeValidation.displayText(from: text, blanks: [blank!], revealed: false, group: 7)
    #expect(hidden == "Alpha […] gamma")
}

@Test func clozeBlankBuilderRejectsExtremeOffsetsWithoutTrapping() {
    #expect(ClozeBlankBuilder.blank(
        text: "safe",
        selectionStart: Int.max,
        selectionLength: 1,
        group: 1
    ) == nil)
    #expect(ClozeBlankBuilder.blank(
        text: "safe",
        selectionStart: 1,
        selectionLength: Int.max,
        group: 1
    ) == nil)
}

@Test @MainActor func templatesModelLoadsMultipleItemTypes() async throws {
    let (model, store) = try await makeTemplatesModel()
    let front = FieldDef(name: "Term", type: .text, isRequired: true)
    let back = FieldDef(name: "Definition", type: .text, isRequired: true)
    let extraType = try ItemTypeBuilder.makeItemType(
        name: "Extra",
        fields: [front, back]
    )
    _ = try await store.createItemType(extraType)

    await model.load()

    #expect(model.itemTypes.count == 3)
    #expect(Set(model.itemTypes.map(\.name)) == ["Basic", "Cloze", "Extra"])
}

@Test @MainActor func templatesModelCreatesItemType() async throws {
    let (model, store) = try await makeTemplatesModel()
    await model.load()

    let saved = await model.createItemType(
        ItemTypeDraft(
            name: "Vocabulary",
            fields: [
                FieldDraft(name: "Word", isRequired: true),
                FieldDraft(name: "Meaning", isRequired: true),
            ]
        )
    )

    #expect(saved == true)
    #expect(model.itemTypes.map(\.name).contains("Vocabulary"))
    #expect(model.selectedItemType?.templates.count == 1)
    #expect(model.selectedItemType?.templates.first?.name == "Card")

    let reloaded = try await store.listItemTypes()
    #expect(reloaded.map(\.name).contains("Vocabulary"))
}

@Test @MainActor func templatesModelUpdatesItemTypeFields() async throws {
    let (model, store) = try await makeTemplatesModel()
    await model.load()

    guard let basic = model.selectedItemType else {
        Issue.record("Expected Basic item type.")
        return
    }

    var draft = ItemTypeDraft(itemType: basic)
    draft.fields.append(FieldDraft(name: "Hint", isRequired: false))

    let saved = await model.updateItemType(draft, editingID: basic.id)
    #expect(saved == true)
    #expect(model.selectedItemType?.fields.count == 3)

    let reloaded = try await store.itemType(id: basic.id)
    #expect(reloaded.fields.map(\.name).contains("Hint"))
}

@Test func fieldReorderingSwapsNeighboursAndIgnoresOutOfBounds() {
    let items = ["A", "B", "C"]
    #expect(FieldReordering.move(items, from: 2, by: -1) == ["A", "C", "B"])
    #expect(FieldReordering.move(items, from: 0, by: 1) == ["B", "A", "C"])
    // Out-of-bounds moves are no-ops rather than crashes.
    #expect(FieldReordering.move(items, from: 0, by: -1) == items)
    #expect(FieldReordering.move(items, from: 2, by: 1) == items)
    #expect(FieldReordering.move(items, from: 5, by: -1) == items)
}

@Test @MainActor func templatesModelPersistsReorderedFields() async throws {
    let (model, store) = try await makeTemplatesModel()
    await model.load()

    let created = await model.createItemType(
        ItemTypeDraft(
            name: "Ordered",
            fields: [
                FieldDraft(name: "One", isRequired: true),
                FieldDraft(name: "Two", isRequired: true),
                FieldDraft(name: "Three", isRequired: false),
            ]
        )
    )
    #expect(created)

    guard let itemType = model.itemTypes.first(where: { $0.name == "Ordered" }) else {
        Issue.record("Expected Ordered item type.")
        return
    }
    #expect(itemType.fields.map(\.name) == ["One", "Two", "Three"])

    var draft = ItemTypeDraft(itemType: itemType)
    // Move the last field to the top, mirroring the editor's move-up control.
    draft.fields = FieldReordering.move(draft.fields, from: 2, by: -1)
    draft.fields = FieldReordering.move(draft.fields, from: 1, by: -1)

    #expect(await model.updateItemType(draft, editingID: itemType.id))

    let reloaded = try await store.itemType(id: itemType.id)
    #expect(reloaded.fields.map(\.name) == ["Three", "One", "Two"])
}

@Test @MainActor func templatesModelDeletesUnusedBasicStarter() async throws {
    let (model, store) = try await makeTemplatesModel()
    await model.load()

    #expect(await model.canDeleteSelectedItemType())
    let deleted = await model.deleteSelectedItemType()
    #expect(deleted)
    #expect(model.itemTypes.map(\.id) == [BuiltInItemTypes.clozeID])
    #expect(model.errorMessage == nil)
    #expect(try await store.listItemTypes().map(\.id) == [BuiltInItemTypes.clozeID])
}
