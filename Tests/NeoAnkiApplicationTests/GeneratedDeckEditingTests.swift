import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import Testing

@Suite struct GeneratedDeckEditingTests {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)
    private func item(_ question: String, deckID: UUID) -> Item {
        .init(itemTypeID: BuiltInItemTypes.basicID, fields: [
            .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text(question)),
            .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
        ], deckID: deckID)
    }

    @Test func loadUsesOnlyDirectDeckItemsInCreationOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("generated-edit-load-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
        try await repository.bootstrap()
        let parent = try await repository.createDeck(Deck(name: "Parent"))
        let child = try await repository.createDeck(Deck(name: "Child", parentID: parent.id))
        let editing = GeneratedDeckEditing(library: repository)
        #expect(try await editing.load(deckID: parent.id, itemTypeID: BuiltInItemTypes.basicID).isEmpty)
        let first = item("First", deckID: parent.id), second = item("Second", deckID: parent.id)
        _ = try await repository.createItem(second, asOf: instant.addingTimeInterval(1))
        _ = try await repository.createItem(first, asOf: instant)
        _ = try await repository.createItem(item("Child", deckID: child.id), asOf: instant)
        let loaded = try await editing.load(deckID: parent.id, itemTypeID: BuiltInItemTypes.basicID)
        #expect(loaded.map(\.item) == [first, second])
        #expect(loaded.map(\.createdAt) == [instant, instant.addingTimeInterval(1)])
        #expect(loaded.allSatisfy { $0.itemType.id == BuiltInItemTypes.basicID })
    }

    @Test func mixedTypesAreRejectedBeforeEditing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("generated-edit-mixed-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
        try await repository.bootstrap()
        let deck = try await repository.createDeck(Deck(name: "Mixed"))
        _ = try await repository.createItem(item("Basic", deckID: deck.id), asOf: instant)
        _ = try await repository.createItem(.init(itemTypeID: BuiltInItemTypes.clozeID, fields: [
            .init(fieldID: BuiltInItemTypes.clozeTextFieldID, value: .cloze("Word", blanks: [.init(group: 1, start: 0, length: 4)])),
        ], deckID: deck.id), asOf: instant)
        await #expect(throws: GeneratedDeckEditingError.self) {
            try await GeneratedDeckEditing(library: repository).load(deckID: deck.id, itemTypeID: BuiltInItemTypes.basicID)
        }
        #expect(try await repository.items(scope: .deck(deck.id), sort: .createdAscending, search: "").count == 2)
    }

    @Test(arguments: ["valid", "stale-content", "stale-membership", "invalid-order", "invalid-replacement"])
    func atomicSaveChecksTheWholeSnapshotBeforeChangingAnything(scenario: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("generated-edit-save-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
        try await repository.bootstrap()
        let deck = try await repository.createDeck(Deck(name: "Ordered"))
        let first = item("First", deckID: deck.id), second = item("Second", deckID: deck.id)
        _ = try await repository.createItem(first, asOf: instant)
        _ = try await repository.createItem(second, asOf: instant.addingTimeInterval(1))
        let originalCard = try #require(try await repository.cards().first { $0.itemID == first.id })
        let review = try await repository.submitReview(cardID: originalCard.id, rating: .good, asOf: instant, durationMilliseconds: 42)
        let learned = try #require(try await repository.cards().first { $0.id == originalCard.id })
        var edited = first
        edited.fields[0].value = .text("Edited first")
        let added = item("Inserted", deckID: deck.id)
        var ids = [first.id, added.id]
        switch scenario {
        case "stale-content":
            var external = second; external.tags = ["External edit"]
            _ = try await repository.updateItem(external, asOf: instant.addingTimeInterval(2))
        case "stale-membership": _ = try await repository.createItem(item("External insert", deckID: deck.id), asOf: instant)
        case "invalid-order": ids.append(UUID())
        case "invalid-replacement": edited.fields[0].value = .number(12)
        default: break
        }
        let beforeCards = try await repository.cards()
        let beforeItems = try await repository.items(scope: .deck(deck.id), sort: .createdAscending, search: "")
        let operations: [ItemBulkOperation] = [
            .init(operationID: "edit", action: .replace(edited)),
            .init(operationID: "insert", action: .create(added)),
            .init(operationID: "retire", action: .delete(second.id)),
        ]
        let order = OrderedDeckItemReconciliation(deckID: deck.id, expectedItems: [first, second], orderedItemIDs: ids)
        let editing = GeneratedDeckEditing(library: repository)
        if scenario == "valid" {
            try await editing.save(operations, order: order, asOf: instant.addingTimeInterval(3))
            #expect(try await repository.item(id: first.id)?.item == edited)
            #expect(try await repository.item(id: added.id)?.item == added)
            #expect(try await repository.item(id: second.id) == nil)
            #expect(try await repository.cards().first { $0.id == learned.id }?.memory == learned.memory)
            try await repository.revertReview(id: review.reviewLogID, asOf: instant.addingTimeInterval(4))
            #expect(try await repository.item(id: first.id)?.item == edited)
        } else {
            await #expect(throws: (any Error).self) { try await editing.save(operations, order: order, asOf: instant.addingTimeInterval(3)) }
            #expect(try await repository.item(id: first.id)?.item == first)
            #expect(try await repository.item(id: added.id) == nil)
            #expect(try await repository.cards() == beforeCards)
            #expect(try await repository.items(scope: .deck(deck.id), sort: .createdAscending, search: "") == beforeItems)
        }
    }
}
