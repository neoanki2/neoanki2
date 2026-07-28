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

/// The bug this closes: every reload used to raise `isLoading`, so the sidebar
/// blinked into a progress view on each save and each count refresh.
@Test @MainActor func decksModelReloadKeepsTheSidebarOnScreen() async throws {
    let (model, store) = try await makeDecksModel()
    _ = try await store.createDeck(Deck(name: "Geography"))
    #expect(model.isLoading)

    await model.load()
    #expect(!model.isLoading)

    _ = try await store.createDeck(Deck(name: "History"))
    let reload = Task { await model.load() }
    // Yielding lets the reload run up to its first store call, which is past the
    // point where it would have raised `isLoading`.
    await Task.yield()
    #expect(!model.isLoading)
    await reload.value

    #expect(model.deckTree.count == 2)
    #expect(!model.isLoading)
}

/// Counts advance without a reload, because cards fall due while nobody is
/// interacting with the app.
@Test @MainActor func decksModelRefreshesCountsWithoutReloading() async throws {
    let (model, store) = try await makeDecksModel()
    let deck = Deck(name: "Geography")
    _ = try await store.createDeck(deck)
    await model.load()
    #expect(model.summaries.first?.dueCount == 0)

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

    await model.refreshCounts()

    #expect(model.summaries.first?.dueCount == 1)
    #expect(model.allDecksDueCount == 1)
    #expect(!model.isLoading)
}

/// A count refresh before the first load has nothing to revise, and must not
/// populate the sidebar behind `isLoading`'s back.
@Test @MainActor func decksModelCountRefreshWaitsForTheFirstLoad() async throws {
    let (model, store) = try await makeDecksModel()
    _ = try await store.createDeck(Deck(name: "Geography"))

    await model.refreshCounts()

    #expect(model.deckTree.isEmpty)
    #expect(model.isLoading)
}

@Test @MainActor func decksModelLoadOrRefreshPopulatesTheInitialSidebar() async throws {
    let (model, store) = try await makeDecksModel()
    _ = try await store.createDeck(Deck(name: "Geography"))

    await model.loadOrRefresh()

    #expect(model.deckTree.count == 1)
    #expect(model.summaries.first?.name == "Geography")
    #expect(!model.isLoading)
}
