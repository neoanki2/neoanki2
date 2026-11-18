import Foundation
import Testing
@testable import NeoAnkiCore

@Test func itemCardSnapshotIncludesFutureCardsAndTracksDeletion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("item-card-snapshot-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ItemStore(databaseURL: root.appendingPathComponent("library.sqlite"))
    try await store.bootstrap()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let item = Item(itemTypeID: BuiltInItemTypes.clozeID, fields: [
        .init(fieldID: BuiltInItemTypes.clozeTextFieldID, value: .cloze("Alpha Beta", blanks: [
            .init(group: 1, start: 0, length: 5), .init(group: 2, start: 6, length: 4),
        ])),
    ])
    _ = try await store.createItem(item, now: now)
    for card in try await store.cards() {
        _ = try await store.submitReview(cardID: card.id, rating: .easy, now: now)
    }
    #expect(try await store.fetchDueCards(asOf: now).isEmpty)
    let snapshot = try #require(try await store.itemCardSnapshot(id: item.id))
    #expect(snapshot.item == item)
    #expect(snapshot.itemType.id == item.itemTypeID)
    #expect(snapshot.cards.count == 2)
    #expect(snapshot.cards.allSatisfy { !$0.isDue(asOf: now) })
    let stored = try await store.cards()
    #expect(Dictionary(uniqueKeysWithValues: snapshot.cards.map { ($0.id, $0) })
        == Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) }))
    _ = try await store.deleteItem(id: item.id)
    #expect(try await store.itemCardSnapshot(id: item.id) == nil)
}
