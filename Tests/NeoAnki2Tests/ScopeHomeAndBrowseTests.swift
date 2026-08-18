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

/// Reloading a scope must not blank the pane. The counts and the item list are
/// read before either is published, so the detail pane never shows one scope's
/// items beside another's totals, and never shows a progress view instead.
@Test @MainActor func scopeReloadKeepsTheDetailPaneOnScreen() async throws {
    let (model, _, store) = try await makeModels()
    let deck = Deck(name: "Geography")
    _ = try await store.createDeck(deck)
    #expect(model.isLoading)

    await model.load()
    #expect(!model.isLoading)

    _ = await addItem(model, front: "France", back: "Paris", deckID: deck.id)
    let reload = Task { await model.load(scope: .deck(deck.id, name: deck.name)) }
    await Task.yield()
    #expect(!model.isLoading)
    await reload.value

    #expect(model.items.count == 1)
    #expect(model.scopeSummary.dueNow == 1)
}

/// Cards fall due on a schedule, so the headline has to advance on its own.
@Test @MainActor func scopeCountsRefreshWithoutReloading() async throws {
    let (model, _, store) = try await makeModels()
    await model.load()
    #expect(model.scopeSummary.dueNow == 0)

    let itemType = try await store.defaultItemType()
    _ = try await store.createItem(
        Item(
            itemTypeID: itemType.id,
            fields: [
                FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("France")),
                FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Paris")),
            ]
        )
    )

    await model.refreshCounts()

    #expect(model.scopeSummary.dueNow == 1)
    #expect(!model.isLoading)
    // The list is a reload's business; a count refresh only revises counts.
    #expect(model.items.isEmpty)
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
    await model.waitForPendingSearch()
    #expect(model.visibleItems.map(\.title) == ["France"])
    #expect(model.items.count == 2)

    model.searchText = "tokyo"
    await model.waitForPendingSearch()
    #expect(model.visibleItems.map(\.title) == ["Japan"])

    model.searchText = "Ukraine"
    await model.waitForPendingSearch()
    #expect(model.visibleItems.isEmpty)

    model.searchText = ""
    #expect(model.visibleItems.count == 2)
}

@Test func needsAttentionBrowserFilterShowsOnlyItemsWithRepeatedLapses() {
    let itemTypeID = UUID()
    let ordinary = SavedItemSummary(
        id: UUID(),
        itemTypeID: itemTypeID,
        itemTypeName: "Basic",
        title: "Ordinary",
        subtitle: "Answer",
        cardCount: 1,
        createdAt: .now,
        schedule: ItemScheduleSummary(
            dueAt: .now,
            phase: .review,
            lapses: ScopeSummary.leechThreshold - 1
        )
    )
    let affected = SavedItemSummary(
        id: UUID(),
        itemTypeID: itemTypeID,
        itemTypeName: "Basic",
        title: "Needs attention",
        subtitle: "Rewrite me",
        cardCount: 1,
        createdAt: .now,
        schedule: ItemScheduleSummary(
            dueAt: .now,
            phase: .relearning,
            lapses: ScopeSummary.leechThreshold
        )
    )
    let acknowledged = SavedItemSummary(
        id: UUID(),
        itemTypeID: itemTypeID,
        itemTypeName: "Basic",
        title: "Already checked",
        subtitle: "No edit needed",
        cardCount: 1,
        createdAt: .now,
        schedule: ItemScheduleSummary(
            dueAt: .now,
            phase: .review,
            lapses: ScopeSummary.leechThreshold,
            needsAttention: false
        )
    )

    #expect(
        ItemBrowserFilter.needsAttention.apply(to: [ordinary, affected, acknowledged])
            == [affected]
    )
    #expect(
        ItemBrowserFilter.all.apply(to: [ordinary, affected, acknowledged])
            == [ordinary, affected, acknowledged]
    )
}

@Test @MainActor func browseSearchPublishesOnlyTheLatestRapidQuery() async throws {
    let (model, _, _) = try await makeModels()
    await model.load()
    _ = await addItem(model, front: "France", back: "Paris")
    _ = await addItem(model, front: "Japan", back: "Tokyo")

    model.searchText = "france"
    model.searchText = "tokyo"
    await model.waitForPendingSearch()

    #expect(model.searchText == "tokyo")
    #expect(model.visibleItems.map(\.title) == ["Japan"])
    #expect(model.items.count == 2)
}

