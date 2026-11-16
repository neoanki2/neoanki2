import Foundation
import SQLite3
import Testing
@testable import NeoAnkiCore

private struct AtomicCommandFixture {
    let directory: URL
    let store: ItemStore
    var url: URL { directory.appendingPathComponent("library.sqlite") }

    init() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("atomic-commands-\(UUID())")
        store = try ItemStore(databaseURL: directory.appendingPathComponent("library.sqlite"))
        try await store.bootstrap()
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    func item(_ title: String) -> Item {
        Item(itemTypeID: BuiltInItemTypes.basicID, fields: [
            .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text(title)),
            .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
        ])
    }
    func execute(_ sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw DatabaseError.openFailed("Fixture could not open SQLite.")
        }
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(handle)))
        }
    }
}

@Suite struct AtomicLibraryCommandsTests {
    @Test func secondMoveFailureRollsBackSelectionAndJournal() async throws {
        let f = try await AtomicCommandFixture()
        defer { f.cleanup() }
        let items = [f.item("First"), f.item("Second")]
        for item in items { _ = try await f.store.createItem(item) }
        let target = try await f.store.createDeck(Deck(name: "Target"))
        try f.execute("""
            CREATE TRIGGER reject_second_move BEFORE UPDATE OF deck_id ON items
            WHEN OLD.id = '\(items[1].id.uuidString)'
            BEGIN SELECT RAISE(ABORT, 'injected second-move failure'); END;
            """)
        let cursor = try await f.store.currentChangeCursor()
        await #expect(throws: (any Error).self) {
            try await f.store.moveItems(items.map { .init(itemID: $0.id, expectedDeckID: nil) }, to: target.id)
        }
        for item in items { #expect(try await f.store.fetchItem(id: item.id)?.item == item) }
        #expect(try await f.store.cards().allSatisfy { $0.deckID == nil })
        #expect(try await f.store.currentChangeCursor() == cursor)
    }

    @Test func movePreservesConcurrentContentButRejectsChangedAssignment() async throws {
        let f = try await AtomicCommandFixture()
        defer { f.cleanup() }
        var item = f.item("First")
        _ = try await f.store.createItem(item)
        let target = try await f.store.createDeck(Deck(name: "Target"))
        item.tags = ["edited after selection"]
        _ = try await f.store.updateItem(item)
        #expect(try await f.store.moveItems([.init(itemID: item.id, expectedDeckID: nil)], to: target.id) == 1)
        #expect(try await f.store.fetchItem(id: item.id)?.item.tags == item.tags)
        await #expect(throws: (any Error).self) {
            try await f.store.moveItems([.init(itemID: item.id, expectedDeckID: nil)], to: nil)
        }
        #expect(try await f.store.fetchItem(id: item.id)?.item.deckID == target.id)
    }

    @Test func importPlacementAndTypeAttachmentCommitTogether() async throws {
        let f = try await AtomicCommandFixture()
        defer { f.cleanup() }
        let target = try await f.store.createDeck(Deck(name: "Target"))
        let data = Data(#"{"itemType":"Basic","rows":[{"Front":"One","Back":"Answer"},{"Front":"Two","Back":"Answer"}]}"#.utf8)
        try f.execute("""
            CREATE TRIGGER reject_attachment BEFORE INSERT ON deck_item_type_settings
            BEGIN SELECT RAISE(ABORT, 'injected attachment failure'); END;
            """)
        let cursor = try await f.store.currentChangeCursor()
        await #expect(throws: (any Error).self) {
            try await f.store.importItemSummaries(from: data, adapter: JSONImportAdapter(), destinationDeckID: target.id)
        }
        #expect(try await f.store.listItems().isEmpty)
        #expect(try await f.store.cards().isEmpty)
        #expect(try await f.store.currentChangeCursor() == cursor)
        try f.execute("DROP TRIGGER reject_attachment;")
        let imported = try await f.store.importItemSummaries(from: data, adapter: JSONImportAdapter(), destinationDeckID: target.id)
        #expect(imported.count == 2)
        #expect(imported.allSatisfy { $0.deckID == target.id })
        #expect(try await f.store.cards().allSatisfy { $0.deckID == target.id })
        #expect(try await f.store.effectiveItemTypePolicy(for: target.id)?.itemTypes.map(\.id) == [BuiltInItemTypes.basicID])
    }

    @Test func receiptFailureRollsBackMutationAndReceiptRecoversAfterReopen() async throws {
        let f = try await AtomicCommandFixture()
        defer { f.cleanup() }
        let item = f.item("Original")
        _ = try await f.store.createItem(item)
        let target = try await f.store.createDeck(Deck(name: "Target"))
        let context = NativeCommandContext(operation: "move", input: Data(item.id.uuidString.utf8))
        try f.execute("""
            CREATE TRIGGER reject_native_receipt BEFORE INSERT ON api_idempotency
            WHEN NEW.route = 'native/v1/library-command'
            BEGIN SELECT RAISE(ABORT, 'injected receipt failure'); END;
            """)
        await #expect(throws: (any Error).self) {
            try await NativeCommandContext.$current.withValue(context) {
                try await f.store.moveItems([.init(itemID: item.id, expectedDeckID: nil)], to: target.id)
            }
        }
        #expect(try await f.store.fetchItem(id: item.id)?.item.deckID == nil)
        #expect(try await f.store.nativeCommandReceipt(context) == nil)
        try f.execute("DROP TRIGGER reject_native_receipt;")
        _ = try await NativeCommandContext.$current.withValue(context) {
            try await f.store.moveItems([.init(itemID: item.id, expectedDeckID: nil)], to: target.id)
        }
        let reopened = try ItemStore(databaseURL: f.url)
        let receipt = try #require(try await reopened.nativeCommandReceipt(context))
        #expect(receipt.commandID == context.id)
        #expect(receipt.affectedCount == 1)
        let conflicting = NativeCommandContext(id: context.id, operation: "move", input: Data("different destination".utf8))
        await #expect(throws: DatabaseError.idempotencyConflict) { try await reopened.nativeCommandReceipt(conflicting) }
    }

    @Test func importHierarchyRejectsMalformedGraphsAndPreservesSiblingOrder() throws {
        let root = Deck(name: "Root")
        let first = Deck(name: "First", parentID: root.id)
        let second = Deck(name: "Second", parentID: root.id)
        #expect(try DeckImportOrdering.parentFirst([first, second, root]).map(\.id) == [root.id, first.id, second.id])
        #expect(throws: (any Error).self) { try DeckImportOrdering.parentFirst([root, root]) }
        #expect(throws: (any Error).self) { try DeckImportOrdering.parentFirst([first]) }
        var cycle = root; cycle.parentID = first.id
        #expect(throws: (any Error).self) { try DeckImportOrdering.parentFirst([cycle, first]) }
    }
}
