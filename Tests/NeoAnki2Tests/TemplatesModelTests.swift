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
    #expect(model.itemTypes.count == 1)
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

@Test @MainActor func templatesModelSurfacesValidationErrors() async throws {
    let (model, _) = try await makeTemplatesModel()
    await model.load()

    let saved = await model.saveTemplate(
        TemplateDraft(name: "   "),
        editingID: nil
    )

    #expect(saved == false)
    #expect(model.errorMessage == "Enter a name and choose different prompt and answer fields.")
    #expect(model.selectedItemType?.templates.count == 1)
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

    #expect(model.itemTypes.count == 2)
    #expect(Set(model.itemTypes.map(\.name)) == ["Basic", "Extra"])
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

@Test @MainActor func templatesModelBlocksDeletingBuiltInType() async throws {
    let (model, _) = try await makeTemplatesModel()
    await model.load()

    #expect(await model.canDeleteSelectedItemType() == false)
    let deleted = await model.deleteSelectedItemType()
    #expect(deleted == false)
    #expect(model.errorMessage == "Built-in item types can't be deleted.")
}
