import Foundation
import NeoAnkiCore
import Testing

@testable import NeoAnki2

@MainActor
private func makeDecksModel() async throws -> (DecksModel, ItemStore) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-decks-app-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let databaseURL = url.appendingPathComponent("test.sqlite")
    let store = try ItemStore(databaseURL: databaseURL)
    try await store.bootstrap()
    return (DecksModel(store: store), store)
}

@Test @MainActor func decksModelBuildsTreeFromSummaries() async throws {
    let (model, store) = try await makeDecksModel()
    let parent = Deck(name: "Geography")
    let child = Deck(name: "Capitals", parentID: parent.id)
    _ = try await store.createDeck(parent)
    _ = try await store.createDeck(child)

    await model.load()

    #expect(model.deckTree.count == 1)
    #expect(model.deckTree.first?.children.count == 1)
    #expect(model.scopeDueCount == 0)
}

@Test @MainActor func decksModelScopeDueCountFollowsSelection() async throws {
    let (model, store) = try await makeDecksModel()
    let deck = Deck(name: "Geography")
    _ = try await store.createDeck(deck)
    let itemType = try await store.defaultItemType()
    _ = try await store.createItem(
        Item(
            itemTypeID: itemType.id,
            fields: [
                FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Q")),
                FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("A")),
            ],
            deckID: deck.id
        )
    )

    await model.load()
    model.selectedScope = .deck(deck.id)

    #expect(model.scopeDueCount == 1)
    #expect(model.studyScope.label == "Geography")
}
