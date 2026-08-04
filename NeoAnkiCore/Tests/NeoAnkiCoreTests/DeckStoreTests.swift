import Foundation
import Testing
@testable import NeoAnkiCore

private func tempDatabaseURL() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-deck-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("test.sqlite")
}

private func makeStore() async throws -> ItemStore {
    let store = try ItemStore(databaseURL: tempDatabaseURL())
    try await store.bootstrap()
    return store
}

private func basicItem(deckID: UUID? = nil) -> Item {
    Item(
        itemTypeID: BuiltInItemTypes.basicID,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("France")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Paris")),
        ],
        deckID: deckID
    )
}

@Test func listDecksReturnsCreatedDecks() async throws {
    let store = try await makeStore()
    let deck = Deck(name: "Geography")
    _ = try await store.createDeck(deck)

    let decks = try await store.listDecks()

    #expect(decks.count == 1)
    #expect(decks.first?.name == "Geography")
}

@Test func deckSummariesIncludeCounts() async throws {
    let store = try await makeStore()
    let deck = Deck(name: "Geography")
    _ = try await store.createDeck(deck)
    _ = try await store.createItem(basicItem(deckID: deck.id))

    let summaries = try await store.deckSummaries()

    #expect(summaries.count == 1)
    #expect(summaries.first?.itemCount == 1)
    #expect(summaries.first?.dueCount == 1)
}

/// A parent whose items all live in subdecks is not empty. Selecting it studies
/// and browses the whole subtree, so its counts have to span the subtree too.
@Test func deckSummariesCountItemsAcrossDescendants() async throws {
    let store = try await makeStore()
    let parent = Deck(name: "Ліна")
    let child = Deck(name: "Спини мене", parentID: parent.id)
    let grandchild = Deck(name: "Строфа", parentID: child.id)
    _ = try await store.createDeck(parent)
    _ = try await store.createDeck(child)
    _ = try await store.createDeck(grandchild)
    _ = try await store.createItem(basicItem(deckID: child.id))
    _ = try await store.createItem(basicItem(deckID: grandchild.id))

    let summaries = try await store.deckSummaries()

    #expect(summaries.first { $0.id == parent.id }?.itemCount == 2)
    #expect(summaries.first { $0.id == child.id }?.itemCount == 2)
    #expect(summaries.first { $0.id == grandchild.id }?.itemCount == 1)
}

/// A leaf with nothing in it still reports zero, so "no items" keeps meaning it.
@Test func deckSummariesReportZeroForATrulyEmptyDeck() async throws {
    let store = try await makeStore()
    let deck = Deck(name: "Unused")
    _ = try await store.createDeck(deck)

    let summaries = try await store.deckSummaries()

    #expect(summaries.first?.itemCount == 0)
    #expect(summaries.first?.dueCount == 0)
}

@Test func deckSummaryDueCountMatchesScopeSummary() async throws {
    let store = try await makeStore()
    let deck = Deck(name: "Mixed", newCardsPerDay: 5)
    _ = try await store.createDeck(deck)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    for _ in 1 ... 3 {
        _ = try await store.createItem(basicItem(deckID: deck.id), now: now)
    }

    let summaries = try await store.deckSummaries(asOf: now)
    let scopeSummary = try await store.scopeSummary(
        scope: .deck(deck.id, includeDescendants: true),
        asOf: now
    )

    #expect(summaries.first?.dueCount == scopeSummary.dueNow)
    #expect(scopeSummary.dueNow == 3)
}

@Test func updateDeckRenamesDeck() async throws {
    let store = try await makeStore()
    var deck = Deck(name: "Geography")
    _ = try await store.createDeck(deck)
    deck.name = "World Geography"
    _ = try await store.updateDeck(deck)

    let loaded = try await store.deck(id: deck.id)
    #expect(loaded.name == "World Geography")
}

@Test func updateDeckRejectsCycle() async throws {
    let store = try await makeStore()
    let parent = Deck(name: "Geography")
    let child = Deck(name: "Capitals", parentID: parent.id)
    _ = try await store.createDeck(parent)
    _ = try await store.createDeck(child)

    var reparentedParent = parent
    reparentedParent.parentID = child.id

    await #expect(throws: DatabaseError.invalidDeck("A deck can't be moved inside itself.")) {
        try await store.updateDeck(reparentedParent)
    }
}

