import Foundation
import SQLite3
import Testing
@testable import NeoAnkiCore

private let pngBytes = Data([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    0x00, 0x00, 0x00, 0x0D,
] + Array(repeating: UInt8(0), count: 8))

private func makeMediaStore() async throws -> (
    store: ItemStore,
    media: MediaStore,
    type: ItemType,
    firstImage: FieldDef,
    secondImage: FieldDef
) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-media-lifecycle-\(UUID().uuidString)", isDirectory: true)
    let databaseURL = root.appendingPathComponent("test.sqlite")
    let store = try ItemStore(databaseURL: databaseURL)
    try await store.bootstrap()
    let media = try #require(await store.media)

    let front = FieldDef(name: "Front", type: .text, isRequired: true)
    let back = FieldDef(name: "Back", type: .text, isRequired: true)
    let firstImage = FieldDef(name: "Image 1", type: .image)
    let secondImage = FieldDef(name: "Image 2", type: .image)
    let type = try ItemTypeBuilder.makeItemType(
        name: "Media lifecycle",
        fields: [front, back, firstImage, secondImage]
    )
    _ = try await store.createItemType(type)
    return (store, media, type, firstImage, secondImage)
}

private func item(
    id: UUID = UUID(),
    type: ItemType,
    mediaFields: [(FieldDef, MediaRef)]
) -> Item {
    var fields = [
        FieldValue(fieldID: type.fields[0].id, value: .text("Front")),
        FieldValue(fieldID: type.fields[1].id, value: .text("Back")),
    ]
    fields.append(contentsOf: mediaFields.map {
        FieldValue(fieldID: $0.0.id, value: .media($0.1))
    })
    return Item(id: id, itemTypeID: type.id, fields: fields)
}

@Test func duplicateIngestRegistersOneUnreferencedAsset() async throws {
    let context = try await makeMediaStore()
    let first = try await context.media.ingest(data: pngBytes, kind: .image, fileExtension: "png")
    let second = try await context.media.ingest(data: pngBytes, kind: .image, fileExtension: "png")

    #expect(first.assetHash == second.assetHash)
    #expect(try await context.store.mediaAsset(hash: first.assetHash)?.refCount == 0)
    let mediaRoot = await context.media.rootDirectory
    let mediaDirectory = mediaRoot.appendingPathComponent("media")
    #expect(try FileManager.default.contentsOfDirectory(atPath: mediaDirectory.path).count == 1)
}

@Test func duplicateReferencesEditsAndDeletesApplyExactDeltas() async throws {
    let context = try await makeMediaStore()
    let first = try await context.media.ingest(data: pngBytes, kind: .image, fileExtension: "png")
    var otherBytes = pngBytes
    otherBytes.append(0x01)
    let second = try await context.media.ingest(data: otherBytes, kind: .image, fileExtension: "png")
    var saved = item(
        type: context.type,
        mediaFields: [(context.firstImage, first), (context.secondImage, first)]
    )

    _ = try await context.store.createItem(saved)
    #expect(try await context.store.mediaAsset(hash: first.assetHash)?.refCount == 2)

    saved.fields = saved.fields.filter { $0.fieldID != context.secondImage.id }
    saved.fields.append(FieldValue(fieldID: context.secondImage.id, value: .media(second)))
    _ = try await context.store.updateItem(saved)
    #expect(try await context.store.mediaAsset(hash: first.assetHash)?.refCount == 1)
    #expect(try await context.store.mediaAsset(hash: second.assetHash)?.refCount == 1)

    #expect(try await context.store.deleteItem(id: saved.id))
    #expect(try await context.store.mediaAsset(hash: first.assetHash) == nil)
    #expect(try await context.store.mediaAsset(hash: second.assetHash) == nil)
    await #expect(throws: MediaError.readFailed) {
        _ = try await context.media.resolve(first)
    }
    await #expect(throws: MediaError.readFailed) {
        _ = try await context.media.resolve(second)
    }
}

@Test func failedItemCreateRollsBackReferenceDeltas() async throws {
    let context = try await makeMediaStore()
    let first = try await context.media.ingest(data: pngBytes, kind: .image, fileExtension: "png")
    var otherBytes = pngBytes
    otherBytes.append(0x02)
    let second = try await context.media.ingest(data: otherBytes, kind: .image, fileExtension: "png")
    let duplicateID = UUID()

    _ = try await context.store.createItem(
        item(id: duplicateID, type: context.type, mediaFields: [(context.firstImage, first)])
    )
    await #expect(throws: DatabaseError.self) {
        _ = try await context.store.createItem(
            item(id: duplicateID, type: context.type, mediaFields: [(context.firstImage, second)])
        )
    }

    #expect(try await context.store.mediaAsset(hash: first.assetHash)?.refCount == 1)
    #expect(try await context.store.mediaAsset(hash: second.assetHash)?.refCount == 0)
}

@Test func sharedAssetSurvivesUntilLastItemIsDeleted() async throws {
    let context = try await makeMediaStore()
    let ref = try await context.media.ingest(data: pngBytes, kind: .image, fileExtension: "png")
    let first = item(type: context.type, mediaFields: [(context.firstImage, ref)])
    let second = item(type: context.type, mediaFields: [(context.firstImage, ref)])
    _ = try await context.store.createItem(first)
    _ = try await context.store.createItem(second)

    #expect(try await context.store.deleteItem(id: first.id))
    #expect(try await context.store.mediaAsset(hash: ref.assetHash)?.refCount == 1)
    _ = try await context.media.resolve(ref)

    #expect(try await context.store.deleteItem(id: second.id))
    #expect(try await context.store.mediaAsset(hash: ref.assetHash) == nil)
    await #expect(throws: MediaError.readFailed) {
        _ = try await context.media.resolve(ref)
    }
}

