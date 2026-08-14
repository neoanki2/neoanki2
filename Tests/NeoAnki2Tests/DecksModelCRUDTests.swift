import Foundation
import NeoAnkiCore
import Testing

@testable import NeoAnki2

@MainActor
private func makeDecksModel() async throws -> (DecksModel, ItemStore) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-decks-crud-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let databaseURL = url.appendingPathComponent("test.sqlite")
    let store = try ItemStore(databaseURL: databaseURL)
    try await store.bootstrap()
    return (DecksModel(store: store), store)
}

@Test @MainActor func decksModelCreatesDeckAndSelectsIt() async throws {
    let (model, _) = try await makeDecksModel()
    await model.load()

    let deck = await model.createDeck(name: "Geography")
    #expect(deck?.name == "Geography")
    #expect(model.selectedScope == .deck(try #require(deck?.id)))
    #expect(model.deckTree.count == 1)
}

@Test @MainActor func decksModelCreatesSubdeck() async throws {
    let (model, store) = try await makeDecksModel()
    let parent = Deck(name: "Languages")
    _ = try await store.createDeck(parent)
    await model.load()

    let child = await model.createDeck(name: "French", parentID: parent.id)
    #expect(child?.parentID == parent.id)
    #expect(model.deckTree.first?.children.count == 1)
}

@Test @MainActor func decksModelRenamesDeck() async throws {
    let (model, store) = try await makeDecksModel()
    let deck = Deck(name: "Old Name")
    _ = try await store.createDeck(deck)
    await model.load()

    let renamed = await model.renameDeck(id: deck.id, name: "New Name")
    #expect(renamed == true)
    #expect(model.deckName(for: deck.id) == "New Name")
}

@Test @MainActor func decksModelUpdatesDailyNewCardLimit() async throws {
    let (model, store) = try await makeDecksModel()
    let deck = Deck(name: "Geography")
    _ = try await store.createDeck(deck)
    await model.load()

    #expect(await model.updateNewCardsPerDay(id: deck.id, limit: 12))
    #expect(try await store.deck(id: deck.id).newCardsPerDay == 12)
    #expect(model.summaries.first?.newCardsPerDay == 12)

    #expect(await model.updateNewCardsPerDay(id: deck.id, limit: nil))
    #expect(try await store.deck(id: deck.id).newCardsPerDay == nil)
}

@Test @MainActor func decksModelRejectsEmptyRename() async throws {
    let (model, store) = try await makeDecksModel()
    let deck = Deck(name: "Valid")
    _ = try await store.createDeck(deck)
    await model.load()

    let renamed = await model.renameDeck(id: deck.id, name: "   ")
    #expect(renamed == false)
    #expect(model.errorMessage == "Deck name can't be empty.")
}

@Test @MainActor func decksModelDeletesDeckAndResetsSelection() async throws {
    let (model, store) = try await makeDecksModel()
    let deck = Deck(name: "Temporary")
    _ = try await store.createDeck(deck)
    await model.load()
    model.selectedScope = .deck(deck.id)

    let deleted = await model.deleteDeck(id: deck.id)
    #expect(deleted == true)
    #expect(model.selectedScope == .allDecks)
    #expect(model.deckTree.isEmpty)
}

@Test @MainActor func decksModelRejectsEmptyCreate() async throws {
    let (model, _) = try await makeDecksModel()
    await model.load()

    let deck = await model.createDeck(name: "  ")
    #expect(deck == nil)
    #expect(model.errorMessage == "Deck name can't be empty.")
}

@Test @MainActor func decksModelDeletesSubdeckSelectionWhenParentRemoved() async throws {
    let (model, store) = try await makeDecksModel()
    let parent = Deck(name: "Parent")
    let child = Deck(name: "Child", parentID: parent.id)
    _ = try await store.createDeck(parent)
    _ = try await store.createDeck(child)
    await model.load()
    model.selectedScope = .deck(child.id)

    let deleted = await model.deleteDeck(id: parent.id)
    #expect(deleted == true)
    #expect(model.selectedScope == .allDecks)
    #expect(model.deckTree.isEmpty)
}

@Test @MainActor func decksModelResetsProgressAndRefreshesCounts() async throws {
    let (model, store) = try await makeDecksModel()
    let deck = Deck(name: "Geography")
    _ = try await store.createDeck(deck)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let item = Item(
        itemTypeID: BuiltInItemTypes.basicID,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("France")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Paris")),
        ],
        deckID: deck.id
    )
    _ = try await store.createItem(item, now: now)
    let card = try #require(
        try await store.fetchDueCards(
            scope: .deck(deck.id, includeDescendants: false),
            asOf: now
        ).first
    )
    _ = try await store.submitReview(cardID: card.id, rating: .good, now: now)
    await model.load(asOf: now.addingTimeInterval(1))
    #expect(model.summaries.first?.dueCount == 0)

    let resetAt = now.addingTimeInterval(2)
    #expect(await model.resetProgress(id: deck.id, now: resetAt) == 1)
    #expect(model.summaries.first?.dueCount == 1)
    #expect(try await store.rawReviewLogCount(for: card.id) == 0)
}

@Test @MainActor func decksModelClearsSelectionWhenDeckRemovedExternally() async throws {
    let (model, store) = try await makeDecksModel()
    let deck = Deck(name: "Gone")
    _ = try await store.createDeck(deck)
    await model.load()
    model.selectedScope = .deck(deck.id)

    _ = try await store.deleteDeck(id: deck.id)
    await model.load()

    #expect(model.selectedScope == .allDecks)
}

@Test func sidebarCaptionOnlySaysNoItemsWhenThereAreNone() {
    #expect(SidebarScopeCaption.text(itemCount: 0, dueCount: 0) == "No items")
    #expect(SidebarScopeCaption.text(itemCount: 11, dueCount: 0) == "11 items")
    #expect(SidebarScopeCaption.text(itemCount: 11, dueCount: 4) == "11 items · 4 due")
}

@Test func sidebarCaptionAgreesWithItselfAboutOne() {
    #expect(SidebarScopeCaption.text(itemCount: 1, dueCount: 0) == "1 item")
    #expect(SidebarScopeCaption.text(itemCount: 1, dueCount: 1) == "1 item · 1 due")
}

@Test func compactSidebarCaptionPrioritizesDueWork() {
    #expect(SidebarScopeCaption.compactText(itemCount: 266, dueCount: 73) == "73 due")
    #expect(SidebarScopeCaption.compactText(itemCount: 26, dueCount: 0) == "26 items")
    #expect(SidebarScopeCaption.compactText(itemCount: 1, dueCount: 0) == "1 item")
    #expect(SidebarScopeCaption.compactText(itemCount: 0, dueCount: 0) == "Empty")
}
