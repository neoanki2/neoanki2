import Foundation
import Testing
@testable import NeoAnkiCore

private func tempDatabaseURL() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-scope-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("test.sqlite")
}

private func makeStore() async throws -> ItemStore {
    let store = try ItemStore(databaseURL: tempDatabaseURL())
    try await store.bootstrap()
    return store
}

private func item(front: String, back: String, deckID: UUID? = nil) -> Item {
    Item(
        itemTypeID: BuiltInItemTypes.basicID,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text(front)),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text(back)),
        ],
        deckID: deckID
    )
}

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
private let laterEpoch = Date(timeIntervalSince1970: 1_700_086_400)

@Test func scopeSummaryRollsUpDescendantDecks() async throws {
    let store = try await makeStore()
    let parent = Deck(name: "Poetry")
    let child = Deck(name: "Sonnets", parentID: parent.id)
    _ = try await store.createDeck(parent)
    _ = try await store.createDeck(child)
    _ = try await store.createItem(item(front: "Ozymandias", back: "Shelley", deckID: parent.id), now: epoch)
    _ = try await store.createItem(
        item(front: "Sonnet 18", back: "Shakespeare", deckID: child.id),
        now: laterEpoch
    )

    let nested = try await store.scopeSummary(
        scope: .deck(parent.id, includeDescendants: true),
        asOf: epoch
    )

    #expect(nested.itemCount == 2)
    #expect(nested.cardCount == 2)
    #expect(nested.dueNow == 1)
    #expect(nested.newCount == 2)
    #expect(nested.inLearningCount == 0)
    #expect(nested.reviewCount == 0)
    #expect(nested.leechCount == 0)
    #expect(nested.nextDueAt == laterEpoch)

    let shallow = try await store.scopeSummary(
        scope: .deck(parent.id, includeDescendants: false),
        asOf: epoch
    )

    #expect(shallow.itemCount == 1)
    #expect(shallow.cardCount == 1)
    #expect(shallow.dueNow == 1)
    #expect(shallow.nextDueAt == nil)
}

@Test func scopeSummarySeparatesUnassignedFromDecks() async throws {
    let store = try await makeStore()
    let deck = Deck(name: "Geography")
    _ = try await store.createDeck(deck)
    _ = try await store.createItem(item(front: "France", back: "Paris", deckID: deck.id), now: epoch)
    _ = try await store.createItem(item(front: "Japan", back: "Tokyo"), now: epoch)

    let unassigned = try await store.scopeSummary(scope: .unassigned, asOf: epoch)
    let all = try await store.scopeSummary(scope: .allDecks, asOf: epoch)

    #expect(unassigned.itemCount == 1)
    #expect(unassigned.dueNow == 1)
    #expect(all.itemCount == 2)
    #expect(all.dueNow == 2)
}

@Test func scopeSummaryMovesCardsOutOfNewAfterReview() async throws {
    let store = try await makeStore()
    _ = try await store.createItem(item(front: "France", back: "Paris"), now: epoch)
    let due = try await store.fetchDueCards(asOf: epoch)
    let card = try #require(due.first?.card)

    _ = try await store.submitReview(cardID: card.id, rating: .good, now: epoch)
    let summary = try await store.scopeSummary(asOf: epoch)

    #expect(summary.cardCount == 1)
    #expect(summary.newCount == 0)
    #expect(summary.inLearningCount + summary.reviewCount == 1)
    #expect(summary.dueNow == 0)
    #expect(summary.nextDueAt != nil)
}

@Test func scopeSummaryOfEmptyScopeReportsNothingScheduled() async throws {
    let store = try await makeStore()
    let deck = Deck(name: "Empty")
    _ = try await store.createDeck(deck)

    let summary = try await store.scopeSummary(
        scope: .deck(deck.id, includeDescendants: true),
        asOf: epoch
    )

    #expect(summary == .empty)
    #expect(!summary.hasItems)
    #expect(!summary.hasDueCards)
}

