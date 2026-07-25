import Foundation
import SQLite3
import Testing
@testable import NeoAnkiCore

@Test func freshDatabaseCreatesCurrentSchema() async throws {
    let url = migrationDatabaseURL()
    let database = try SQLiteDatabase(path: url)

    try await database.migrate()

    #expect(try integer("SELECT version FROM schema_version;", at: url) == Schema.version)
    #expect(try tableExists("media_assets", at: url))
    #expect(try tableExists("review_reverts", at: url))
    #expect(try columnExists("memory_before", in: "review_logs", at: url))
}

@Test func versionOneMigrationBackfillsDueDateAndReachesCurrentSchema() async throws {
    let url = migrationDatabaseURL()
    let memory = MemoryState(due: Date(timeIntervalSince1970: 1_725_000_000))
    let memoryHex = try JSONEncoder().encode(memory).map { String(format: "%02x", $0) }.joined()
    try executeMigrationSQL(
        """
        CREATE TABLE schema_version (version INTEGER NOT NULL);
        INSERT INTO schema_version VALUES (1);
        CREATE TABLE cards (
            id TEXT PRIMARY KEY NOT NULL,
            memory BLOB NOT NULL
        );
        INSERT INTO cards (id, memory) VALUES ('\(UUID().uuidString)', X'\(memoryHex)');
        """,
        at: url
    )
    let database = try SQLiteDatabase(path: url)

    try await database.migrate()

    #expect(try integer("SELECT version FROM schema_version;", at: url) == Schema.version)
    #expect(try double("SELECT due_at FROM cards LIMIT 1;", at: url) == memory.due.timeIntervalSince1970)
    #expect(try tableExists("media_assets", at: url))
    #expect(try tableExists("review_reverts", at: url))
}

@Test func versionFourMigrationPreservesRawReviewHistory() async throws {
    let url = migrationDatabaseURL()
    let logID = UUID()
    let cardID = UUID()
    try executeMigrationSQL(
        """
        CREATE TABLE schema_version (version INTEGER NOT NULL);
        INSERT INTO schema_version VALUES (4);
        CREATE TABLE review_logs (
            id TEXT PRIMARY KEY NOT NULL,
            card_id TEXT NOT NULL,
            reviewed_at REAL NOT NULL,
            log BLOB NOT NULL
        );
        CREATE INDEX idx_review_logs_card_id ON review_logs(card_id);
        INSERT INTO review_logs VALUES (
            '\(logID.uuidString)',
            '\(cardID.uuidString)',
            1725000000,
            X'7b7d'
        );
        """,
        at: url
    )
    let database = try SQLiteDatabase(path: url)

    try await database.migrate()

    #expect(try integer("SELECT version FROM schema_version;", at: url) == Schema.version)
    #expect(try integer("SELECT COUNT(*) FROM review_logs;", at: url) == 1)
    #expect(try columnExists("memory_before", in: "review_logs", at: url))
    #expect(try tableExists("review_reverts", at: url))
}

@Test func failedMigrationRollsBackSchemaAndVersion() async throws {
    let url = migrationDatabaseURL()
    try executeMigrationSQL(
        """
        CREATE TABLE schema_version (version INTEGER NOT NULL);
        INSERT INTO schema_version VALUES (4);
        CREATE TABLE review_logs (
            id TEXT PRIMARY KEY NOT NULL,
            card_id TEXT NOT NULL,
            reviewed_at REAL NOT NULL
        );
        """,
        at: url
    )
    let database = try SQLiteDatabase(path: url)

    await #expect(throws: DatabaseError.self) {
        try await database.migrate()
    }

    #expect(try integer("SELECT version FROM schema_version;", at: url) == 4)
    #expect(try tableExists("review_logs", at: url))
    #expect(try !tableExists("review_logs_v5", at: url))
    #expect(try !tableExists("review_reverts", at: url))
}

@Test func newerSchemaFailsLoudWithoutMutation() async throws {
    let url = migrationDatabaseURL()
    let newerVersion = Schema.version + 1
    try executeMigrationSQL(
        """
        CREATE TABLE schema_version (version INTEGER NOT NULL);
        INSERT INTO schema_version VALUES (\(newerVersion));
        """,
        at: url
    )
    let database = try SQLiteDatabase(path: url)

    await #expect(throws: DatabaseError.unsupportedSchemaVersion(newerVersion)) {
        try await database.migrate()
    }

    #expect(try !tableExists("item_types", at: url))
    #expect(try integer("SELECT version FROM schema_version;", at: url) == newerVersion)
}

@Test func corruptSchemaVersionReadDoesNotRecreateDatabase() async throws {
    let url = migrationDatabaseURL()
    try executeMigrationSQL(
        """
        CREATE TABLE schema_version (corrupt TEXT NOT NULL);
        INSERT INTO schema_version VALUES ('not-a-version');
        """,
        at: url
    )
    let database = try SQLiteDatabase(path: url)

    await #expect(throws: DatabaseError.schemaVersionReadFailed) {
        try await database.migrate()
    }

    #expect(try !tableExists("item_types", at: url))
    #expect(try !columnExists("version", in: "schema_version", at: url))
}

private func migrationDatabaseURL() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-migration-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("test.sqlite")
}

private func executeMigrationSQL(_ sql: String, at url: URL) throws {
    try withMigrationDatabase(at: url) { database in
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(database)))
        }
    }
}

private func tableExists(_ name: String, at url: URL) throws -> Bool {
    try integer(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '\(name)';",
        at: url
    ) == 1
}

private func columnExists(_ column: String, in table: String, at url: URL) throws -> Bool {
    try withMigrationDatabase(at: url) { database in
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table));", -1, &statement, nil)
            == SQLITE_OK,
            let statement
        else {
            throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 1) else { continue }
            if String(cString: name) == column {
                return true
            }
        }
        return false
    }
}

private func integer(_ sql: String, at url: URL) throws -> Int {
    try withMigrationDatabase(at: url) { database in
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }
        return Int(sqlite3_column_int64(statement, 0))
    }
}

private func double(_ sql: String, at url: URL) throws -> Double {
    try withMigrationDatabase(at: url) { database in
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }
        return sqlite3_column_double(statement, 0)
    }
}

private func withMigrationDatabase<T>(
    at url: URL,
    _ body: (OpaquePointer) throws -> T
) throws -> T {
    var database: OpaquePointer?
    guard sqlite3_open(url.path(percentEncoded: false), &database) == SQLITE_OK,
          let database
    else {
        throw DatabaseError.openFailed("Could not open migration test database.")
    }
    defer { sqlite3_close(database) }
    return try body(database)
}
