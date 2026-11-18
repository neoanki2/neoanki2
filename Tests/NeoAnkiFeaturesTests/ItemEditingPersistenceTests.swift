import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import SQLite3
import Testing

/// Exercise the native save boundary against isolated SQLite databases. Every
/// assertion re-reads persisted content; a successful callback alone is not proof.
@Suite @MainActor struct ItemEditingPersistenceTests {
    private struct Fixture {
        let root: URL
        let repository: SQLiteLibraryRepository
        let model: LibraryFeatureModel
        let item: Item
    }
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("item-edit-contract-\(UUID())")
        let repository = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
        let model = LibraryFeatureModel(library: repository)
        await model.bootstrap(startSync: false)
        let item = Item(itemTypeID: BuiltInItemTypes.basicID, fields: [
            .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Before", lang: "uk")),
            .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer", lang: "en")),
        ], tags: ["original"])
        _ = try await repository.createItem(item, asOf: instant)
        return .init(root: root, repository: repository, model: model, item: item)
    }

    @Test(arguments: ["same", "text", "rich", "tags", "deck", "unassigned"])
    func nativeEditSurvivesReopeningAndKeepsCardMemoryAndUndo(scenario: String) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var edited = f.item
        let originalCard = try #require(try await f.repository.cards().first)
        let review = try await f.repository.submitReview(cardID: originalCard.id, rating: .good,
            asOf: instant, durationMilliseconds: 100)
        let learned = try #require(try await f.repository.cards().first)
        switch scenario {
        case "text": edited.fields[0].value = .text("Виправлено 🧠 e\u{301}", lang: "uk")
        case "rich": edited.fields[0].value = .rich([Span("Виправлено", styles: [.bold]), Span(" source", link: "https://example.com")])
        case "tags": edited.tags = ["changed", "second"]
        case "deck": edited.deckID = try await f.repository.createDeck(Deck(name: "Destination")).id
        case "unassigned":
            let deck = try await f.repository.createDeck(Deck(name: "Original"))
            var assigned = edited; assigned.deckID = deck.id
            try await f.model.updateItem(assigned)
            edited.deckID = nil
        default: break
        }
        try await f.model.updateItem(edited)
        #expect(f.model.lastCommandReceipt != nil)
        let reopened = try SQLiteLibraryRepository(databaseURL: f.root.appendingPathComponent("library.sqlite"))
        #expect(try await reopened.item(id: edited.id)?.item == edited)
        let savedCard = try #require(try await reopened.cards().first)
        #expect(savedCard.id == learned.id)
        #expect(savedCard.memory == learned.memory)
        #expect(savedCard.deckID == edited.deckID)
        #expect(try await reopened.items(scope: .allDecks, sort: .createdAscending, search: "").count == 1)
        try await reopened.revertReview(id: review.reviewLogID, asOf: instant.addingTimeInterval(60))
        #expect(try await reopened.cards().first?.memory == originalCard.memory)
        #expect(try await reopened.item(id: edited.id)?.item == edited, "Undoing a review must not undo the content edit")
    }

    @Test(arguments: ["required-empty", "unknown-field", "duplicate-field", "wrong-kind", "missing-type", "missing-deck", "empty-tag", "too-many-tags"])
    func rejectedEditsLeaveContentCardsAndReceiptUnchanged(scenario: String) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let originalCards = try await f.repository.cards()
        let originalReceipt = f.model.lastCommandReceipt
        var edited = f.item
        switch scenario {
        case "required-empty": edited.fields[0].value = .empty
        case "unknown-field": edited.fields.append(.init(fieldID: UUID(), value: .text("Unknown")))
        case "duplicate-field": edited.fields.append(edited.fields[0])
        case "wrong-kind": edited.fields[0].value = .number(1)
        case "missing-type": edited.itemTypeID = UUID()
        case "missing-deck": edited.deckID = UUID()
        case "empty-tag": edited.tags = [" "]
        default: edited.tags = (0..<257).map(String.init)
        }
        await #expect(throws: (any Error).self) { try await f.model.updateItem(edited) }
        #expect(try await f.repository.item(id: f.item.id)?.item == f.item)
        #expect(try await f.repository.cards() == originalCards)
        #expect(f.model.lastCommandReceipt == originalReceipt)
    }

    @Test func databaseWriteFailureDoesNotPublishAnEditAndAnExplicitRetryCanSaveIt() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var db: OpaquePointer?
        #expect(sqlite3_open(f.root.appendingPathComponent("library.sqlite").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "CREATE TRIGGER fail_edit BEFORE UPDATE ON items BEGIN SELECT RAISE(ABORT, 'injected write failure'); END;", nil, nil, nil) == SQLITE_OK)
        let before = try await f.repository.cards()
        var edited = f.item
        edited.fields[0].value = .text("After explicit retry", lang: "uk")
        await #expect(throws: (any Error).self) { try await f.model.updateItem(edited) }
        #expect(try await f.repository.item(id: edited.id)?.item == f.item)
        #expect(try await f.repository.cards() == before)
        #expect(f.model.lastCommandReceipt == nil)
        #expect(sqlite3_exec(db, "DROP TRIGGER fail_edit;", nil, nil, nil) == SQLITE_OK)
        try await f.model.updateItem(edited)
        #expect(try await f.repository.item(id: edited.id)?.item == edited)
        #expect(f.model.lastCommandReceipt != nil)
    }

    @Test func editingDeletedItemCannotResurrectIt() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.repository.deleteItem(id: f.item.id, asOf: instant)
        await #expect(throws: (any Error).self) { try await f.model.updateItem(f.item) }
        #expect(try await f.repository.item(id: f.item.id) == nil)
        #expect(try await f.repository.cards().isEmpty)
        #expect(f.model.lastCommandReceipt == nil)
    }

    @Test func editingOneItemDoesNotOverwriteAnotherItemOrMutateAnUnsavedDraft() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let other = Item(itemTypeID: f.item.itemTypeID, fields: f.item.fields)
        _ = try await f.repository.createItem(other, asOf: instant)
        var draft = f.item
        draft.fields[0].value = .text("Unsaved")
        #expect(try await f.repository.item(id: f.item.id)?.item == f.item)
        try await f.model.updateItem(draft)
        #expect(try await f.repository.item(id: other.id)?.item == other)
        #expect(try await f.repository.item(id: draft.id)?.item == draft)
    }

    @Test(arguments: ["same-groups", "merge", "split", "replace-all", "no-blanks", "overlap", "past-end"])
    func clozeEditsReconcileGroupIdentityOrRollBackCompletely(scenario: String) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let original = Item(itemTypeID: BuiltInItemTypes.clozeID, fields: [
            .init(fieldID: BuiltInItemTypes.clozeTextFieldID, value: .cloze("Alpha Beta", blanks: [
                .init(group: 1, start: 0, length: 5), .init(group: 2, start: 6, length: 4),
            ])),
        ])
        _ = try await f.repository.createItem(original, asOf: instant)
        for card in try await f.repository.cards() where card.itemID == original.id {
            _ = try await f.repository.submitReview(cardID: card.id, rating: .good, asOf: instant, durationMilliseconds: 10)
        }
        let learned = try await f.repository.cards().filter { $0.itemID == original.id }
        let groups: [Int]
        switch scenario {
        case "merge": groups = [1, 1]
        case "split": groups = [1, 3]
        case "replace-all": groups = [3, 4]
        default: groups = [1, 2]
        }
        var blanks: [ClozeSpan] = [
            .init(group: groups[0], start: 0, length: 5, hint: "Edited hint"),
            .init(group: groups[1], start: 6, length: 5),
        ]
        if scenario == "no-blanks" { blanks = [] }
        if scenario == "overlap" { blanks[1].start = 3 }
        if scenario == "past-end" { blanks[1].length = 100 }
        var edited = original
        edited.fields[0].value = .cloze("Alpha Gamma", blanks: blanks)
        if ["no-blanks", "overlap", "past-end"].contains(scenario) {
            await #expect(throws: (any Error).self) { try await f.model.updateItem(edited) }
            #expect(try await f.repository.item(id: original.id)?.item == original)
            #expect(try await f.repository.cards().filter { $0.itemID == original.id } == learned)
        } else {
            try await f.model.updateItem(edited)
            let reconciled = try await f.repository.cards().filter { $0.itemID == original.id }
            #expect(Set(reconciled.compactMap(\.clozeGroup)) == Set(groups))
            #expect(reconciled.count == Set(groups).count)
            for card in reconciled {
                if let prior = learned.first(where: { $0.clozeGroup == card.clozeGroup }) {
                    #expect(card.id == prior.id)
                    #expect(card.memory == prior.memory)
                } else {
                    #expect(!learned.contains { $0.id == card.id })
                    #expect(card.memory.phase == .new)
                }
            }
            #expect(try await f.repository.item(id: original.id)?.item == edited)
        }
    }
}