@Test func listItemsDefaultsToCreationOrder() async throws {
    let store = try await makeStore()
    _ = try await store.createItem(item(front: "First line", back: "Second line"), now: epoch)
    _ = try await store.createItem(
        item(front: "Third line", back: "Fourth line"),
        now: laterEpoch
    )

    let items = try await store.listItems()

    #expect(items.map(\.title) == ["First line", "Third line"])
}

@Test func listItemsSortsNewestFirstOnRequest() async throws {
    let store = try await makeStore()
    _ = try await store.createItem(item(front: "First line", back: "Second line"), now: epoch)
    _ = try await store.createItem(
        item(front: "Third line", back: "Fourth line"),
        now: laterEpoch
    )

    let items = try await store.listItems(sort: .createdDescending)

    #expect(items.map(\.title) == ["Third line", "First line"])
}

@Test func listItemsSortsByTitleAndDueDate() async throws {
    let store = try await makeStore()
    _ = try await store.createItem(item(front: "Zebra", back: "Stripes"), now: epoch)
    _ = try await store.createItem(item(front: "Aardvark", back: "Ants"), now: laterEpoch)

    let byTitle = try await store.listItems(sort: .titleAscending)
    let byDue = try await store.listItems(sort: .dueSoonest)

    #expect(byTitle.map(\.title) == ["Aardvark", "Zebra"])
    #expect(byDue.map(\.title) == ["Zebra", "Aardvark"])
}

@Test func listItemsSearchMatchesPromptAnswerAndType() async throws {
    let store = try await makeStore()
    _ = try await store.createItem(item(front: "France", back: "Paris"), now: epoch)
    _ = try await store.createItem(item(front: "Japan", back: "Tokyo"), now: laterEpoch)

    #expect(try await store.listItems(search: "fra").map(\.title) == ["France"])
    #expect(try await store.listItems(search: "TOKYO").map(\.title) == ["Japan"])
    #expect(try await store.listItems(search: "Basic").count == 2)
    #expect(try await store.listItems(search: "  ").count == 2)
    #expect(try await store.listItems(search: "Ukraine").isEmpty)
}

@Test func savedItemSummaryCarriesScheduleState() async throws {
    let store = try await makeStore()
    let saved = try await store.createItem(item(front: "France", back: "Paris"), now: epoch)

    let schedule = try #require(saved.schedule)
    #expect(schedule.dueAt == epoch)
    #expect(schedule.phase == .new)
    #expect(schedule.lapses == 0)
    #expect(!schedule.isLeech)
    #expect(schedule.isDue(asOf: epoch))

    let listed = try #require(try await store.listItems().first)
    #expect(listed.schedule == schedule)
}

@Test func acknowledgingRepeatedLapsesHidesOnlyTheCurrentWarning() async throws {
    let databaseURL = tempDatabaseURL()
    let store = try ItemStore(databaseURL: databaseURL)
    try await store.bootstrap()
    let created = try await store.createItem(
        item(front: "Difficult", back: "Still valid"),
        now: epoch
    )
    let card = try #require(try await store.fetchDueCards(asOf: epoch).first?.card)
    let database = try SQLiteDatabase(path: databaseURL)

    func memory(lapses: Int) -> MemoryState {
        MemoryState(
            stability: 2,
            difficulty: 8,
            due: epoch,
            lastReview: epoch.addingTimeInterval(-86_400),
            reps: lapses + 2,
            lapses: lapses,
            phase: .review
        )
    }

    try await database.updateCardMemory(
        card.id,
        memory: memory(lapses: ScopeSummary.leechThreshold)
    )

    #expect(try await store.scopeSummary(asOf: epoch).leechCount == 1)
    #expect(try #require(try await store.listItems().first?.schedule).isLeech)

    #expect(try await store.acknowledgeRepeatedLapses(itemIDs: [created.id], asOf: epoch) == 1)
    #expect(try await store.scopeSummary(asOf: epoch).leechCount == 0)
    let acknowledged = try #require(try await store.listItems().first?.schedule)
    #expect(acknowledged.lapses == ScopeSummary.leechThreshold)
    #expect(!acknowledged.isLeech)
    #expect(try await store.acknowledgeRepeatedLapses(itemIDs: [created.id], asOf: epoch) == 0)

    try await database.updateCardMemory(
        card.id,
        memory: memory(lapses: ScopeSummary.leechThreshold + 1)
    )

    #expect(try await store.scopeSummary(asOf: epoch).leechCount == 1)
    #expect(try #require(try await store.listItems().first?.schedule).isLeech)
}

