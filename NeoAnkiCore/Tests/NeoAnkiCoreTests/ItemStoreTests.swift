import Foundation
import SQLite3
import Testing
@testable import NeoAnkiCore

private func tempDatabaseURL() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("test.sqlite")
}

private func makeStore() async throws -> ItemStore {
    let store = try ItemStore(databaseURL: tempDatabaseURL())
    try await store.bootstrap()
    return store
}

@Test func bootstrapSeedsBasicItemType() async throws {
    let store = try await makeStore()

    let itemType = try await store.defaultItemType()

    #expect(itemType.id == BuiltInItemTypes.basicID)
    #expect(itemType.name == "Basic")
    #expect(itemType.fields.map(\.name) == ["Front", "Back"])
    #expect(itemType.templates.count == 1)
    #expect(itemType.templates.first?.interaction == .reveal)
}

@Test func createItemPersistsItemAndGeneratedCards() async throws {
    let store = try await makeStore()
    let itemType = try await store.defaultItemType()
    let item = Item(
        itemTypeID: itemType.id,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Question")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
        ]
    )

    let saved = try await store.createItem(item)
    let listed = try await store.listItems()

    #expect(saved.title == "Question")
    #expect(saved.subtitle == "Answer")
    #expect(saved.cardCount == 1)
    #expect(listed.count == 1)
    #expect(listed.first?.id == item.id)
    #expect(listed.first?.cardCount == 1)
}

@Test func deleteItemRemovesItemAndCards() async throws {
    let store = try await makeStore()
    let itemType = try await store.defaultItemType()
    let item = Item(
        itemTypeID: itemType.id,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Question")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
        ]
    )

    _ = try await store.createItem(item)
    #expect(try await store.listItems().count == 1)
    #expect(try await store.dueCount() == 1)

    let deleted = try await store.deleteItem(id: item.id)
    #expect(deleted == true)
    #expect(try await store.listItems().isEmpty)
    #expect(try await store.dueCount() == 0)
    #expect(try await store.fetchItem(id: item.id) == nil)
    #expect(try await store.deleteItem(id: item.id) == false)
}

@Test func deleteItemTypeRemovesUnusedType() async throws {
    let store = try await makeStore()
    let itemType = try ItemTypeBuilder.makeItemType(
        name: "Temporary",
        fields: [
            FieldDef(name: "A", type: .text, isRequired: true),
            FieldDef(name: "B", type: .text, isRequired: true),
        ]
    )
    let created = try await store.createItemType(itemType)

    #expect(try await store.deleteItemType(id: created.id) == true)
    #expect(try await store.listItemTypes().map(\.name).contains("Temporary") == false)
}

@Test func deleteItemTypeRejectsBuiltInType() async throws {
    let store = try await makeStore()

    await #expect(throws: DatabaseError.invalidItemType("Built-in item types can't be deleted.")) {
        try await store.deleteItemType(id: BuiltInItemTypes.basicID)
    }
}

@Test func deleteItemTypeRejectsTypeWithItems() async throws {
    let store = try await makeStore()
    let itemType = try ItemTypeBuilder.makeItemType(
        name: "Occupied",
        fields: [
            FieldDef(name: "A", type: .text, isRequired: true),
            FieldDef(name: "B", type: .text, isRequired: true),
        ]
    )
    let created = try await store.createItemType(itemType)
    let item = Item(
        itemTypeID: created.id,
        fields: [
            FieldValue(fieldID: created.fields[0].id, value: .text("Front")),
            FieldValue(fieldID: created.fields[1].id, value: .text("Back")),
        ]
    )
    _ = try await store.createItem(item)

    await #expect(throws: DatabaseError.invalidItemType("Remove all items of this type before deleting it.")) {
        try await store.deleteItemType(id: created.id)
    }
}

@Test func itemsSurviveStoreReopen() async throws {
    let databaseURL = tempDatabaseURL()
    let itemID: UUID

    do {
        let store = try ItemStore(databaseURL: databaseURL)
        try await store.bootstrap()
        let itemType = try await store.defaultItemType()
        let item = Item(
            itemTypeID: itemType.id,
            fields: [
                FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Front")),
                FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Back")),
            ]
        )
        itemID = item.id
        _ = try await store.createItem(item)
    }

    let reopened = try ItemStore(databaseURL: databaseURL)
    try await reopened.bootstrap()
    let listed = try await reopened.listItems()

    #expect(listed.count == 1)
    #expect(listed.first?.id == itemID)
    #expect(listed.first?.title == "Front")
    #expect(listed.first?.subtitle == "Back")
}

@Test func requiredFieldsMustBePresent() async throws {
    let store = try await makeStore()
    let itemType = try await store.defaultItemType()
    let item = Item(
        itemTypeID: itemType.id,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Only front")),
        ]
    )

    await #expect(throws: DatabaseError.requiredFieldEmpty("Back")) {
        try await store.createItem(item)
    }
}

