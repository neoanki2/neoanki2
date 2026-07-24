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

    let saved = await model.addItem(fieldText: [
        frontID: "France",
        backID: "Paris",
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

    let saved = await model.addItem(fieldText: [
        BuiltInItemTypes.frontFieldID: "Only front",
    ])

    #expect(saved == false)
    #expect(model.errorMessage == "Back is required.")
    #expect(model.items.isEmpty)
}

@Test @MainActor func itemsModelDeletesItemFromList() async throws {
    let (model, _) = try await makeModel()
    await model.load()

    let saved = await model.addItem(fieldText: [
        BuiltInItemTypes.frontFieldID: "France",
        BuiltInItemTypes.backFieldID: "Paris",
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
