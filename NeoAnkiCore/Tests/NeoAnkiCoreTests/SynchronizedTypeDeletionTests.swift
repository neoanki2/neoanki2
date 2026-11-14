import Foundation
import Testing
@testable import NeoAnkiCore

private struct TypeDeletionFixture {
    let directory: URL
    let store: ItemStore
    let database: SQLiteDatabase
    let deck: Deck
    let type: ItemType

    static func make() async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sync-type-delete-\(UUID())")
        let store = try ItemStore(databaseURL: directory.appendingPathComponent("library.sqlite"))
        try await store.bootstrap()
        let base = try await store.defaultItemType()
        let type = ItemType(name: "Unused remote type", fields: base.fields, templates: base.templates)
        _ = try await store.createItemType(type)
        let deck = try await store.createDeck(Deck(name: "Before sync"))
        try await store.setDeckItemTypes(.init(deckID: deck.id, itemTypeIDs: [type.id], defaultItemTypeID: type.id))
        return Self(directory: directory, store: store,
                    database: try SQLiteDatabase(path: directory.appendingPathComponent("library.sqlite")),
                    deck: deck, type: type)
    }
}

struct SynchronizedTypeDeletionTests {
    @Test func remoteTypeDeletionSharesTheBatchTransaction() async throws {
        let f = try await TypeDeletionFixture.make()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let cursor = try await f.store.currentChangeCursor()
        var renamed = f.deck
        renamed.name = "After sync"
        try await f.store.applySynchronizedBatch([
            .deck(renamed), .tombstone(kind: .itemType, id: f.type.id.uuidString),
        ])
        #expect(try await f.store.deck(id: f.deck.id).name == "After sync")
        #expect(try await f.store.listItemTypes().allSatisfy { $0.id != f.type.id })
        let settings = try #require(try await f.database.fetchDeckTypeSettings().first { $0.deckID == f.deck.id })
        #expect(settings.itemTypeIDs.isEmpty)
        #expect(settings.defaultItemTypeID == nil)
        let changes = try await f.store.libraryChanges(after: cursor, limit: 100)
        #expect(Set(changes.map(\.transactionID)).count == 1)
    }

    @Test func laterBatchFailureRollsBackTypeDeletionAndAttachmentCleanup() async throws {
        let f = try await TypeDeletionFixture.make()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let cursor = try await f.store.currentChangeCursor()
        await #expect(throws: DatabaseError.invalidDeck("Study day rollover must be a valid local time.")) {
            try await f.store.applySynchronizedBatch([
                .tombstone(kind: .itemType, id: f.type.id.uuidString),
                .schedulingSettings(.studyDayRollover(minutes: -1)),
            ])
        }
        #expect(try await f.store.listItemTypes().contains { $0.id == f.type.id })
        let settings = try #require(try await f.database.fetchDeckTypeSettings().first { $0.deckID == f.deck.id })
        #expect(settings.itemTypeIDs == [f.type.id])
        #expect(settings.defaultItemTypeID == f.type.id)
        #expect(try await f.store.currentChangeCursor() == cursor)
    }

    @Test func repeatedUnknownTypeTombstonesAreHarmless() async throws {
        let f = try await TypeDeletionFixture.make()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = UUID().uuidString
        let cursor = try await f.store.currentChangeCursor()
        try await f.store.applySynchronizedBatch([
            .tombstone(kind: .itemType, id: id), .tombstone(kind: .itemType, id: id),
        ])
        #expect(try await f.store.currentChangeCursor() == cursor)
    }
}
