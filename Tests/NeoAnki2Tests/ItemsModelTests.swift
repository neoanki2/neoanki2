import Foundation
import NeoAnkiCore
import Testing

@testable import NeoAnki2

@MainActor
private func makeModel() async throws -> (ItemsModel, ItemStore) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-app-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let databaseURL = url.appendingPathComponent("test.sqlite")
    let store = try ItemStore(databaseURL: databaseURL)
    try await store.bootstrap()
    return (ItemsModel(store: store), store)
}

@Test @MainActor func itemsModelLoadsEmptyLibrary() async throws {
    let (model, _) = try await makeModel()

    await model.load()

    #expect(model.isLoading == false)
    #expect(model.items.isEmpty)
    #expect(model.itemType?.name == "Basic")
    #expect(model.errorMessage == nil)
}

@Test @MainActor func itemsModelAddsItemToList() async throws {
    let (model, store) = try await makeModel()
    await model.load()

    let frontID = BuiltInItemTypes.frontFieldID
    let backID = BuiltInItemTypes.backFieldID

    let saved = await model.addItem(fieldSpans: [
        frontID: [Span("France")],
        backID: [Span("Paris")],
    ])

    #expect(saved == true)
    #expect(model.items.count == 1)
    #expect(model.items.first?.title == "France")
    #expect(model.items.first?.subtitle == "Paris")
    _ = store
}

@Test @MainActor func itemsModelSurfacesValidationErrors() async throws {
    let (model, _) = try await makeModel()
    await model.load()

    let saved = await model.addItem(fieldSpans: [
        BuiltInItemTypes.frontFieldID: [Span("Only front")],
    ])

    #expect(saved == false)
    #expect(model.errorMessage == "Back is required.")
    #expect(model.items.isEmpty)
}

@Test @MainActor func itemsModelPersistsRichTextFields() async throws {
    let (model, store) = try await makeModel()
    await model.load()

    let frontID = BuiltInItemTypes.frontFieldID
    let backID = BuiltInItemTypes.backFieldID
    let richFront = [Span("Q", styles: [.bold]), Span("uestion", styles: [])]

    let saved = await model.addItem(fieldSpans: [
        frontID: richFront,
        backID: [Span("Answer", styles: [.italic])],
    ])

    #expect(saved == true)

    let itemID = try #require(model.items.first?.id)
    let fetched = try await store.fetchItem(id: itemID)
    let item = try #require(fetched?.item)

    #expect(item.value(for: frontID) == .rich(richFront))
    #expect(item.value(for: backID) == .rich([Span("Answer", styles: [.italic])]))
    #expect(model.items.first?.title == "Question")
    #expect(model.items.first?.subtitle == "Answer")
}

@Test @MainActor func itemsModelDeletesItemFromList() async throws {
    let (model, _) = try await makeModel()
    await model.load()

    let saved = await model.addItem(fieldSpans: [
        BuiltInItemTypes.frontFieldID: [Span("France")],
        BuiltInItemTypes.backFieldID: [Span("Paris")],
    ])
    #expect(saved == true)
    #expect(model.items.count == 1)
    #expect(model.dueCount == 1)

    let itemID = try #require(model.items.first?.id)
    let deleted = await model.deleteItem(id: itemID)

    #expect(deleted == true)
    #expect(model.items.isEmpty)
    #expect(model.dueCount == 0)
    #expect(model.errorMessage == nil)
}