/// `visibleItems` is cached rather than recomputed on read, so anything that
/// mutates the item list has to invalidate it.
@Test @MainActor func browseSearchResultsTrackItemChanges() async throws {
    let (model, _, _) = try await makeModels()
    await model.load()
    _ = await addItem(model, front: "France", back: "Paris")
    _ = await addItem(model, front: "Francium", back: "Element 87")
    model.searchText = "fran"
    await model.waitForPendingSearch()
    #expect(model.visibleItems.count == 2)

    let doomed = try #require(model.items.first { $0.title == "Francium" }?.id)
    #expect(await model.deleteItem(id: doomed))
    await model.waitForPendingSearch()
    #expect(model.visibleItems.map(\.title) == ["France"])

    _ = await addItem(model, front: "Frankfurt", back: "Germany")
    await model.waitForPendingSearch()
    #expect(model.visibleItems.map(\.title) == ["France", "Frankfurt"])

    model.tableSort = [KeyPathComparator(\.title, order: .reverse)]
    await model.waitForPendingSearch()
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

// MARK: - Cold start

/// A first launch fills the sidebar and the browse list from one snapshot. It
/// has to agree with the counts the ordinary reload path produces, or the app
/// would show one set of totals on launch and another the moment anything moved.
@Test @MainActor func coldSnapshotMatchesTheOrdinaryLoadedLibrary() async throws {
    let (model, decksModel, store) = try await makeModels()
    let deck = Deck(name: "Geography")
    _ = try await store.createDeck(deck)
    await model.load()
    #expect(await addItem(model, front: "France", back: "Paris", deckID: deck.id))
    #expect(await addItem(model, front: "Japan", back: "Tokyo"))
    await decksModel.load()

    let coldItems = ItemsModel(store: store, mediaStore: await store.media)
    let coldDecks = DecksModel(store: store)
    #expect(coldItems.needsInitialLoad)
    #expect(coldDecks.needsInitialLoad)

    let snapshot = try await store.coldLibrarySnapshot(scope: .allDecks)
    coldDecks.applyColdSnapshot(snapshot)
    coldItems.applyColdSnapshot(snapshot, scope: .allDecks)

    #expect(!coldItems.needsInitialLoad)
    #expect(!coldDecks.needsInitialLoad)
    #expect(coldItems.items.map(\.title) == model.items.map(\.title))
    #expect(coldItems.scopeSummary == model.scopeSummary)
    #expect(coldItems.itemTypes.map(\.id) == model.itemTypes.map(\.id))
    #expect(coldDecks.summaries == decksModel.summaries)
    #expect(coldDecks.allDecksDueCount == decksModel.allDecksDueCount)
    #expect(coldDecks.unassignedDueCount == decksModel.unassignedDueCount)
    #expect(coldDecks.unassignedItemCount == decksModel.unassignedItemCount)
    #expect(coldItems.errorMessage == nil)
    #expect(coldDecks.errorMessage == nil)
}

@Test @MainActor func coldHomeSnapshotDefersBrowseRowsWithoutChangingHomeState() async throws {
    let (model, decksModel, store) = try await makeModels()
    let deck = Deck(name: "Geography")
    _ = try await store.createDeck(deck)
    await model.load()
    #expect(await addItem(model, front: "France", back: "Paris", deckID: deck.id))
    #expect(await addItem(model, front: "Japan", back: "Tokyo"))
    await decksModel.load()

    let snapshot = try await store.coldLibraryHomeSnapshot(scope: .allDecks)
    let coldItems = ItemsModel(store: store, mediaStore: await store.media)
    let coldDecks = DecksModel(store: store)
    coldDecks.applyColdHomeSnapshot(snapshot)
    coldItems.applyColdHomeSnapshot(snapshot, scope: .allDecks)

    #expect(!coldItems.needsInitialLoad)
    #expect(coldItems.needsBrowseLoad)
    #expect(coldItems.items.isEmpty)
    #expect(coldItems.scopeSummary == model.scopeSummary)
    #expect(coldItems.itemTypes.map(\.id) == model.itemTypes.map(\.id))
    #expect(coldDecks.summaries == decksModel.summaries)
    #expect(coldDecks.allDecksDueCount == decksModel.allDecksDueCount)
    #expect(coldDecks.unassignedDueCount == decksModel.unassignedDueCount)
    #expect(coldDecks.unassignedItemCount == decksModel.unassignedItemCount)

    coldItems.beginBrowseLoad()
    #expect(coldItems.isLoading)
    await coldItems.load(scope: .allDecks)
    #expect(!coldItems.needsBrowseLoad)
    #expect(coldItems.items.map(\.title) == model.items.map(\.title))
    #expect(coldItems.scopeSummary == model.scopeSummary)
}

@Test @MainActor func coldHomeSnapshotPreservesCorruptItemTypeWarning() async throws {
    let (model, _, _) = try await makeModels()
    let snapshot = ColdLibraryHomeSnapshot(
        itemTypes: ItemTypeLoadResult(
            itemTypes: BuiltInItemTypes.all,
            corruptions: [
                QuarantinedItemTypeDefinition(
                    persistedID: UUID().uuidString,
                    name: "Damaged"
                ),
            ]
        ),
        deckSummaries: [],
        allDecksSummary: .empty,
        unassignedSummary: .empty,
        selectedScopeSummary: .empty
    )

    model.applyColdHomeSnapshot(snapshot, scope: .allDecks)

    #expect(model.errorMessage?.hasPrefix("One damaged item type") == true)
    #expect(!model.needsInitialLoad)
    #expect(model.needsBrowseLoad)
    await model.load(scope: .allDecks)
    #expect(model.errorMessage?.hasPrefix("One damaged item type") == true)
}

@Test @MainActor func populatedBrowseReloadDoesNotReturnToLoadingState() async throws {
    let (model, _, store) = try await makeModels()
    let deck = Deck(name: "Geography")
    _ = try await store.createDeck(deck)
    await model.load()
    #expect(await addItem(model, front: "France", back: "Paris"))
    #expect(!model.items.isEmpty)
    #expect(!model.isLoading)

    let reload = Task { @MainActor in
        await model.load(scope: .deck(deck.id, name: deck.name))
    }
    await Task.yield()

    #expect(!model.isLoading)
    await reload.value
    #expect(!model.isLoading)
}

/// The browse list is projected per item now, so a scoped cold start has to
/// narrow to the selected deck rather than hand back the whole library.
@Test @MainActor func coldSnapshotHonorsTheSelectedDeckScope() async throws {
    let (model, _, store) = try await makeModels()
    let deck = Deck(name: "Geography")
    _ = try await store.createDeck(deck)
    await model.load()
    _ = await addItem(model, front: "France", back: "Paris", deckID: deck.id)
    _ = await addItem(model, front: "Japan", back: "Tokyo")

    let scope = StudyScope.deck(deck.id, name: "Geography")
    let snapshot = try await store.coldLibrarySnapshot(scope: scope.filter)
    let coldItems = ItemsModel(store: store, mediaStore: await store.media)
    coldItems.applyColdSnapshot(snapshot, scope: scope)

    #expect(coldItems.items.map(\.title) == ["France"])
    #expect(coldItems.scopeSummary.itemCount == 1)
    #expect(snapshot.allDecksSummary.itemCount == 2)
    #expect(snapshot.unassignedSummary.itemCount == 1)
}

/// The cold path also runs when only the sidebar is uninitialized, so a browse
/// column the learner already chose has to survive it.
@Test @MainActor func coldSnapshotKeepsTheChosenBrowseOrder() async throws {
    let (model, _, store) = try await makeModels()
    await model.load()
    _ = await addItem(model, front: "Zebra", back: "Stripes")
    _ = await addItem(model, front: "Aardvark", back: "Ants")

    let coldItems = ItemsModel(store: store, mediaStore: await store.media)
    coldItems.tableSort = [KeyPathComparator(\.title, order: .forward)]
    let snapshot = try await store.coldLibrarySnapshot(scope: .allDecks)
    coldItems.applyColdSnapshot(snapshot, scope: .allDecks)

    #expect(coldItems.items.map(\.title) == ["Aardvark", "Zebra"])
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
