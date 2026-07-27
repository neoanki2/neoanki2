import Foundation
import Testing
@testable import NeoAnkiCore

@Test func libraryIdentityIsStableAndPortableMappingsPersist() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-portable-mapping-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = try SQLiteDatabase(path: directory.appendingPathComponent("library.sqlite"))
    try await database.migrate()

    let firstLibraryID = try await database.getOrCreateLibraryID()
    let secondLibraryID = try await database.getOrCreateLibraryID()
    #expect(firstLibraryID == secondLibraryID)

    let localType = try makeMappedItemType()
    try await database.insertItemType(localType)
    let originLibraryID = UUID()
    let originTypeID = UUID()
    let digest = try localType.portableSchemaDigest()

    #expect(try await database.lookupPortableItemTypeMapping(
        originLibraryID: originLibraryID,
        originTypeID: originTypeID,
        schemaDigest: digest
    ) == nil)

    try await database.persistPortableItemTypeMapping(
        originLibraryID: originLibraryID,
        originTypeID: originTypeID,
        schemaDigest: digest,
        localTypeID: localType.id
    )

    #expect(try await database.lookupPortableItemTypeMapping(
        originLibraryID: originLibraryID,
        originTypeID: originTypeID,
        schemaDigest: digest
    ) == localType.id)
    #expect(try await database.lookupPortableItemTypeMapping(schemaDigest: digest) == localType.id)
}

private func makeMappedItemType() throws -> ItemType {
    try ItemTypeBuilder.makeItemType(
        name: "Mapped",
        fields: [
            FieldDef(name: "Prompt", type: .text, isRequired: true),
            FieldDef(name: "Answer", type: .text, isRequired: true),
        ]
    )
}
