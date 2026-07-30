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
    #expect(try columnExists("sequence", in: "review_logs", at: url))
    #expect(try columnExists("cloze_group", in: "cards", at: url))
    #expect(try tableExists("media_reservations", at: url))
    #expect(try tableExists("portable_item_type_mappings", at: url))
    #expect(try tableExists("new_card_introductions", at: url))
    #expect(try indexExists("idx_new_card_introductions_day_deck_log", at: url))
    #expect(try indexExists("idx_cards_active_new_due", at: url))
    #expect(try columnExists("new_cards_per_day", in: "decks", at: url))
    #expect(try tableExists("library_item_types", at: url))
    #expect(try tableExists("deck_included_item_types", at: url))
    #expect(try tableExists("deck_item_type_policy_entries", at: url))
    let firstLibraryID = try await database.getOrCreateLibraryID()
    let secondLibraryID = try await database.getOrCreateLibraryID()
    #expect(firstLibraryID == secondLibraryID)
}

@Test func versionNineteenMigrationAddsBoundedNewCardIndexWithoutChangingRows() async throws {
    let url = migrationDatabaseURL()
    let cardID = UUID()
    try executeMigrationSQL(
        """
        CREATE TABLE schema_version (version INTEGER NOT NULL);
        INSERT INTO schema_version VALUES (19);
        CREATE TABLE app_metadata (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        CREATE TABLE cards (
            id TEXT PRIMARY KEY NOT NULL,
            due_at REAL NOT NULL,
            phase TEXT NOT NULL,
            is_suspended INTEGER NOT NULL
        );
        INSERT INTO cards VALUES ('\(cardID.uuidString)', 100, 'new', 0);
        """,
        at: url
    )
    let database = try SQLiteDatabase(path: url)

    try await database.migrate()

    #expect(try integer("SELECT version FROM schema_version;", at: url) == Schema.version)
    #expect(try indexExists("idx_cards_active_new_due", at: url))
    #expect(try integer("SELECT COUNT(*) FROM cards;", at: url) == 1)
}

@Test func versionTwentyMigrationFailureRollsBackVersionAndIndex() async throws {
    let url = migrationDatabaseURL()
    try executeMigrationSQL(
        """
        CREATE TABLE schema_version (version INTEGER NOT NULL);
        INSERT INTO schema_version VALUES (19);
        CREATE TABLE app_metadata (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        CREATE TABLE cards (
            id TEXT PRIMARY KEY NOT NULL,
            due_at REAL NOT NULL,
            phase TEXT NOT NULL,
            is_suspended INTEGER NOT NULL
        );
        CREATE TABLE idx_cards_active_new_due (collision INTEGER);
        """,
        at: url
    )
    let database = try SQLiteDatabase(path: url)

    await #expect(throws: DatabaseError.self) {
        try await database.migrate()
    }

    #expect(try integer("SELECT version FROM schema_version;", at: url) == 19)
    #expect(try !indexExists("idx_cards_active_new_due", at: url))
}

@Test func versionEighteenMigrationAddsStudyDayIntroductionIndexWithoutChangingRows() async throws {
    let url = migrationDatabaseURL()
    let reviewLogID = UUID()
    let deckID = UUID()
    try executeMigrationSQL(
        """
        CREATE TABLE schema_version (version INTEGER NOT NULL);
        INSERT INTO schema_version VALUES (18);
        CREATE TABLE app_metadata (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        CREATE TABLE new_card_introductions (
            review_log_id TEXT PRIMARY KEY NOT NULL,
            deck_id TEXT NOT NULL,
            study_day TEXT NOT NULL
        );
        INSERT INTO new_card_introductions
        VALUES ('\(reviewLogID.uuidString)', '\(deckID.uuidString)', '2027-01-15');
        """,
        at: url
    )
    let database = try SQLiteDatabase(path: url)

    try await database.migrate()

    #expect(try integer("SELECT version FROM schema_version;", at: url) == Schema.version)
    #expect(try indexExists("idx_new_card_introductions_day_deck_log", at: url))
    #expect(try integer("SELECT COUNT(*) FROM new_card_introductions;", at: url) == 1)
}

