import Foundation
import NeoAnkiCore
import Testing

@testable import NeoAnki2

@MainActor
private func makeModels() async throws -> (ItemsModel, DecksModel, ItemStore) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-scope-home-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let store = try ItemStore(databaseURL: url.appendingPathComponent("test.sqlite"))
    try await store.bootstrap()
    let mediaStore = await store.media
    return (ItemsModel(store: store, mediaStore: mediaStore), DecksModel(store: store), store)
}

@MainActor
private func addItem(
    _ model: ItemsModel,
    front: String,
    back: String,
    deckID: UUID? = nil
) async -> Bool {
    await model.addItem(
        fieldSpans: [
            BuiltInItemTypes.frontFieldID: [Span(front)],
            BuiltInItemTypes.backFieldID: [Span(back)],
        ],
        deckID: deckID
    )
}

// MARK: - Scope home

@Test @MainActor func scopeHomeSummaryReportsDueCardsAndStates() async throws {
    let (model, _, _) = try await makeModels()
    await model.load()
    #expect(model.scopeSummary == .empty)

    #expect(await addItem(model, front: "France", back: "Paris"))

    #expect(model.scopeSummary.itemCount == 1)
    #expect(model.scopeSummary.cardCount == 1)
    #expect(model.scopeSummary.dueNow == 1)
    #expect(model.scopeSummary.newCount == 1)
    #expect(model.scopeSummary.hasDueCards)
    #expect(model.dueCount == 1)
}

@Test @MainActor func scopeSummaryFollowsTheSelectedScope() async throws {
    let (model, _, store) = try await makeModels()
    let deck = Deck(name: "Geography")
    _ = try await store.createDeck(deck)
    await model.load()
    _ = await addItem(model, front: "France", back: "Paris", deckID: deck.id)
    _ = await addItem(model, front: "Japan", back: "Tokyo")

    await model.load(scope: .deck(deck.id, name: "Geography"))
    #expect(model.scopeSummary.itemCount == 1)
    #expect(model.scopeSummary.dueNow == 1)

    await model.load(scope: .unassigned)
    #expect(model.scopeSummary.itemCount == 1)

    await model.load(scope: .allDecks)
    #expect(model.scopeSummary.itemCount == 2)
    #expect(model.scopeSummary.dueNow == 2)
}

@Test @MainActor func scopeHomeSummaryReportsNewCardsDeferredByLimit() async throws {
    let (model, _, store) = try await makeModels()
    let deck = Deck(name: "Paused", newCardsPerDay: 0)
    _ = try await store.createDeck(deck)
    await model.load(scope: .deck(deck.id, name: deck.name))

    #expect(await addItem(model, front: "France", back: "Paris", deckID: deck.id))
    #expect(model.scopeSummary.dueNow == 0)
    #expect(model.scopeSummary.newCount == 1)
    #expect(model.scopeSummary.availableNewCount == 0)
    #expect(model.scopeSummary.hiddenNewCount == 1)
    #expect(model.scopeSummary.nextNewCardsAt != nil)
}

/// The bug this closes: adding an item inside a deck used to refresh the summary
/// against every deck, so the scope home reported counts from another scope.
@Test @MainActor func addingAnItemRefreshesTheLoadedScopeOnly() async throws {
    let (model, _, store) = try await makeModels()
    let deck = Deck(name: "Geography")
    _ = try await store.createDeck(deck)
    await model.load()
    _ = await addItem(model, front: "Japan", back: "Tokyo")

    await model.load(scope: .deck(deck.id, name: "Geography"))
    _ = await addItem(model, front: "France", back: "Paris", deckID: deck.id)

    #expect(model.scopeSummary.itemCount == 1)
    #expect(model.items.count == 1)
}

@Test @MainActor func scopeSummaryDropsToEmptyAfterDeletingEverything() async throws {
    let (model, _, _) = try await makeModels()
    await model.load()
    _ = await addItem(model, front: "France", back: "Paris")
    let id = try #require(model.items.first?.id)

    #expect(await model.deleteItem(id: id))

    #expect(model.scopeSummary == .empty)
    #expect(!model.scopeSummary.hasItems)
}

// MARK: - Browse

@Test @MainActor func browseSearchFiltersVisibleItemsWithoutDroppingThem() async throws {
    let (model, _, _) = try await makeModels()
    await model.load()
    _ = await addItem(model, front: "France", back: "Paris")
    _ = await addItem(model, front: "Japan", back: "Tokyo")

    model.searchText = "fra"
    #expect(model.visibleItems.map(\.title) == ["France"])
    #expect(model.items.count == 2)

    model.searchText = "tokyo"
    #expect(model.visibleItems.map(\.title) == ["Japan"])

    model.searchText = "Ukraine"
    #expect(model.visibleItems.isEmpty)

    model.searchText = ""
    #expect(model.visibleItems.count == 2)
}

