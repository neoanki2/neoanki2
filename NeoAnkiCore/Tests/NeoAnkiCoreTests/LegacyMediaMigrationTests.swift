import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import NeoAnkiCore

@Test(arguments: [4, 5, 6])
func legacyURLMediaMigrationPreservesItemsWithoutExternalReads(version: Int) async throws {
    let fixture = try makeLegacyMediaFixture(version: version)
    let store = try ItemStore(databaseURL: fixture.databaseURL, starterItemTypes: [])
    try await store.bootstrap()

    let fetched = try #require(await store.fetchItem(id: fixture.itemID))
    #expect(fetched.item.fields.count == 2)
    let trusted = try #require(mediaRef(fetched.item, fieldID: fixture.trustedFieldID))
    let missing = try #require(mediaRef(fetched.item, fieldID: fixture.externalFieldID))
    let media = try #require(await store.media)

    let trustedURL = try await media.resolve(trusted)
    #expect(try Data(contentsOf: trustedURL) == legacyPNGBytes)
    #expect(missing.altText?.contains("Re-import") == true)
    await #expect(throws: MediaError.readFailed) {
        _ = try await media.resolve(missing)
    }
    #expect(missing.assetHash != sha256Hex(legacyPNGBytes))
    #expect(try persistedFieldsText(at: fixture.databaseURL).contains("file://") == false)
    #expect(try schemaVersion(at: fixture.databaseURL) == Schema.version)
}

private let legacyPNGBytes = Data([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    0x00, 0x00, 0x00, 0x0D,
] + Array(repeating: UInt8(0), count: 8))

private struct LegacyFixture {
    let databaseURL: URL
    let itemID: UUID
    let trustedFieldID: UUID
    let externalFieldID: UUID
}

private func makeLegacyMediaFixture(version: Int) throws -> LegacyFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-legacy-v\(version)-\(UUID().uuidString)", isDirectory: true)
    let mediaDirectory = root.appendingPathComponent("media", isDirectory: true)
    try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
    let trustedURL = mediaDirectory.appendingPathComponent("legacy.png")
    let externalURL = root.appendingPathComponent("outside.png")
    try legacyPNGBytes.write(to: trustedURL)
    try legacyPNGBytes.write(to: externalURL)

    let databaseURL = root.appendingPathComponent("test.sqlite")
    let trustedField = FieldDef(name: "Trusted", type: .image)
    let externalField = FieldDef(name: "External", type: .image)
    let itemType = ItemType(
        name: "Legacy Media",
        fields: [trustedField, externalField],
        templates: []
    )
    let trustedRef = MediaRef(kind: .image, assetHash: String(repeating: "a", count: 64), fileExtension: "png")
    let externalRef = MediaRef(kind: .image, assetHash: String(repeating: "b", count: 64), fileExtension: "png")
    let fields = [
        FieldValue(fieldID: trustedField.id, value: .media(trustedRef)),
        FieldValue(fieldID: externalField.id, value: .media(externalRef)),
    ]
    let fieldsData = try legacyFieldsData(
        fields,
        URLsByReferenceID: [
            trustedRef.id: trustedURL,
            externalRef.id: externalURL,
        ]
    )
    let itemID = UUID()

    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path(percentEncoded: false), &database) == SQLITE_OK,
          let database
    else {
        throw DatabaseError.openFailed("Could not create legacy media fixture.")
    }
    defer { sqlite3_close(database) }
    var schema = """
    CREATE TABLE schema_version (version INTEGER NOT NULL);
    INSERT INTO schema_version VALUES (\(version));
    CREATE TABLE item_types (
        id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL,
        definition BLOB NOT NULL
    );
    CREATE TABLE items (
        id TEXT PRIMARY KEY NOT NULL,
        item_type_id TEXT NOT NULL REFERENCES item_types(id),
        fields BLOB NOT NULL,
        tags BLOB NOT NULL,
        deck_id TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );
    CREATE TABLE cards (
        id TEXT PRIMARY KEY NOT NULL,
        item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
        template_id TEXT NOT NULL,
        skill BLOB NOT NULL,
        memory BLOB NOT NULL,
        due_at REAL NOT NULL DEFAULT 0,
        is_suspended INTEGER NOT NULL DEFAULT 0,
        deck_id TEXT
    );
    CREATE TABLE review_logs (
        id TEXT PRIMARY KEY NOT NULL,
        card_id TEXT NOT NULL,
        reviewed_at REAL NOT NULL,
        log BLOB NOT NULL\(version >= 6 ? ", memory_before BLOB" : "")
    );
    CREATE INDEX idx_review_logs_card_id ON review_logs(card_id);
    CREATE TABLE decks (
        id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL,
        parent_id TEXT REFERENCES decks(id)
    );
    CREATE TABLE media_assets (
        hash TEXT PRIMARY KEY NOT NULL,
        kind TEXT NOT NULL,
        byte_size INTEGER NOT NULL,
        file_extension TEXT NOT NULL,
        created_at REAL NOT NULL
    );
    """
    if version >= 5 {
        schema += """
        CREATE TABLE app_metadata (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
        INSERT INTO app_metadata VALUES ('starter_item_types_seeded', '1');
        """
    }
    if version >= 6 {
        schema += """
        CREATE TABLE review_reverts (
            id TEXT PRIMARY KEY NOT NULL,
            review_log_id TEXT NOT NULL UNIQUE REFERENCES review_logs(id),
            reverted_at REAL NOT NULL
        );
        CREATE INDEX idx_review_reverts_log_id ON review_reverts(review_log_id);
        """
    }
    guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
        throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(database)))
    }
    try legacyInsert(
        database,
        sql: "INSERT INTO item_types (id, name, definition) VALUES (?, ?, ?);",
        values: [
            .text(itemType.id.uuidString),
            .text(itemType.name),
            .blob(try JSONEncoder().encode(itemType)),
        ]
    )
    try legacyInsert(
        database,
        sql: """
        INSERT INTO items (id, item_type_id, fields, tags, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?);
        """,
        values: [
            .text(itemID.uuidString),
            .text(itemType.id.uuidString),
            .blob(fieldsData),
            .blob(try JSONEncoder().encode([String]())),
            .double(1_700_000_000),
            .double(1_700_000_000),
        ]
    )
    return LegacyFixture(
        databaseURL: databaseURL,
        itemID: itemID,
        trustedFieldID: trustedField.id,
        externalFieldID: externalField.id
    )
}