@Test func deleteDeckRemovesItemsInDeck() async throws {
    let store = try await makeStore()
    let parent = Deck(name: "Geography")
    let child = Deck(name: "Capitals", parentID: parent.id)
    _ = try await store.createDeck(parent)
    _ = try await store.createDeck(child)

    let item = basicItem(deckID: child.id)
    _ = try await store.createItem(item)

    #expect(try await store.deleteDeck(id: child.id) == true)

    #expect(try await store.fetchItem(id: item.id) == nil)
    #expect(try await store.listItems(scope: .allDecks).isEmpty)
}

@Test func deleteDeckRemovesSubdecksAndNestedItems() async throws {
    let store = try await makeStore()
    let parent = Deck(name: "Languages")
    let child = Deck(name: "French", parentID: parent.id)
    _ = try await store.createDeck(parent)
    _ = try await store.createDeck(child)

    let parentItem = basicItem(deckID: parent.id)
    let childItem = basicItem(deckID: child.id)
    _ = try await store.createItem(parentItem)
    _ = try await store.createItem(childItem)

    #expect(try await store.deleteDeck(id: parent.id) == true)

    #expect(try await store.listDecks().isEmpty)
    #expect(try await store.fetchItem(id: parentItem.id) == nil)
    #expect(try await store.fetchItem(id: childItem.id) == nil)
}

@Test func resetDeckProgressClearsSubtreeHistoryAndKeepsOtherDecks() async throws {
    let store = try await makeStore()
    let parent = Deck(name: "Languages", newCardsPerDay: 2)
    let child = Deck(name: "French", parentID: parent.id)
    let other = Deck(name: "Geography")
    _ = try await store.createDeck(parent)
    _ = try await store.createDeck(child)
    _ = try await store.createDeck(other)

    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let parentItem = basicItem(deckID: parent.id)
    let childItem = basicItem(deckID: child.id)
    let otherItem = basicItem(deckID: other.id)
    _ = try await store.createItem(parentItem, now: start)
    _ = try await store.createItem(childItem, now: start)
    _ = try await store.createItem(otherItem, now: start)

    let parentCard = try #require(
        try await store.fetchDueCards(
            scope: .deck(parent.id, includeDescendants: false),
            asOf: start
        ).first
    )
    let childCard = try #require(
        try await store.fetchDueCards(
            scope: .deck(child.id, includeDescendants: false),
            asOf: start
        ).first
    )
    let otherCard = try #require(
        try await store.fetchDueCards(
            scope: .deck(other.id, includeDescendants: false),
            asOf: start
        ).first
    )

    _ = try await store.submitReviewWithReceipt(
        cardID: parentCard.id,
        rating: .good,
        now: start
    )
    let revertedReview = try await store.submitReviewWithReceipt(
        cardID: parentCard.id,
        rating: .again,
        now: start.addingTimeInterval(10)
    )
    try await store.revertReview(
        reviewLogID: revertedReview.reviewLogID,
        now: start.addingTimeInterval(20)
    )
    _ = try await store.submitReview(cardID: childCard.id, rating: .good, now: start)
    _ = try await store.submitReview(cardID: otherCard.id, rating: .good, now: start)

    #expect(try await store.rawReviewLogCount(for: parentCard.id) == 2)
    #expect(try await store.rawReviewLogCount(for: childCard.id) == 1)
    #expect(try await store.rawReviewLogCount(for: otherCard.id) == 1)

    let resetAt = start.addingTimeInterval(30)
    #expect(try await store.resetDeckProgress(id: parent.id, now: resetAt) == 2)

    let resetCards = try await store.fetchDueCards(
        scope: .deck(parent.id, includeDescendants: true),
        asOf: resetAt
    )
    #expect(resetCards.count == 2)
    #expect(resetCards.map(\.item.id) == [parentItem.id, childItem.id])
    #expect(resetCards.allSatisfy { $0.card.memory.phase == .new })
    #expect(resetCards.allSatisfy { $0.card.memory.due < resetAt })
    #expect(resetCards[0].card.memory.due < resetCards[1].card.memory.due)
    #expect(try await store.rawReviewLogCount(for: parentCard.id) == 0)
    #expect(try await store.rawReviewLogCount(for: childCard.id) == 0)
    #expect(try await store.rawReviewLogCount(for: otherCard.id) == 1)
    #expect(try await store.fetchItem(id: parentItem.id) != nil)
    #expect(try await store.fetchItem(id: childItem.id) != nil)
    #expect(try await store.deck(id: parent.id).newCardsPerDay == 2)

    let otherAfterReset = try #require(
        try await store.fetchDueCards(
            scope: .deck(other.id, includeDescendants: false),
            asOf: resetAt.addingTimeInterval(10 * 86_400)
        ).first
    )
    #expect(otherAfterReset.card.memory.phase == .review)
}

