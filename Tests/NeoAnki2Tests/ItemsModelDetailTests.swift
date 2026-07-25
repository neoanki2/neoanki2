import Foundation
import NeoAnkiCore
import Testing

@testable import NeoAnki2

@MainActor
private func makeItemsModel() async throws -> (ItemsModel, ItemStore) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-items-detail-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let databaseURL = url.appendingPathComponent("test.sqlite")
    let store = try ItemStore(databaseURL: databaseURL)
    try await store.bootstrap()
    let mediaStore = await store.media
    return (ItemsModel(store: store, mediaStore: mediaStore), store)
}

@Test @MainActor func itemsModelMoveItemUpdatesDeck() async throws {
    let (model, store) = try await makeItemsModel()
    let deckA = Deck(name: "A")
    let deckB = Deck(name: "B")
    _ = try await store.createDeck(deckA)
    _ = try await store.createDeck(deckB)
    await model.load()

    _ = await model.addItem(fieldSpans: [
        BuiltInItemTypes.frontFieldID: [Span("Q")],
        BuiltInItemTypes.backFieldID: [Span("A")],
    ], deckID: deckA.id)

    let itemID = try #require(model.items.first?.id)
    let moved = await model.moveItem(id: itemID, to: deckB.id)
    #expect(moved == true)

    let fetched = try await store.fetchItem(id: itemID)
    #expect(fetched?.item.deckID == deckB.id)
}

@Test @MainActor func itemsModelMoveItemToUnassigned() async throws {
    let (model, store) = try await makeItemsModel()
    let deck = Deck(name: "Deck")
    _ = try await store.createDeck(deck)
    await model.load()

    _ = await model.addItem(fieldSpans: [
        BuiltInItemTypes.frontFieldID: [Span("Q")],
        BuiltInItemTypes.backFieldID: [Span("A")],
    ], deckID: deck.id)

    let itemID = try #require(model.items.first?.id)
    let moved = await model.moveItem(id: itemID, to: nil)
    #expect(moved == true)

    let fetched = try await store.fetchItem(id: itemID)
    #expect(fetched?.item.deckID == nil)
}

@Test @MainActor func itemsModelDeleteItemReturnsFalseForMissing() async throws {
    let (model, _) = try await makeItemsModel()
    await model.load()

    let deleted = await model.deleteItem(id: UUID())
    #expect(deleted == false)
}

@Test @MainActor func itemsModelMoveItemReturnsFalseForMissing() async throws {
    let (model, _) = try await makeItemsModel()
    await model.load()

    let moved = await model.moveItem(id: UUID(), to: nil)
    #expect(moved == false)
}

@Test @MainActor func itemsModelScopedLoadFiltersItems() async throws {
    let (model, store) = try await makeItemsModel()
    let deck = Deck(name: "Scoped")
    _ = try await store.createDeck(deck)
    await model.load()

    _ = await model.addItem(fieldSpans: [
        BuiltInItemTypes.frontFieldID: [Span("In Deck")],
        BuiltInItemTypes.backFieldID: [Span("A")],
    ], deckID: deck.id)
    _ = await model.addItem(fieldSpans: [
        BuiltInItemTypes.frontFieldID: [Span("Unassigned")],
        BuiltInItemTypes.backFieldID: [Span("B")],
    ])

    await model.load(scope: .deck(deck.id, name: "Scoped"))
    #expect(model.items.count == 1)
    #expect(model.items.first?.title == "In Deck")
}