private func legacyFieldsData(
    _ fields: [FieldValue],
    URLsByReferenceID URLs: [UUID: URL]
) throws -> Data {
    let current = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fields))
    func replace(_ value: Any) -> Any {
        if var dictionary = value as? [String: Any] {
            if let idText = dictionary["id"] as? String,
               let id = UUID(uuidString: idText),
               let URL = URLs[id]
            {
                dictionary.removeValue(forKey: "assetHash")
                dictionary.removeValue(forKey: "fileExtension")
                dictionary["url"] = URL.absoluteString
                return dictionary
            }
            for (key, child) in dictionary {
                dictionary[key] = replace(child)
            }
            return dictionary
        }
        if let array = value as? [Any] {
            return array.map(replace)
        }
        return value
    }
    return try JSONSerialization.data(withJSONObject: replace(current), options: [.sortedKeys])
}

private func mediaRef(_ item: Item, fieldID: UUID) -> MediaRef? {
    guard case let .media(ref)? = item.value(for: fieldID) else { return nil }
    return ref
}

private enum LegacyValue {
    case text(String)
    case blob(Data)
    case double(Double)
}

private func legacyInsert(
    _ database: OpaquePointer,
    sql: String,
    values: [LegacyValue]
) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement
    else {
        throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    for (offset, value) in values.enumerated() {
        let index = Int32(offset + 1)
        switch value {
        case let .text(text):
            sqlite3_bind_text(statement, index, text, -1, legacySQLiteTransient)
        case let .blob(data):
            _ = data.withUnsafeBytes {
                sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), legacySQLiteTransient)
            }
        case let .double(double):
            sqlite3_bind_double(statement, index, double)
        }
    }
    guard sqlite3_step(statement) == SQLITE_DONE else {
        throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(database)))
    }
}

private func persistedFieldsText(at URL: URL) throws -> String {
    try legacyRead(URL, sql: "SELECT CAST(fields AS TEXT) FROM items LIMIT 1;") {
        String(cString: sqlite3_column_text($0, 0))
    }
}

private func schemaVersion(at URL: URL) throws -> Int {
    try legacyRead(URL, sql: "SELECT version FROM schema_version LIMIT 1;") {
        Int(sqlite3_column_int64($0, 0))
    }
}

private func legacyRead<T>(_ URL: URL, sql: String, transform: (OpaquePointer) -> T) throws -> T {
    var database: OpaquePointer?
    guard sqlite3_open_v2(URL.path(percentEncoded: false), &database, SQLITE_OPEN_READONLY, nil)
            == SQLITE_OK,
          let database
    else {
        throw DatabaseError.openFailed("Could not inspect legacy fixture.")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement,
          sqlite3_step(statement) == SQLITE_ROW
    else {
        throw DatabaseError.queryFailed("Could not inspect legacy fixture.")
    }
    defer { sqlite3_finalize(statement) }
    return transform(statement)
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private let legacySQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