@Test func migratesLegacyNoteSchema() async throws {
    let databaseURL = tempDatabaseURL()
    try createLegacyNoteDatabase(at: databaseURL)

    let store = try ItemStore(databaseURL: databaseURL)
    try await store.bootstrap()

    let items = try await store.listItems()
    #expect(items.count == 1)
    #expect(items.first?.title == "Legacy front")
    #expect(items.first?.subtitle == "Legacy back")
}

private func createLegacyNoteDatabase(at url: URL) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path(percentEncoded: false), &db) == SQLITE_OK, let db else {
        throw DatabaseError.openFailed("Could not create legacy test database.")
    }
    defer { sqlite3_close(db) }

    let statements = [
        """
        CREATE TABLE schema_version (version INTEGER NOT NULL);
        INSERT INTO schema_version (version) VALUES (2);
        """,
        """
        CREATE TABLE note_types (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            definition BLOB NOT NULL
        );
        """,
        """
        CREATE TABLE notes (
            id TEXT PRIMARY KEY NOT NULL,
            note_type_id TEXT NOT NULL REFERENCES note_types(id),
            fields BLOB NOT NULL,
            tags BLOB NOT NULL,
            deck_id TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """,
        """
        CREATE TABLE cards (
            id TEXT PRIMARY KEY NOT NULL,
            note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            template_id TEXT NOT NULL,
            skill BLOB NOT NULL,
            memory BLOB NOT NULL,
            is_suspended INTEGER NOT NULL DEFAULT 0,
            deck_id TEXT,
            due_at REAL NOT NULL DEFAULT 0
        );
        """,
    ]

    for sql in statements {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    let itemType = BuiltInItemTypes.basic
    let itemTypeData = try JSONEncoder().encode(itemType)
    let itemID = UUID()
    let cardID = UUID()
    let templateID = itemType.templates[0].id
    let fields = [
        FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Legacy front")),
        FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Legacy back")),
    ]
    let fieldsData = try JSONEncoder().encode(fields)
    let tagsData = try JSONEncoder().encode([String]())
    let skillData = try JSONEncoder().encode(Skill(input: .text, output: .text, operation: .recognize))
    let memory = MemoryState(due: Date(timeIntervalSince1970: 1_700_000_000))
    let memoryData = try JSONEncoder().encode(memory)

    try bindAndRun(
        db,
        sql: "INSERT INTO note_types (id, name, definition) VALUES (?, ?, ?);",
        itemType.id.uuidString,
        itemType.name,
        itemTypeData
    )
    try bindAndRun(
        db,
        sql: """
        INSERT INTO notes (id, note_type_id, fields, tags, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?);
        """,
        itemID.uuidString,
        itemType.id.uuidString,
        fieldsData,
        tagsData,
        1_700_000_000.0,
        1_700_000_000.0
    )
    try bindAndRun(
        db,
        sql: """
        INSERT INTO cards (id, note_id, template_id, skill, memory, due_at)
        VALUES (?, ?, ?, ?, ?, ?);
        """,
        cardID.uuidString,
        itemID.uuidString,
        templateID.uuidString,
        skillData,
        memoryData,
        1_700_000_000.0
    )
}

private func bindAndRun(
    _ db: OpaquePointer,
    sql: String,
    _ text1: String,
    _ text2: String,
    _ blob: Data
) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, text1, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    sqlite3_bind_text(statement, 2, text2, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    blob.withUnsafeBytes { buffer in
        sqlite3_bind_blob(statement, 3, buffer.baseAddress, Int32(buffer.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    guard sqlite3_step(statement) == SQLITE_DONE else {
        throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(db)))
    }
}

private func bindAndRun(
    _ db: OpaquePointer,
    sql: String,
    _ text1: String,
    _ text2: String,
    _ blob1: Data,
    _ blob2: Data,
    _ double1: Double,
    _ double2: Double
) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, text1, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    sqlite3_bind_text(statement, 2, text2, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    blob1.withUnsafeBytes { buffer in
        sqlite3_bind_blob(statement, 3, buffer.baseAddress, Int32(buffer.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    blob2.withUnsafeBytes { buffer in
        sqlite3_bind_blob(statement, 4, buffer.baseAddress, Int32(buffer.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    sqlite3_bind_double(statement, 5, double1)
    sqlite3_bind_double(statement, 6, double2)
    guard sqlite3_step(statement) == SQLITE_DONE else {
        throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(db)))
    }
}

private func bindAndRun(
    _ db: OpaquePointer,
    sql: String,
    _ text1: String,
    _ text2: String,
    _ text3: String,
    _ blob1: Data,
    _ blob2: Data,
    _ double1: Double
) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, text1, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    sqlite3_bind_text(statement, 2, text2, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    sqlite3_bind_text(statement, 3, text3, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    blob1.withUnsafeBytes { buffer in
        sqlite3_bind_blob(statement, 4, buffer.baseAddress, Int32(buffer.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    blob2.withUnsafeBytes { buffer in
        sqlite3_bind_blob(statement, 5, buffer.baseAddress, Int32(buffer.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    sqlite3_bind_double(statement, 6, double1)
    guard sqlite3_step(statement) == SQLITE_DONE else {
        throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(db)))
    }
}