/// `visibleItems` is cached rather than recomputed on read, so anything that
/// mutates the item list has to invalidate it.
@Test @MainActor func browseSearchResultsTrackItemChanges() async throws {
    let (model, _, _) = try await makeModels()
    await model.load()
    _ = await addItem(model, front: "France", back: "Paris")
    _ = await addItem(model, front: "Francium", back: "Element 87")
    model.searchText = "fran"
    #expect(model.visibleItems.count == 2)

    let doomed = try #require(model.items.first { $0.title == "Francium" }?.id)
    #expect(await model.deleteItem(id: doomed))
    #expect(model.visibleItems.map(\.title) == ["France"])

    _ = await addItem(model, front: "Frankfurt", back: "Germany")
    #expect(model.visibleItems.map(\.title) == ["France", "Frankfurt"])

    model.tableSort = [KeyPathComparator(\.title, order: .reverse)]
    #expect(model.visibleItems.map(\.title) == ["Frankfurt", "France"])
}

@Test @MainActor func browseLoadsInCreationOrder() async throws {
    let (model, _, _) = try await makeModels()
    await model.load()
    _ = await addItem(model, front: "First line", back: "A")
    _ = await addItem(model, front: "Second line", back: "B")

    await model.load()

    #expect(model.items.map(\.title) == ["First line", "Second line"])
}

@Test @MainActor func browseTableSortReordersLoadedItems() async throws {
    let (model, _, _) = try await makeModels()
    await model.load()
    _ = await addItem(model, front: "Zebra", back: "Stripes")
    _ = await addItem(model, front: "Aardvark", back: "Ants")

    model.tableSort = [KeyPathComparator(\.title, order: .forward)]
    #expect(model.items.map(\.title) == ["Aardvark", "Zebra"])

    model.tableSort = [KeyPathComparator(\.title, order: .reverse)]
    #expect(model.items.map(\.title) == ["Zebra", "Aardvark"])

    model.tableSort = [KeyPathComparator(\.createdAt, order: .forward)]
    #expect(model.items.map(\.title) == ["Zebra", "Aardvark"])
}

@Test @MainActor func browseSortIsPreservedAcrossReloads() async throws {
    let (model, _, _) = try await makeModels()
    await model.load()
    _ = await addItem(model, front: "Zebra", back: "Stripes")
    _ = await addItem(model, front: "Aardvark", back: "Ants")
    model.tableSort = [KeyPathComparator(\.title, order: .forward)]

    await model.load()

    #expect(model.items.map(\.title) == ["Aardvark", "Zebra"])
}

@Test @MainActor func browseBulkMoveMovesEverySelectedItem() async throws {
    let (model, _, store) = try await makeModels()
    let deck = Deck(name: "Geography")
    _ = try await store.createDeck(deck)
    await model.load()
    _ = await addItem(model, front: "France", back: "Paris")
    _ = await addItem(model, front: "Japan", back: "Tokyo")
    let ids = Set(model.items.map(\.id))

    let moved = await model.moveItems(ids: ids, to: deck.id)

    #expect(moved == 2)
    let inDeck = try await store.listItems(scope: .deck(deck.id, includeDescendants: false))
    #expect(inDeck.count == 2)
    #expect(model.scopeSummary.itemCount == 2)
}

@Test @MainActor func browseBulkMoveReportsPartialSuccess() async throws {
    let (model, _, _) = try await makeModels()
    await model.load()
    _ = await addItem(model, front: "France", back: "Paris")
    let existing = try #require(model.items.first?.id)

    let moved = await model.moveItems(ids: [existing, UUID()], to: nil)

    #expect(moved == 1)
    #expect(model.errorMessage == nil)
}

@Test @MainActor func browseBulkDeleteRemovesSelectionAndRefreshesSummary() async throws {
    let (model, _, _) = try await makeModels()
    await model.load()
    _ = await addItem(model, front: "France", back: "Paris")
    _ = await addItem(model, front: "Japan", back: "Tokyo")
    _ = await addItem(model, front: "Peru", back: "Lima")
    let doomed = Set(model.items.prefix(2).map(\.id))

    let deleted = await model.deleteItems(ids: doomed)

    #expect(deleted == 2)
    #expect(model.items.map(\.title) == ["Peru"])
    #expect(model.scopeSummary.itemCount == 1)
    #expect(model.scopeSummary.dueNow == 1)
}

// MARK: - Table sort keys

@Test @MainActor func browseSortKeysKeepUnscheduledItemsTogether() async throws {
    let scheduled = SavedItemSummary(
        id: UUID(),
        itemTypeID: BuiltInItemTypes.basicID,
        itemTypeName: "Basic",
        title: "Scheduled",
        subtitle: "Answer",
        cardCount: 1,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        schedule: ItemScheduleSummary(
            dueAt: Date(timeIntervalSince1970: 1_700_000_000),
            phase: .review,
            lapses: 9
        )
    )
    let unscheduled = SavedItemSummary(
        id: UUID(),
        itemTypeID: BuiltInItemTypes.basicID,
        itemTypeName: "Basic",
        title: "Unscheduled",
        subtitle: "Answer",
        cardCount: 0,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    #expect(scheduled.dueSortKey == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(unscheduled.dueSortKey == .distantFuture)
    #expect(scheduled.phaseSortKey == 3)
    #expect(unscheduled.phaseSortKey == 4)
    #expect(scheduled.lapseSortKey == 9)
    #expect(unscheduled.lapseSortKey == 0)
    #expect(scheduled.schedule?.isLeech == true)
}
