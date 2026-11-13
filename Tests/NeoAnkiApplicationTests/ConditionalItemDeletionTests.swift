import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import Testing

private struct ConditionalDeletionFixture {
    let root: URL
    let library: SQLiteLibraryRepository

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("conditional-delete-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
        try await library.bootstrap()
    }
    func item(_ question: String) -> Item {
        Item(itemTypeID: BuiltInItemTypes.basicID, fields: [
            .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text(question)),
            .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer"))
        ])
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct ConditionalItemDeletionTests {
    @Test func unchangedFreshBatchDeletesTogether() async throws {
        let fixture = try await ConditionalDeletionFixture()
        defer { fixture.cleanup() }
        let items = [fixture.item("First"), fixture.item("Second")]
        for item in items { _ = try await fixture.library.createItem(item, asOf: .now) }
        let cursor = try await fixture.library.currentChangeCursor()
        let results = try await fixture.library.deleteUnchangedUnreviewedItems(items, asOf: .now)
        let changes = try await fixture.library.changes(after: cursor, limit: 100)
        let deletions = changes.filter { $0.resourceKind == .item && $0.isTombstone }
        #expect(Set(deletions.map(\.resourceID)) == Set(items.map { $0.id.uuidString }))
        #expect(Set(deletions.map(\.transactionID)).count == 1)
        #expect(Set(results.map(\.itemID)) == Set(items.map(\.id)))
        #expect(try await fixture.library.items(scope: .allDecks, sort: .createdAscending, search: "").isEmpty)
    }

    @Test(arguments: [false, true])
    func changedOrMovedMemberPreservesTheEntireBatch(moveToDeck: Bool) async throws {
        let fixture = try await ConditionalDeletionFixture()
        defer { fixture.cleanup() }
        let items = [fixture.item("First"), fixture.item("Second")]
        for item in items { _ = try await fixture.library.createItem(item, asOf: .now) }
        var changed = items[1]
        if moveToDeck {
            changed.deckID = try await fixture.library.createDeck(Deck(name: "Another deck")).id
        } else { changed.tags = ["edited"] }
        _ = try await fixture.library.updateItem(changed, asOf: .now)
        let cursor = try await fixture.library.currentChangeCursor()

        await #expect(throws: (any Error).self) {
            try await fixture.library.deleteUnchangedUnreviewedItems(items, asOf: .now)
        }
        #expect(try await fixture.library.item(id: items[0].id)?.item == items[0])
        #expect(try await fixture.library.item(id: changed.id)?.item == changed)
        #expect(try await fixture.library.currentChangeCursor() == cursor)
    }

    @Test(arguments: [false, true])
    func reviewAfterCapturePreventsBatchUndoEvenAfterRevert(revert: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("conditional-review-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(databaseURL: root.appendingPathComponent("library.sqlite"))
        let library = SQLiteLibraryRepository(store: store)
        try await library.bootstrap()
        let items = ["First", "Second"].map { question in
            Item(itemTypeID: BuiltInItemTypes.basicID, fields: [
                .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text(question)),
                .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer"))
            ])
        }
        for item in items { _ = try await library.createItem(item, asOf: .now) }
        let card = try #require(try await store.fetchDueCards().first { $0.item.id == items[1].id }?.card)
        let review = try await store.submitReviewWithReceipt(cardID: card.id, rating: .good)
        if revert { try await store.revertReview(reviewLogID: review.reviewLogID) }

        await #expect(throws: (any Error).self) {
            try await library.deleteUnchangedUnreviewedItems(items, asOf: .now)
        }
        for item in items { #expect(try await library.item(id: item.id)?.item == item) }
        #expect(try await store.rawReviewLogCount(for: card.id) == 1)
    }
}
