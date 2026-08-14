import Foundation
import SQLite3
import Testing
@testable import NeoAnkiCore

private func changeTrackingDatabaseURL() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-change-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("library.sqlite")
}

private func changeTrackingStore(at url: URL = changeTrackingDatabaseURL()) async throws -> ItemStore {
    let store = try ItemStore(databaseURL: url)
    try await store.bootstrap()
    return store
}

private func trackedBasicItem(deckID: UUID? = nil) -> Item {
    Item(
        itemTypeID: BuiltInItemTypes.basicID,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Question")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
        ],
        deckID: deckID
    )
}

@Test func singleResourceWritesCreateDurableRevisionsAndEvents() async throws {
    let url = changeTrackingDatabaseURL()
    let store = try await changeTrackingStore(at: url)
    let baseline = try await store.currentChangeCursor()
    var deck = Deck(name: "Geography")

    _ = try await store.createDeck(deck)

    let createdRevision = try #require(
        try await store.resourceRevision(resourceType: "deck", resourceID: deck.id.uuidString)
    )
    #expect(createdRevision.revision == 1)
    #expect(createdRevision.isDeleted == false)
    let created = try #require(try await store.libraryChanges(after: baseline).last)
    #expect(created.eventType == "deck.created")
    #expect(created.resourceID == deck.id.uuidString)
    #expect(created.revision == 1)
    #expect(created.isTombstone == false)

    deck.name = "World Geography"
    _ = try await store.updateDeck(deck)

    let updatedRevision = try #require(
        try await store.resourceRevision(resourceType: "deck", resourceID: deck.id.uuidString)
    )
    #expect(updatedRevision.revision == 2)
    let updates = try await store.libraryChanges(after: created.cursor)
    #expect(updates.map(\.eventType) == ["deck.updated"])
    #expect(updates.first?.revision == 2)

    let reopened = try await changeTrackingStore(at: url)
    #expect(try await reopened.currentChangeCursor() == updates.first?.cursor)
    #expect(
        try await reopened.resourceRevision(resourceType: "deck", resourceID: deck.id.uuidString)
            == updatedRevision
    )
}

@Test func multiResourceItemWriteEmitsOneContiguousTransaction() async throws {
    let store = try await changeTrackingStore()
    let deck = Deck(name: "Facts")
    _ = try await store.createDeck(deck)
    let baseline = try await store.currentChangeCursor()
    let item = trackedBasicItem(deckID: deck.id)

    let summary = try await store.createItem(item)

    #expect(summary.cardCount == 1)
    let changes = try await store.libraryChanges(after: baseline)
    #expect(changes.map(\.eventType) == ["item.created", "card.created"])
    #expect(Set(changes.map(\.transactionID)).count == 1)
    #expect(changes.map(\.sequence) == [0, 1])
    #expect(changes[1].cursor == changes[0].cursor + 1)
    #expect(changes.allSatisfy { !$0.isTombstone })
}

@Test func cascadingDeleteUsesOneTransactionAndLeavesTombstoneRevisions() async throws {
    let store = try await changeTrackingStore()
    let item = trackedBasicItem()
    _ = try await store.createItem(item)
    let cardID = try #require(try await store.fetchDueCards().first?.id)
    let baseline = try await store.currentChangeCursor()

    #expect(try await store.deleteItem(id: item.id))

    let changes = try await store.libraryChanges(after: baseline)
    #expect(changes.map(\.eventType) == ["card.deleted", "item.deleted"])
    #expect(Set(changes.map(\.transactionID)).count == 1)
    #expect(changes.map(\.sequence) == [0, 1])
    #expect(changes.allSatisfy { $0.isTombstone })
    let itemRevision = try #require(
        try await store.resourceRevision(resourceType: "item", resourceID: item.id.uuidString)
    )
    let cardRevision = try #require(
        try await store.resourceRevision(resourceType: "card", resourceID: cardID.uuidString)
    )
    #expect(itemRevision.revision == 2)
    #expect(itemRevision.isDeleted)
    #expect(cardRevision.revision == 2)
    #expect(cardRevision.isDeleted)
}

@Test func failedDomainValidationProducesNoRevisionOrEvent() async throws {
    let store = try await changeTrackingStore()
    let baseline = try await store.currentChangeCursor()
    let invalid = Item(
        itemTypeID: BuiltInItemTypes.basicID,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .empty),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
        ]
    )

    await #expect(throws: DatabaseError.self) {
        try await store.createItem(invalid)
    }

    #expect(try await store.currentChangeCursor() == baseline)
    #expect(
        try await store.resourceRevision(resourceType: "item", resourceID: invalid.id.uuidString)
            == nil
    )
}

@Test func changePaginationAndRetentionAreBounded() async throws {
    let store = try ItemStore(
        databaseURL: changeTrackingDatabaseURL(),
        starterItemTypes: []
    )
    try await store.bootstrap()
    let baseline = try await store.currentChangeCursor()
    for index in 0 ..< 5 {
        _ = try await store.createDeck(Deck(name: "Deck \(index)"))
    }

    let firstPage = try await store.libraryChanges(after: baseline, limit: 2)
    let secondPage = try await store.libraryChanges(after: firstPage.last?.cursor ?? baseline, limit: 2)
    let thirdPage = try await store.libraryChanges(after: secondPage.last?.cursor ?? baseline, limit: 2)
    let combined = firstPage + secondPage + thirdPage
    #expect(combined.count == 5)
    #expect(Set(combined.map(\.cursor)).count == 5)
    #expect(combined.map(\.cursor) == combined.map(\.cursor).sorted())
    let totalBeforePrune = try await store.libraryChanges(after: 0).count

    #expect(
        try await store.pruneLibraryChanges(
            asOf: .distantFuture,
            retentionInterval: 0,
            minimumRetained: 3
        ) == totalBeforePrune - 3
    )
    let retained = try await store.libraryChanges(after: baseline)
    #expect(retained.map(\.cursor) == Array(combined.suffix(3)).map(\.cursor))
}

@Test func versionTwentyMigrationBackfillsWithoutInventingEvents() async throws {
    let url = changeTrackingDatabaseURL()
    let deck = Deck(name: "Existing")
    try executeChangeTrackingSQL(
        """
        CREATE TABLE schema_version (version INTEGER NOT NULL);
        INSERT INTO schema_version VALUES (20);
        CREATE TABLE app_metadata (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        CREATE TABLE decks (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            parent_id TEXT REFERENCES decks(id),
            new_cards_per_day INTEGER CHECK(new_cards_per_day >= 0)
        );
        INSERT INTO decks (id, name) VALUES ('\(deck.id.uuidString)', 'Existing');
        """,
        at: url
    )
    let database = try SQLiteDatabase(path: url)

    try await database.migrate()

    #expect(try await database.currentChangeCursor() == 0)
    let revision = try #require(
        try await database.fetchResourceRevision(
            resourceType: "deck",
            resourceID: deck.id.uuidString
        )
    )
    #expect(revision.revision == 1)
    #expect(!revision.isDeleted)
    var updated = deck
    updated.name = "Updated"
    try await database.updateDeck(updated)
    let changes = try await database.fetchLibraryChanges(after: 0, limit: 10)
    #expect(changes.map(\.eventType) == ["deck.updated"])
    #expect(changes.first?.revision == 2)
}

private func executeChangeTrackingSQL(_ sql: String, at url: URL) throws {
    var handle: OpaquePointer?
    guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
        throw DatabaseError.openFailed("Could not create test database.")
    }
    defer { sqlite3_close(handle) }
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
        throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(handle)))
    }
}