@Test func garbageCollectionHandlesMissingFiles() async throws {
    let context = try await makeMediaStore()
    let ref = try await context.media.ingest(data: pngBytes, kind: .image, fileExtension: "png")
    let saved = item(type: context.type, mediaFields: [(context.firstImage, ref)])
    _ = try await context.store.createItem(saved)
    let resolved = try await context.media.resolve(ref)
    try FileManager.default.removeItem(at: resolved)

    #expect(try await context.store.deleteItem(id: saved.id))
    #expect(try await context.store.mediaAsset(hash: ref.assetHash) == nil)
}

@Test func orphanDeletionRejectsTraversalComponents() async throws {
    let context = try await makeMediaStore()
    let mediaRoot = await context.media.rootDirectory
    let sentinel = mediaRoot.appendingPathComponent("sentinel.png")
    try pngBytes.write(to: sentinel)
    let hostile = MediaAsset(
        hash: "../../sentinel",
        kind: .image,
        byteSize: pngBytes.count,
        fileExtension: "png",
        createdAt: .now,
        refCount: 0
    )

    await #expect(throws: MediaError.sandboxViolation) {
        try await context.media.removeOrphan(hostile)
    }
    #expect(FileManager.default.fileExists(atPath: sentinel.path))
}

@Test func migrationV5BackfillsDuplicateReferences() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-media-migration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let databaseURL = root.appendingPathComponent("test.sqlite")
    let hash = String(repeating: "a", count: 64)
    let firstImage = FieldDef(name: "Image 1", type: .image)
    let secondImage = FieldDef(name: "Image 2", type: .image)
    let ref = MediaRef(kind: .image, assetHash: hash, fileExtension: "png")
    let fields = [
        FieldValue(fieldID: firstImage.id, value: .media(ref)),
        FieldValue(fieldID: secondImage.id, value: .media(ref)),
    ]
    try createV4Database(at: databaseURL, fields: fields, hash: hash)

    let store = try ItemStore(databaseURL: databaseURL)
    try await store.bootstrap()

    #expect(try await store.mediaAsset(hash: hash)?.refCount == 2)
}

private func createV4Database(at url: URL, fields: [FieldValue], hash: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path(percentEncoded: false), &database) == SQLITE_OK,
          let database
    else {
        throw DatabaseError.openFailed("Could not create migration fixture.")
    }
    defer { sqlite3_close(database) }
    let statements = [
        "CREATE TABLE schema_version (version INTEGER NOT NULL);",
        "INSERT INTO schema_version (version) VALUES (4);",
        "CREATE TABLE item_types (id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, definition BLOB NOT NULL);",
        "CREATE TABLE cards (id TEXT PRIMARY KEY NOT NULL);",
        """
        CREATE TABLE items (
            id TEXT PRIMARY KEY NOT NULL,
            item_type_id TEXT NOT NULL REFERENCES item_types(id),
            fields BLOB NOT NULL,
            tags BLOB NOT NULL,
            deck_id TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """,
        """
        CREATE TABLE media_assets (
            hash TEXT PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL,
            byte_size INTEGER NOT NULL,
            file_extension TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        """,
    ]
    for statement in statements {
        guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(database)))
        }
    }

    let itemType = BuiltInItemTypes.basic
    try insert(
        into: database,
        sql: "INSERT INTO item_types (id, name, definition) VALUES (?, ?, ?);",
        bindings: [
            .text(itemType.id.uuidString),
            .text(itemType.name),
            .blob(try JSONEncoder().encode(itemType)),
        ]
    )
    try insert(
        into: database,
        sql: """
        INSERT INTO items (id, item_type_id, fields, tags, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?);
        """,
        bindings: [
            .text(UUID().uuidString),
            .text(itemType.id.uuidString),
            .blob(try JSONEncoder().encode(fields)),
            .blob(try JSONEncoder().encode([String]())),
            .double(1_700_000_000),
            .double(1_700_000_000),
        ]
    )
    try insert(
        into: database,
        sql: """
        INSERT INTO media_assets (hash, kind, byte_size, file_extension, created_at)
        VALUES (?, ?, ?, ?, ?);
        """,
        bindings: [
            .text(hash),
            .text(MediaKind.image.rawValue),
            .integer(Int64(pngBytes.count)),
            .text("png"),
            .double(1_700_000_000),
        ]
    )
}

private enum TestBinding {
    case text(String)
    case blob(Data)
    case double(Double)
    case integer(Int64)
}

private func insert(into database: OpaquePointer, sql: String, bindings: [TestBinding]) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement
    else {
        throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    for (offset, binding) in bindings.enumerated() {
        let index = Int32(offset + 1)
        switch binding {
        case let .text(value):
            sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT_TEST)
        case let .blob(value):
            _ = value.withUnsafeBytes {
                sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT_TEST)
            }
        case let .double(value):
            sqlite3_bind_double(statement, index, value)
        case let .integer(value):
            sqlite3_bind_int64(statement, index, value)
        }
    }
    guard sqlite3_step(statement) == SQLITE_DONE else {
        throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(database)))
    }
}

private let SQLITE_TRANSIENT_TEST = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
