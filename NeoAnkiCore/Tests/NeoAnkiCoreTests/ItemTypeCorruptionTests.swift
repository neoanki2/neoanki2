import Foundation
import Testing
@testable import NeoAnkiCore

@Test func malformedItemTypeDoesNotHideGoodRowsAndCanBeArchivedBeforeRepair() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-corrupt-type-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = try SQLiteDatabase(path: directory.appendingPathComponent("test.sqlite"))
    try await database.migrate()

    let good = try ItemTypeBuilder.makeItemType(
        name: "Good",
        fields: [FieldDef(name: "Front", type: .text), FieldDef(name: "Back", type: .text)]
    )
    let damaged = try ItemTypeBuilder.makeItemType(
        name: "Damaged",
        fields: [FieldDef(name: "Front", type: .text), FieldDef(name: "Back", type: .text)]
    )
    try await database.insertItemType(good)
    try await database.insertItemType(damaged)
    try await database.replaceItemTypeDefinition(
        id: damaged.id,
        with: Data(#"{"templates":[{"broken":true}]}"#.utf8)
    )

    let loaded = try await database.fetchItemTypesWithCorruption()
    #expect(loaded.itemTypes.map(\.id) == [good.id])
    #expect(loaded.corruptions == [
        QuarantinedItemTypeDefinition(persistedID: damaged.id.uuidString, name: damaged.name),
    ])

    let repaired = try await database.repairItemTypeDefinition(
        id: damaged.id,
        now: Date(timeIntervalSince1970: 123)
    )
    #expect(repaired.id == damaged.id)
    #expect(repaired.fields.count == 2)
    #expect(try await database.quarantinedDefinitionCount(itemTypeID: damaged.id) == 1)

    let afterRepair = try await database.fetchItemTypesWithCorruption()
    #expect(Set(afterRepair.itemTypes.map(\.id)) == [good.id, damaged.id])
    #expect(afterRepair.corruptions.isEmpty)
}

@Test func corruptItemTypeOnlyQuarantinesItsLinkedItemsAndDueCards() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-corrupt-linked-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let databaseURL = directory.appendingPathComponent("test.sqlite")
    let store = try ItemStore(databaseURL: databaseURL, starterItemTypes: [])
    try await store.bootstrap()

    let good = try ItemTypeBuilder.makeItemType(
        name: "Good",
        fields: [FieldDef(name: "Front", type: .text), FieldDef(name: "Back", type: .text)]
    )
    let damaged = try ItemTypeBuilder.makeItemType(
        name: "Damaged",
        fields: [FieldDef(name: "Front", type: .text), FieldDef(name: "Back", type: .text)]
    )
    try await store.createItemType(good)
    try await store.createItemType(damaged)
    let goodItem = Item(
        itemTypeID: good.id,
        fields: [
            FieldValue(fieldID: good.fields[0].id, value: .text("Good question")),
            FieldValue(fieldID: good.fields[1].id, value: .text("Good answer")),
        ]
    )
    let damagedItem = Item(
        itemTypeID: damaged.id,
        fields: [
            FieldValue(fieldID: damaged.fields[0].id, value: .text("Damaged question")),
            FieldValue(fieldID: damaged.fields[1].id, value: .text("Damaged answer")),
        ]
    )
    try await store.createItem(goodItem)
    try await store.createItem(damagedItem)

    let database = try SQLiteDatabase(path: databaseURL)
    try await database.replaceItemTypeDefinition(
        id: damaged.id,
        with: Data(#"{"templates":[{"broken":true}]}"#.utf8)
    )

    let summaries = try await store.listItems()
    #expect(Set(summaries.map(\.id)) == [goodItem.id])
    let dueCards = try await store.fetchDueCards(asOf: .distantFuture)
    #expect(Set(dueCards.map(\.item.id)) == [goodItem.id])

    let diagnostics = try await store.loadItemTypes()
    #expect(diagnostics.corruptions == [
        QuarantinedItemTypeDefinition(persistedID: damaged.id.uuidString, name: damaged.name),
    ])
    #expect(try await database.quarantinedDefinitionCount(itemTypeID: damaged.id) == 0)

    _ = try await store.repairItemTypeDefinition(id: damaged.id)
    #expect(try await database.quarantinedDefinitionCount(itemTypeID: damaged.id) == 1)
    #expect(Set(try await store.listItems().map(\.id)) == [goodItem.id, damagedItem.id])
    #expect(Set(try await store.fetchDueCards(asOf: .distantFuture).map(\.item.id)) == [
        goodItem.id,
        damagedItem.id,
    ])
}
