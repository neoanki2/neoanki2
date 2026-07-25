import Foundation
import SQLite3
import Testing
@testable import NeoAnkiCore

@Test func itemUpdateReconcilesClozeGroupsAndPreservesMatchingMemory() async throws {
    let databaseURL = reconciliationDatabaseURL()
    let store = try ItemStore(databaseURL: databaseURL)
    try await store.bootstrap()
    let type = try await store.itemType(id: BuiltInItemTypes.clozeID)
    var item = Item(
        itemTypeID: type.id,
        fields: [
            FieldValue(
                fieldID: BuiltInItemTypes.clozeTextFieldID,
                value: .cloze(
                    "alpha beta",
                    blanks: [
                        ClozeSpan(group: 1, start: 0, length: 5),
                        ClozeSpan(group: 2, start: 6, length: 4),
                    ]
                )
            ),
        ]
    )
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try await store.createItem(item, now: start)
    let database = try SQLiteDatabase(path: databaseURL)
    let original = try await database.fetchCards(for: item.id)
    let groupOne = try #require(original.first { $0.clozeGroup == 1 })
    _ = try await store.submitReview(
        cardID: groupOne.id,
        rating: .good,
        now: start.addingTimeInterval(60)
    )
    let learned = try #require(await database.fetchCard(id: groupOne.id))

    item.fields = [
        FieldValue(
            fieldID: BuiltInItemTypes.clozeTextFieldID,
            value: .cloze(
                "alpha gamma",
                blanks: [
                    ClozeSpan(group: 1, start: 0, length: 5),
                    ClozeSpan(group: 3, start: 6, length: 5),
                ]
            )
        ),
    ]
    let saved = try await store.updateItem(item, now: start.addingTimeInterval(120))
    let reconciled = try await database.fetchCards(for: item.id)

    #expect(saved.cardCount == 2)
    #expect(Set(reconciled.compactMap(\.clozeGroup)) == [1, 3])
    let preserved = try #require(reconciled.first { $0.clozeGroup == 1 })
    #expect(preserved.id == learned.id)
    #expect(preserved.memory == learned.memory)
    #expect(reconciled.first { $0.clozeGroup == 2 } == nil)
    #expect(reconciled.first { $0.clozeGroup == 3 }?.memory.phase == .new)
}

@Test func itemUpdateAppliesGenerateWhenTransitionsAtomically() async throws {
    let databaseURL = reconciliationDatabaseURL()
    let store = try ItemStore(databaseURL: databaseURL)
    try await store.bootstrap()
    let front = FieldDef(name: "Front", type: .text, isRequired: true)
    let optional = FieldDef(name: "Optional", type: .text)
    let always = Template(
        name: "Always",
        prompt: Side(slots: [Slot(source: .field(front.id))]),
        answer: Side(slots: [Slot(source: .field(front.id))]),
        interaction: .reveal,
        skill: Skill(input: .text, output: .text, operation: .recognize)
    )
    let gated = Template(
        name: "Gated",
        prompt: Side(slots: [Slot(source: .field(optional.id))]),
        answer: Side(slots: [Slot(source: .field(front.id))]),
        interaction: .reveal,
        skill: Skill(input: .text, output: .text, operation: .recall),
        generateWhen: .fieldNotEmpty(optional.id)
    )
    let type = ItemType(name: "Conditional", fields: [front, optional], templates: [always, gated])
    _ = try await store.createItemType(type)
    var item = Item(
        itemTypeID: type.id,
        fields: [
            FieldValue(fieldID: front.id, value: .text("Question")),
            FieldValue(fieldID: optional.id, value: .text("Extra")),
        ]
    )
    let start = Date(timeIntervalSince1970: 1_700_100_000)
    _ = try await store.createItem(item, now: start)
    let database = try SQLiteDatabase(path: databaseURL)
    let initial = try await database.fetchCards(for: item.id)
    let alwaysCard = try #require(initial.first { $0.templateID == always.id })
    _ = try await store.submitReview(cardID: alwaysCard.id, rating: .easy, now: start)
    let learned = try #require(await database.fetchCard(id: alwaysCard.id))

    item.fields.removeAll { $0.fieldID == optional.id }
    #expect(try await store.updateItem(item).cardCount == 1)
    var cards = try await database.fetchCards(for: item.id)
    #expect(cards.map(\.templateID) == [always.id])
    #expect(cards[0].id == learned.id)
    #expect(cards[0].memory == learned.memory)

    item.fields.append(FieldValue(fieldID: optional.id, value: .text("Restored")))
    #expect(try await store.updateItem(item).cardCount == 2)
    cards = try await database.fetchCards(for: item.id)
    #expect(cards.first { $0.templateID == always.id }?.memory == learned.memory)
    #expect(cards.first { $0.templateID == gated.id }?.memory.phase == .new)
}

@Test func itemAndGeneratedCardReconciliationRollBackTogether() async throws {
    let databaseURL = reconciliationDatabaseURL()
    let store = try ItemStore(databaseURL: databaseURL)
    try await store.bootstrap()
    let type = try await store.itemType(id: BuiltInItemTypes.clozeID)
    var item = Item(
        itemTypeID: type.id,
        fields: [
            FieldValue(
                fieldID: BuiltInItemTypes.clozeTextFieldID,
                value: .cloze("alpha beta", blanks: [ClozeSpan(group: 1, start: 0, length: 5)])
            ),
        ]
    )
    _ = try await store.createItem(item)
    try executeReconciliationSQL(
        """
        CREATE TRIGGER fail_new_cloze_card
        BEFORE INSERT ON cards
        BEGIN
            SELECT RAISE(ABORT, 'forced card reconciliation failure');
        END;
        """,
        at: databaseURL
    )
    item.fields = [
        FieldValue(
            fieldID: BuiltInItemTypes.clozeTextFieldID,
            value: .cloze(
                "alpha beta",
                blanks: [
                    ClozeSpan(group: 1, start: 0, length: 5),
                    ClozeSpan(group: 2, start: 6, length: 4),
                ]
            )
        ),
    ]

    await #expect(throws: DatabaseError.self) {
        try await store.updateItem(item)
    }

    let persisted = try #require(await store.fetchItem(id: item.id)?.item)
    guard case let .cloze(_, blanks)? = persisted.value(for: BuiltInItemTypes.clozeTextFieldID) else {
        Issue.record("Expected the original cloze value")
        return
    }
    #expect(blanks.map(\.group) == [1])
    let database = try SQLiteDatabase(path: databaseURL)
    #expect(try await database.fetchCards(for: item.id).compactMap(\.clozeGroup) == [1])
}

private func reconciliationDatabaseURL() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-card-reconcile-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.appendingPathComponent("test.sqlite")
}

private func executeReconciliationSQL(_ sql: String, at URL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(URL.path(percentEncoded: false), &database) == SQLITE_OK,
          let database
    else {
        throw DatabaseError.openFailed("Could not open reconciliation test database.")
    }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(database)))
    }
}