@Test func resetDeckProgressRejectsMissingDeck() async throws {
    let store = try await makeStore()
    let missingID = UUID()

    await #expect(throws: DatabaseError.deckNotFound(missingID)) {
        try await store.resetDeckProgress(id: missingID)
    }
}

@Test func deleteRootDeckRemovesItems() async throws {
    let store = try await makeStore()
    let deck = Deck(name: "Geography")
    _ = try await store.createDeck(deck)
    let item = basicItem(deckID: deck.id)
    _ = try await store.createItem(item)

    #expect(try await store.deleteDeck(id: deck.id) == true)

    #expect(try await store.fetchItem(id: item.id) == nil)
    #expect(try await store.listItems(scope: .unassigned).isEmpty)
}

@Test func deleteAllUnassignedItemsRemovesOnlyUnassigned() async throws {
    let store = try await makeStore()
    let deck = Deck(name: "Geography")
    _ = try await store.createDeck(deck)
    _ = try await store.createItem(basicItem(deckID: deck.id))
    _ = try await store.createItem(basicItem())

    #expect(try await store.deleteAllUnassignedItems() == 1)
    #expect(try await store.listItems(scope: .unassigned).isEmpty)
    #expect(try await store.listItems(scope: .deck(deck.id, includeDescendants: false)).count == 1)
}

@Test func updateItemDeckSyncsCards() async throws {
    let store = try await makeStore()
    let deckA = Deck(name: "Geography")
    let deckB = Deck(name: "History")
    _ = try await store.createDeck(deckA)
    _ = try await store.createDeck(deckB)

    let item = basicItem(deckID: deckA.id)
    _ = try await store.createItem(item)

    #expect(try await store.updateItemDeck(itemID: item.id, deckID: deckB.id) == true)

    let dueInB = try await store.fetchDueCards(scope: .deck(deckB.id, includeDescendants: false))
    #expect(dueInB.count == 1)
    #expect(dueInB.first?.card.deckID == deckB.id)

    let dueInA = try await store.fetchDueCards(scope: .deck(deckA.id, includeDescendants: false))
    #expect(dueInA.isEmpty)
}

@Test func scopedDueCardsExcludeOtherDecks() async throws {
    let store = try await makeStore()
    let deckA = Deck(name: "Geography")
    let deckB = Deck(name: "History")
    _ = try await store.createDeck(deckA)
    _ = try await store.createDeck(deckB)
    _ = try await store.createItem(basicItem(deckID: deckA.id))
    _ = try await store.createItem(basicItem(deckID: deckB.id))

    let dueA = try await store.fetchDueCards(scope: .deck(deckA.id, includeDescendants: false))
    #expect(dueA.count == 1)
    #expect(dueA.first?.card.deckID == deckA.id)
}

@Test func descendantInclusiveStudyIncludesNestedDeckCards() async throws {
    let store = try await makeStore()
    let parent = Deck(name: "Geography")
    let child = Deck(name: "Capitals", parentID: parent.id)
    _ = try await store.createDeck(parent)
    _ = try await store.createDeck(child)
    _ = try await store.createItem(basicItem(deckID: child.id))

    let due = try await store.fetchDueCards(scope: .deck(parent.id, includeDescendants: true))
    #expect(due.count == 1)
}

@Test func listItemsFiltersByScope() async throws {
    let store = try await makeStore()
    let deck = Deck(name: "Geography")
    _ = try await store.createDeck(deck)
    _ = try await store.createItem(basicItem(deckID: deck.id))
    _ = try await store.createItem(basicItem())

    #expect(try await store.listItems(scope: .allDecks).count == 2)
    #expect(try await store.listItems(scope: .deck(deck.id, includeDescendants: false)).count == 1)
    #expect(try await store.listItems(scope: .unassigned).count == 1)
}

@Test func createItemRejectsMissingDeck() async throws {
    let store = try await makeStore()
    let item = basicItem(deckID: UUID())

    await #expect(throws: DatabaseError.self) {
        try await store.createItem(item)
    }
}