@Test func versionNineteenMigrationFailureRollsBackVersionAndIndex() async throws {
    let url = migrationDatabaseURL()
    try executeMigrationSQL(
        """
        CREATE TABLE schema_version (version INTEGER NOT NULL);
        INSERT INTO schema_version VALUES (18);
        CREATE TABLE app_metadata (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        CREATE TABLE new_card_introductions (
            review_log_id TEXT PRIMARY KEY NOT NULL,
            deck_id TEXT NOT NULL
        );
        """,
        at: url
    )
    let database = try SQLiteDatabase(path: url)

    await #expect(throws: DatabaseError.self) {
        try await database.migrate()
    }

    #expect(try integer("SELECT version FROM schema_version;", at: url) == 18)
    #expect(try !indexExists("idx_new_card_introductions_day_deck_log", at: url))
}

@Test func versionEighteenMigrationKeepsEveryExistingTypeNormal() async throws {
    let url = migrationDatabaseURL()
    let first = UUID()
    let second = UUID()
    try executeMigrationSQL(
        """
        CREATE TABLE schema_version (version INTEGER NOT NULL);
        INSERT INTO schema_version VALUES (17);
        CREATE TABLE item_types (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            definition BLOB NOT NULL
        );
        CREATE TABLE decks (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            parent_id TEXT REFERENCES decks(id),
            new_cards_per_day INTEGER
        );
        INSERT INTO item_types VALUES ('\(first.uuidString)', 'First', X'7b7d');
        INSERT INTO item_types VALUES ('\(second.uuidString)', 'Second', X'7b7d');
        """,
        at: url
    )
    let database = try SQLiteDatabase(path: url)

    try await database.migrate()

    #expect(try integer("SELECT version FROM schema_version;", at: url) == Schema.version)
    #expect(try integer("SELECT COUNT(*) FROM item_types;", at: url) == 2)
    #expect(try integer("SELECT COUNT(*) FROM library_item_types;", at: url) == 2)
    #expect(try integer("SELECT COUNT(*) FROM deck_included_item_types;", at: url) == 0)
    #expect(try integer("SELECT COUNT(*) FROM deck_item_type_policy_entries;", at: url) == 0)
}

@Test func versionFourteenMigrationAddsUnlimitedDeckLimits() async throws {
    let url = migrationDatabaseURL()
    let deckID = UUID()
    try executeMigrationSQL(
        """
        CREATE TABLE schema_version (version INTEGER NOT NULL);
        INSERT INTO schema_version VALUES (14);
        CREATE TABLE app_metadata (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        CREATE TABLE review_logs (
            id TEXT PRIMARY KEY NOT NULL,
            card_id TEXT NOT NULL,
            reviewed_at REAL NOT NULL,
            log BLOB NOT NULL,
            memory_before BLOB NOT NULL,
            sequence INTEGER NOT NULL UNIQUE
        );
        CREATE TABLE decks (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            parent_id TEXT REFERENCES decks(id)
        );
        INSERT INTO decks VALUES ('\(deckID.uuidString)', 'Existing', NULL);
        """,
        at: url
    )
    let database = try SQLiteDatabase(path: url)

    try await database.migrate()

    #expect(try columnExists("new_cards_per_day", in: "decks", at: url))
    #expect(try tableExists("new_card_introductions", at: url))
    #expect(try integer(
        "SELECT COUNT(*) FROM decks WHERE id = '\(deckID.uuidString)' AND new_cards_per_day IS NULL;",
        at: url
    ) == 1)
}

@Test func versionTwelveMigrationPreservesLibraryIdentityAndAddsPortableMappings() async throws {
    let url = migrationDatabaseURL()
    let libraryID = UUID()
    try executeMigrationSQL(
        """
        CREATE TABLE schema_version (version INTEGER NOT NULL);
        INSERT INTO schema_version VALUES (12);
        CREATE TABLE app_metadata (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        INSERT INTO app_metadata VALUES ('library_id', '\(libraryID.uuidString)');
        CREATE TABLE item_types (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            definition BLOB NOT NULL
        );
        """,
        at: url
    )
    let database = try SQLiteDatabase(path: url)

    try await database.migrate()

    #expect(try integer("SELECT version FROM schema_version;", at: url) == Schema.version)
    #expect(try tableExists("portable_item_type_mappings", at: url))
    #expect(try await database.getOrCreateLibraryID() == libraryID)
    #expect(try integer(
        """
        SELECT COUNT(*) FROM sqlite_master
        WHERE type = 'index' AND name = 'idx_portable_item_type_mappings_digest';
        """,
        at: url
    ) == 1)
}