/// Browse rows are projected alongside the items they describe, so every edit
/// that changes a title, a deck, a card count, or a schedule has to reach the
/// projection. A stale row would show a learner text they already replaced.
@Test func browseRowsFollowEveryItemEdit() async throws {
    let store = try await makeStore()
    let first = Deck(name: "Geography")
    let second = Deck(name: "History")
    _ = try await store.createDeck(first)
    _ = try await store.createDeck(second)
    let created = try await store.createItem(
        item(front: "France", back: "Paris", deckID: first.id),
        now: epoch
    )

    var listed = try #require(try await store.listItems().first)
    #expect(listed.title == "France")
    #expect(listed.deckID == first.id)
    #expect(listed.cardCount == 1)

    _ = try await store.updateItem(
        Item(
            id: created.id,
            itemTypeID: BuiltInItemTypes.basicID,
            fields: [
                FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Japan")),
                FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Tokyo")),
            ],
            deckID: first.id
        ),
        now: laterEpoch
    )
    listed = try #require(try await store.listItems().first)
    #expect(listed.title == "Japan")
    #expect(listed.subtitle == "Tokyo")
    #expect(listed.createdAt == epoch)

    #expect(try await store.updateItemDeck(itemID: created.id, deckID: second.id))
    listed = try #require(try await store.listItems().first)
    #expect(listed.deckID == second.id)
    #expect(try await store.listItems(scope: .deck(second.id)).count == 1)
    #expect(try await store.listItems(scope: .deck(first.id)).isEmpty)

    #expect(try await store.updateItemDeck(itemID: created.id, deckID: nil))
    #expect(try await store.listItems(scope: .unassigned).count == 1)

    #expect(try await store.deleteItem(id: created.id))
    #expect(try await store.listItems().isEmpty)
}

/// Grading moves the schedule the browse list reports.
@Test func browseRowsFollowGrading() async throws {
    let store = try await makeStore()
    let created = try await store.createItem(item(front: "France", back: "Paris"), now: epoch)
    let before = try #require(try await store.listItems().first)
    #expect(before.schedule?.phase == .new)

    let due = try #require(try await store.fetchDueCards(asOf: epoch).first)
    _ = try await store.submitReview(cardID: due.card.id, rating: .good, now: epoch)

    let after = try #require(try await store.listItems().first)
    #expect(after.id == created.id)
    #expect(after.schedule?.phase != .new)
    #expect(try #require(after.schedule?.dueAt) > epoch)
}

/// A renamed item type is shown and searched by its new name without touching
/// the items themselves.
@Test func browseRowsFollowItemTypeRenames() async throws {
    let store = try await makeStore()
    _ = try await store.createItem(item(front: "France", back: "Paris"), now: epoch)
    let basic = try #require(try await store.loadItemTypes().itemTypes.first)

    _ = try await store.updateItemType(
        ItemType(
            id: basic.id,
            name: "Capitals",
            fields: basic.fields,
            templates: basic.templates
        ),
        now: laterEpoch
    )

    let listed = try #require(try await store.listItems().first)
    #expect(listed.itemTypeName == "Capitals")
    #expect(try await store.listItems(search: "Capitals").count == 1)
}

@Test func itemBrowsingArrangesWithoutRequery() async throws {
    let store = try await makeStore()
    _ = try await store.createItem(item(front: "Zebra", back: "Stripes"), now: epoch)
    _ = try await store.createItem(item(front: "Aardvark", back: "Ants"), now: laterEpoch)
    let items = try await store.listItems()

    let arranged = ItemBrowsing.arrange(items, sort: .titleAscending, search: "a")

    #expect(arranged.map(\.title) == ["Aardvark", "Zebra"])
    #expect(ItemBrowsing.filter(items, search: "stripes").map(\.title) == ["Zebra"])
}
