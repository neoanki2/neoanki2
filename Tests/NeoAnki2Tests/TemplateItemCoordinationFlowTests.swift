import Foundation
import NeoAnkiCore
import Testing

@testable import NeoAnki2

@Test @MainActor func templateSaveThroughModelsRefreshesItemCardAndDueCounts() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-template-item-flow-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try ItemStore(databaseURL: root.appendingPathComponent("test.sqlite"))
    try await store.bootstrap()
    let itemsModel = ItemsModel(store: store, mediaStore: await store.media)
    let templatesModel = TemplatesModel(store: store)
    await itemsModel.load()
    await templatesModel.load()

    #expect(await itemsModel.addItem(fieldSpans: [
        BuiltInItemTypes.frontFieldID: [Span("France")],
        BuiltInItemTypes.backFieldID: [Span("Paris")],
    ]))
    #expect(itemsModel.items.first?.cardCount == 1)
    #expect(itemsModel.dueCount == 1)

    #expect(await templatesModel.saveTemplate(
        TemplateDraft(
            name: "Reverse",
            promptFieldID: BuiltInItemTypes.backFieldID,
            answerFieldID: BuiltInItemTypes.frontFieldID
        ),
        editingID: nil
    ))
    await itemsModel.load()

    #expect(itemsModel.items.first?.cardCount == 2)
    #expect(itemsModel.dueCount == 2)
}

@Test @MainActor func templateDeleteThroughModelReconcilesExistingItemCards() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-template-delete-flow-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try ItemStore(databaseURL: root.appendingPathComponent("test.sqlite"))
    try await store.bootstrap()
    let itemsModel = ItemsModel(store: store, mediaStore: await store.media)
    let templatesModel = TemplatesModel(store: store)
    await itemsModel.load()
    await templatesModel.load()
    #expect(await itemsModel.addItem(fieldSpans: [
        BuiltInItemTypes.frontFieldID: [Span("France")],
        BuiltInItemTypes.backFieldID: [Span("Paris")],
    ]))
    #expect(await templatesModel.saveTemplate(
        TemplateDraft(
            name: "Reverse",
            promptFieldID: BuiltInItemTypes.backFieldID,
            answerFieldID: BuiltInItemTypes.frontFieldID
        ),
        editingID: nil
    ))
    let reverseID = try #require(
        templatesModel.selectedItemType?.templates.first { $0.name == "Reverse" }?.id
    )

    #expect(await templatesModel.deleteTemplate(id: reverseID))
    await itemsModel.load()

    #expect(templatesModel.selectedItemType?.templates.count == 1)
    #expect(itemsModel.items.first?.cardCount == 1)
    #expect(itemsModel.dueCount == 1)
    let onlyTemplateID = try #require(templatesModel.selectedItemType?.templates.first?.id)
    #expect(await templatesModel.deleteTemplate(id: onlyTemplateID) == false)
    #expect(templatesModel.errorMessage == "An item type must have at least one template.")
}