@Test func versionNineMigrationBackfillsStableReviewAppendOrder() async throws {
    let url = migrationDatabaseURL()
    let firstID = UUID(uuidString: "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF")!
    let secondID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    try executeMigrationSQL(
        """
        CREATE TABLE schema_version (version INTEGER NOT NULL);
        INSERT INTO schema_version VALUES (9);
        CREATE TABLE review_logs (
            id TEXT PRIMARY KEY NOT NULL,
            card_id TEXT NOT NULL,
            reviewed_at REAL NOT NULL,
            log BLOB NOT NULL,
            memory_before BLOB
        );
        INSERT INTO review_logs VALUES (
            '\(firstID.uuidString)', '\(UUID().uuidString)', 100, X'7b7d', NULL
        );
        INSERT INTO review_logs VALUES (
            '\(secondID.uuidString)', '\(UUID().uuidString)', 100, X'7b7d', NULL
        );
        CREATE TABLE media_assets (
            hash TEXT PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL,
            byte_size INTEGER NOT NULL,
            file_extension TEXT NOT NULL,
            created_at REAL NOT NULL,
            ref_count INTEGER NOT NULL DEFAULT 0
        );
        """,
        at: url
    )
    let database = try SQLiteDatabase(path: url)

    try await database.migrate()

    #expect(try integer(
        "SELECT sequence FROM review_logs WHERE id = '\(firstID.uuidString)';",
        at: url
    ) == 1)
    #expect(try integer(
        "SELECT sequence FROM review_logs WHERE id = '\(secondID.uuidString)';",
        at: url
    ) == 2)
    #expect(try tableExists("media_reservations", at: url))
    #expect(try integer("SELECT version FROM schema_version;", at: url) == Schema.version)
}

@Test func versionEightMigrationAddsClozeGroupsWithoutChangingExistingCards() async throws {
    let url = migrationDatabaseURL()
    let cardID = UUID()
    try executeMigrationSQL(
        """
        CREATE TABLE schema_version (version INTEGER NOT NULL);
        INSERT INTO schema_version VALUES (8);
        CREATE TABLE cards (
            id TEXT PRIMARY KEY NOT NULL,
            item_id TEXT NOT NULL,
            template_id TEXT NOT NULL,
            skill BLOB NOT NULL,
            memory BLOB NOT NULL,
            due_at REAL NOT NULL DEFAULT 0,
            is_suspended INTEGER NOT NULL DEFAULT 0,
            deck_id TEXT
        );
        INSERT INTO cards (
            id, item_id, template_id, skill, memory, due_at, is_suspended, deck_id
        ) VALUES (
            '\(cardID.uuidString)', '\(UUID().uuidString)', '\(UUID().uuidString)',
            X'7b7d', X'7b7d', 0, 0, NULL
        );
        """,
        at: url
    )
    let database = try SQLiteDatabase(path: url)

    try await database.migrate()

    #expect(try integer("SELECT version FROM schema_version;", at: url) == Schema.version)
    #expect(try columnExists("cloze_group", in: "cards", at: url))
    #expect(try integer("SELECT COUNT(*) FROM cards;", at: url) == 1)
}

