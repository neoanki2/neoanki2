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