@Test func versionThirteenMigrationBackfillsPhaseAndLapsesFromMemory() async throws {
    let url = migrationDatabaseURL()
    let reviewID = UUID()
    let newID = UUID()
    let reviewMemory = MemoryState(
        stability: 12,
        difficulty: 6,
        due: Date(timeIntervalSince1970: 1_725_000_000),
        lastReview: Date(timeIntervalSince1970: 1_724_000_000),
        reps: 9,
        lapses: 3,
        phase: .review
    )
    let reviewHex = try memoryHex(reviewMemory)
    let newHex = try memoryHex(MemoryState(due: Date(timeIntervalSince1970: 1_726_000_000)))
    try executeMigrationSQL(
        """
        CREATE TABLE schema_version (version INTEGER NOT NULL);
        INSERT INTO schema_version VALUES (13);
        CREATE TABLE cards (
            id TEXT PRIMARY KEY NOT NULL,
            item_id TEXT NOT NULL,
            template_id TEXT NOT NULL,
            skill BLOB NOT NULL,
            memory BLOB NOT NULL,
            due_at REAL NOT NULL DEFAULT 0,
            is_suspended INTEGER NOT NULL DEFAULT 0,
            deck_id TEXT,
            cloze_group INTEGER
        );
        INSERT INTO cards (id, item_id, template_id, skill, memory, due_at)
        VALUES (
            '\(reviewID.uuidString)', '\(UUID().uuidString)', '\(UUID().uuidString)',
            X'7b7d', X'\(reviewHex)', \(reviewMemory.due.timeIntervalSince1970)
        );
        INSERT INTO cards (id, item_id, template_id, skill, memory, due_at)
        VALUES (
            '\(newID.uuidString)', '\(UUID().uuidString)', '\(UUID().uuidString)',
            X'7b7d', X'\(newHex)', 1726000000
        );
        """,
        at: url
    )
    let database = try SQLiteDatabase(path: url)

    try await database.migrate()

    #expect(try integer("SELECT version FROM schema_version;", at: url) == Schema.version)
    #expect(try columnExists("phase", in: "cards", at: url))
    #expect(try columnExists("lapses", in: "cards", at: url))
    #expect(try text(
        "SELECT phase FROM cards WHERE id = '\(reviewID.uuidString)';",
        at: url
    ) == "review")
    #expect(try integer(
        "SELECT lapses FROM cards WHERE id = '\(reviewID.uuidString)';",
        at: url
    ) == 3)
    #expect(try text("SELECT phase FROM cards WHERE id = '\(newID.uuidString)';", at: url) == "new")
    #expect(try integer(
        "SELECT lapses FROM cards WHERE id = '\(newID.uuidString)';",
        at: url
    ) == 0)
    #expect(try integer(
        """
        SELECT COUNT(*) FROM sqlite_master
        WHERE type = 'index' AND name = 'idx_cards_phase';
        """,
        at: url
    ) == 1)
}

@Test func versionThirteenMigrationSurvivesUndecodableMemory() async throws {
    let url = migrationDatabaseURL()
    let cardID = UUID()
    try executeMigrationSQL(
        """
        CREATE TABLE schema_version (version INTEGER NOT NULL);
        INSERT INTO schema_version VALUES (13);
        CREATE TABLE cards (
            id TEXT PRIMARY KEY NOT NULL,
            item_id TEXT NOT NULL,
            template_id TEXT NOT NULL,
            skill BLOB NOT NULL,
            memory BLOB NOT NULL,
            due_at REAL NOT NULL DEFAULT 0,
            is_suspended INTEGER NOT NULL DEFAULT 0,
            deck_id TEXT,
            cloze_group INTEGER
        );
        INSERT INTO cards (id, item_id, template_id, skill, memory, due_at)
        VALUES (
            '\(cardID.uuidString)', '\(UUID().uuidString)', '\(UUID().uuidString)',
            X'7b7d', X'7b7d', 0
        );
        """,
        at: url
    )
    let database = try SQLiteDatabase(path: url)

    try await database.migrate()

    #expect(try integer("SELECT version FROM schema_version;", at: url) == Schema.version)
    #expect(try text("SELECT phase FROM cards WHERE id = '\(cardID.uuidString)';", at: url) == "new")
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
        CREATE TABLE cards (
            id TEXT PRIMARY KEY NOT NULL
        );
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

private func indexExists(_ name: String, at url: URL) throws -> Bool {
    try integer(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = '\(name)';",
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

private func text(_ sql: String, at url: URL) throws -> String {
    try withMigrationDatabase(at: url) { database in
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0)
        else {
            throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }
        return String(cString: value)
    }
}

private func memoryHex(_ memory: MemoryState) throws -> String {
    try JSONEncoder().encode(memory).map { String(format: "%02x", $0) }.joined()
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
