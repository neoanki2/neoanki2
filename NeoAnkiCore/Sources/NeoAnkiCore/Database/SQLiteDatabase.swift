import CryptoKit
import Darwin
import Foundation
import SQLite3

private struct SchedulerWeightEnvelope: Decodable {
    let weights: [Double]
}

public enum DatabaseError: Error, Sendable, Equatable, LocalizedError {
    case openFailed(String)
    case executeFailed(String)
    case queryFailed(String)
    case itemTypeNotFound(UUID)
    case itemNotFound(UUID)
    case cardNotFound(UUID)
    case reviewLogNotFound(UUID)
    case studyResponseNotFound(UUID)
    case templateNotFound(UUID)
    case deckNotFound(UUID)
    case requiredFieldEmpty(String)
    case invalidItemType(String)
    case invalidItem(String)
    case invalidDeck(String)
    case resourceInUse(String)
    case invalidMediaAsset(String)
    case idempotencyConflict
    case idempotencyRecordNotFound
    case studySessionNotFound(UUID)
    case studyConflict(String)
    case encodingFailed
    case decodingFailed
    case unsupportedSchemaVersion(Int)
    case schemaVersionReadFailed
    case templateDefinitionMigrationRequired

    public var errorDescription: String? {
        switch self {
        case let .openFailed(message):
            return "Could not open database: \(message)"
        case let .executeFailed(message):
            return "Database write failed: \(message)"
        case let .queryFailed(message):
            return "Database read failed: \(message)"
        case let .itemTypeNotFound(id):
            return "Item type not found: \(id.uuidString)"
        case let .itemNotFound(id):
            return "Item not found: \(id.uuidString)"
        case let .cardNotFound(id):
            return "Card not found: \(id.uuidString)"
        case let .reviewLogNotFound(id):
            return "Review log not found: \(id.uuidString)"
        case let .studyResponseNotFound(id):
            return "Study response not found: \(id.uuidString)"
        case let .templateNotFound(id):
            return "Template not found: \(id.uuidString)"
        case let .deckNotFound(id):
            return "Deck not found: \(id.uuidString)"
        case let .requiredFieldEmpty(name):
            return "\(name) is required."
        case let .invalidItemType(message):
            return message
        case let .invalidItem(message):
            return message
        case let .invalidDeck(message):
            return message
        case let .resourceInUse(message):
            return message
        case let .invalidMediaAsset(message):
            return message
        case .idempotencyConflict:
            return "The idempotency key was already used for different input."
        case .idempotencyRecordNotFound:
            return "The idempotency record no longer exists."
        case let .studySessionNotFound(id):
            return "Study session not found: \(id.uuidString)"
        case let .studyConflict(message):
            return message
        case .encodingFailed:
            return "Could not encode data for storage."
        case .decodingFailed:
            return "Could not decode stored data."
        case let .unsupportedSchemaVersion(version):
            return "Database schema version \(version) is newer than this app supports."
        case .schemaVersionReadFailed:
            return "Could not read the database schema version."
        case .templateDefinitionMigrationRequired:
            return "This library uses the earlier template format. Run neoanki-template-migrator before opening it."
        }
    }
}

struct PersistedItem: Sendable {
    var item: Item
    var createdAt: Date
    var updatedAt: Date
}

struct DatabaseCacheToken: Sendable, Equatable {
    let localRevision: UInt64
    let dataVersion: Int64
}

private struct SingleNewCardLimiter {
    let deckIDs: [String]
    let remainingCapacity: Int
}

private struct MultipleNewCardLimiters {
    /// Absolute deck depths, deepest first. Applying child limits before their
    /// ancestors lets a rejected child candidate be backfilled by a sibling.
    let depths: [Int]
}

private enum NewCardLimitShape {
    case none
    case single(SingleNewCardLimiter)
    case multiple(MultipleNewCardLimiters)
}

/// Low-level SQLite connection. An actor so callers serialize access.
actor SQLiteDatabase {
    private nonisolated(unsafe) var handle: OpaquePointer?
    private let databaseURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var localRevision: UInt64 = 0
    private var changeTrackingReady = false

    init(path: URL) throws {
        databaseURL = path.standardizedFileURL
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(path.path(percentEncoded: false), &db, flags, nil)
        guard code == SQLITE_OK, let db else {
            throw DatabaseError.openFailed(String(cString: sqlite3_errstr(code)))
        }
        handle = db

        let fkCode = sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil)
        guard fkCode == SQLITE_OK else {
            throw DatabaseError.executeFailed("Failed to enable foreign keys.")
        }
    }

    deinit {
        if let handle {
            sqlite3_close(handle)
        }
    }

    func cacheToken() throws -> DatabaseCacheToken {
        let rows = try query("PRAGMA data_version;")
        let dataVersion = rows.first?["data_version"] as? Int64 ?? 0
        return DatabaseCacheToken(
            localRevision: localRevision,
            dataVersion: dataVersion
        )
    }

    /// Writes a transactionally consistent SQLite snapshot without exposing
    /// the live database path or relying on a WAL file copy.
    func backup(to destination: URL) throws {
        guard let source = handle else {
            throw DatabaseError.executeFailed("The database connection is closed.")
        }
        var destinationHandle: OpaquePointer?
        let openCode = sqlite3_open_v2(
            destination.path(percentEncoded: false),
            &destinationHandle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openCode == SQLITE_OK, let destinationHandle else {
            if let destinationHandle { sqlite3_close(destinationHandle) }
            throw DatabaseError.openFailed(String(cString: sqlite3_errstr(openCode)))
        }
        defer { sqlite3_close(destinationHandle) }
        guard let backup = sqlite3_backup_init(destinationHandle, "main", source, "main") else {
            throw DatabaseError.executeFailed("Could not initialize a database snapshot.")
        }
        let stepCode = sqlite3_backup_step(backup, -1)
        let finishCode = sqlite3_backup_finish(backup)
        guard stepCode == SQLITE_DONE, finishCode == SQLITE_OK else {
            throw DatabaseError.executeFailed("Could not complete a database snapshot.")
        }
    }

    func migrate() throws {
        let current = try schemaVersion()

        guard current <= Schema.version else {
            throw DatabaseError.unsupportedSchemaVersion(current)
        }

        if current == 0 {
            try inTransaction {
                for sql in Schema.createStatements {
                    try execute(sql)
                }
                try execute(
                    "INSERT INTO schema_version (version) VALUES (?);",
                    bindings: [.int(Int64(Schema.version))]
                )
                _ = try getOrCreateLibraryID()
            }
            changeTrackingReady = true
            return
        }

        guard current < Schema.version else {
            _ = try getOrCreateLibraryID()
            changeTrackingReady = try tableExists("api_transaction_context")
            return
        }

        try inTransaction {
            if current < 2 {
                for sql in Schema.migrationV2Statements {
                    try execute(sql)
                }
                try backfillCardDueDates()
            }

            if current < 3 {
                try migrateNotesToItemsSchemaIfNeeded()
            }

            if current < 4 {
                for sql in Schema.migrationV4Statements {
                    try execute(sql)
                }
            }

            if current < 5 {
                for sql in Schema.migrationV5Statements {
                    try execute(sql)
                }
            }

            if current < 6 {
                try migrateReviewHistorySchemaIfNeeded()
            }

            if current < 7 {
                try migrateMediaReferenceSchemaIfNeeded()
            }

            if current < 8 {
                for sql in Schema.migrationV8Statements {
                    try execute(sql)
                }
            }

            if current < 9 {
                for sql in Schema.migrationV9Statements {
                    try execute(sql)
                }
            }

            if current < 10 {
                for sql in Schema.migrationV10Statements {
                    try execute(sql)
                }
            }

            if current < 11 {
                try migrateReviewSequenceSchemaIfNeeded()
            }

            if current < 12 {
                for sql in Schema.migrationV12Statements {
                    try execute(sql)
                }
            }

            if current < 13 {
                for sql in Schema.migrationV13Statements {
                    try execute(sql)
                }
                _ = try getOrCreateLibraryID()
            }

            if current < 14, try tableExists("cards") {
                for sql in Schema.migrationV14Statements {
                    try execute(sql)
                }
                try backfillCardScheduleColumns()
            }

            if current < 15 {
                for sql in Schema.migrationV15Statements {
                    try execute(sql)
                }
                if try tableExists("cards"), !(try columnExists("deck_id", in: "cards")) {
                    try execute("ALTER TABLE cards ADD COLUMN deck_id TEXT;")
                }
                if try tableExists("cards"),
                   try columnExists("deck_id", in: "cards"),
                   try columnExists("due_at", in: "cards") {
                    try execute(
                        """
                        CREATE INDEX IF NOT EXISTS idx_cards_deck_due
                        ON cards(deck_id, due_at, id);
                        """
                    )
                }
            }

            if current < 16, try tableExists("items") {
                for sql in Schema.migrationV16Statements {
                    try execute(sql)
                }
            }

            if current < 17, try tableExists("items") {
                let supportsCardProjection = try cardsSupportScheduleAggregates()
                for sql in Schema.migrationV17Statements where supportsCardProjection
                    || !sql.contains("item_browse_cards_") {
                    try execute(sql)
                }
                try backfillBrowseProjection()
            }

            if current < 18, try tableExists("item_types") {
                for sql in Schema.migrationV18Statements {
                    try execute(sql)
                }
            }

            if current < 19, try tableExists("new_card_introductions") {
                for sql in Schema.migrationV19Statements {
                    try execute(sql)
                }
            }

            if current < 20 {
                if try tableExists("cards"),
                   try columnExists("due_at", in: "cards"),
                   try columnExists("phase", in: "cards"),
                   try columnExists("is_suspended", in: "cards") {
                    try execute(Schema.migrationV20Statements[0])
                }
                if try tableExists("decks"),
                   try columnExists("new_cards_per_day", in: "decks") {
                    try execute(Schema.migrationV20Statements[1])
                }
            }

            if current < 21 {
                for sql in Schema.migrationV21StateStatements {
                    try execute(sql)
                }
                try backfillResourceRevisions()
                for table in [
                    "decks",
                    "item_types",
                    "items",
                    "cards",
                    "review_logs",
                    "review_reverts",
                    "media_assets",
                ] where try tableExists(table) {
                    for sql in Schema.apiChangeTrackingStatements(forExistingTable: table) {
                        try execute(sql)
                    }
                }
            }

            if current < 22 {
                try execute(
                    "CREATE TABLE IF NOT EXISTS library_aliases (alias_id TEXT PRIMARY KEY NOT NULL, canonical_id TEXT NOT NULL);"
                )
                for table in [
                    "library_item_types", "deck_included_item_types",
                    "deck_item_type_policy_entries", "scheduler_params",
                    "portable_item_type_mappings", "app_metadata",
                ] where try tableExists(table) {
                    for sql in Schema.syncChangeTrackingStatements(forExistingTable: table) {
                        try execute(sql)
                    }
                }
                try backfillExtendedSyncResourceRevisions()
            }

            if current < 23 {
                for sql in Schema.migrationV23Statements {
                    try execute(sql)
                }
                for sql in Schema.apiChangeTrackingStatements(forExistingTable: "study_responses") {
                    try execute(sql)
                }
            }

            if current < 24,
               try tableExists("cards"),
               try columnExists("deck_id", in: "cards"),
               try columnExists("due_at", in: "cards"),
               try columnExists("phase", in: "cards"),
               try columnExists("is_suspended", in: "cards") {
                for sql in Schema.migrationV24Statements {
                    try execute(sql)
                }
            }

            if current < 25 {
                for sql in Schema.migrationV25Statements {
                    try execute(sql)
                }
                if try tableExists("cards") {
                    if !(try columnExists("memory_model_version", in: "cards")) {
                        try execute("ALTER TABLE cards ADD COLUMN memory_model_version TEXT;")
                    }
                    if !(try columnExists("memory_parameter_set_id", in: "cards")) {
                        try execute("ALTER TABLE cards ADD COLUMN memory_parameter_set_id TEXT;")
                    }
                    if !(try columnExists("scheduling_history_origin", in: "cards")) {
                        try execute("ALTER TABLE cards ADD COLUMN scheduling_history_origin REAL;")
                    }
                }
                if try tableExists("review_logs") {
                    if !(try columnExists("memory_after", in: "review_logs")) {
                        try execute("ALTER TABLE review_logs ADD COLUMN memory_after BLOB;")
                    }
                    if !(try columnExists("scheduling_audit", in: "review_logs")) {
                        try execute("ALTER TABLE review_logs ADD COLUMN scheduling_audit BLOB;")
                    }
                }
                if try tableExists("scheduler_params") {
                    try execute(
                        """
                        INSERT OR IGNORE INTO quarantined_scheduler_params (
                            profile_id, parameters, optimized_at, sample_count,
                            log_loss, archived_at, reason
                        )
                        SELECT profile_id, parameters, optimized_at, sample_count,
                               log_loss, CAST(strftime('%s', 'now') AS REAL),
                               'Replaced by versioned upstream FSRS implementation'
                        FROM scheduler_params;
                        """
                    )
                }
            }

            if current < 26,
               try tableExists("decks"),
               !(try columnExists("sort_position", in: "decks")) {
                for sql in Schema.migrationV26Statements {
                    try execute(sql)
                }
            }

            try execute(
                "UPDATE schema_version SET version = ?;",
                bindings: [.int(Int64(Schema.version))]
            )
        }
        changeTrackingReady = true
    }

    func ensureTemplateDefinitionFormat() throws {
        let key = "template_definition_format"
        if let value = try metadataValue(forKey: key) {
            guard value == "2" else {
                throw DatabaseError.templateDefinitionMigrationRequired
            }
            return
        }
        let rows = try query("SELECT COUNT(*) AS count FROM item_types;")
        let count = (rows.first?["count"] as? Int64) ?? 0
        let usesCompositionFormat = count == 0 ? true : try storedDefinitionsUseCompositionFormat()
        guard usesCompositionFormat else {
            throw DatabaseError.templateDefinitionMigrationRequired
        }
        try setMetadataValue("2", forKey: key)
    }

    /// Structural detection handles synthetic historical-schema fixtures that
    /// already contain current definitions. It does not decode or convert the
    /// legacy format; real prompt/answer definitions still require the tool.
    private func storedDefinitionsUseCompositionFormat() throws -> Bool {
        for row in try query("SELECT definition FROM item_types;") {
            guard let data = payload(row, "definition"),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let templates = object["templates"] as? [[String: Any]],
                  templates.allSatisfy({ $0["layout"] != nil && $0["components"] != nil })
            else { return false }
        }
        return true
    }

    /// Existing resources begin at revision one without manufacturing change
    /// history that predates the local API. Tables absent from deliberately
    /// minimal migration fixtures are skipped.
    private func backfillResourceRevisions() throws {
        let tracked: [(table: String, resourceType: String, idColumn: String)] = [
            ("decks", "deck", "id"),
            ("item_types", "itemType", "id"),
            ("items", "item", "id"),
            ("cards", "card", "id"),
            ("review_logs", "review", "id"),
            ("review_reverts", "reviewRevert", "id"),
            ("media_assets", "media", "hash"),
        ]
        let now = Date.now.timeIntervalSince1970
        for entry in tracked where try tableExists(entry.table) {
            try execute(
                """
                INSERT OR IGNORE INTO resource_revisions (
                    resource_type, resource_id, revision, updated_at, is_deleted
                )
                SELECT ?, \(entry.idColumn), 1, ?, 0 FROM \(entry.table);
                """,
                bindings: [.text(entry.resourceType), .double(now)]
            )
        }
    }

    private func backfillExtendedSyncResourceRevisions() throws {
        let now = Date.now.timeIntervalSince1970
        let rows: [(table: String, kind: String, sql: String)] = [
            ("library_item_types", "itemTypeMembership", "SELECT 'library:' || item_type_id AS id FROM library_item_types"),
            ("deck_included_item_types", "itemTypeMembership", "SELECT 'included:' || root_deck_id || ':' || item_type_id AS id FROM deck_included_item_types"),
            ("deck_item_type_policy_entries", "itemTypeMembership", "SELECT 'policy:' || deck_id || ':' || item_type_id AS id FROM deck_item_type_policy_entries"),
            ("scheduler_params", "schedulingSettings", "SELECT 'profile:' || profile_id AS id FROM scheduler_params"),
            ("app_metadata", "schedulingSettings", "SELECT 'rollover' AS id FROM app_metadata WHERE key = 'study_day_rollover_minutes'"),
            ("portable_item_type_mappings", "portableTypeMapping", "SELECT origin_library_id || ':' || origin_type_id || ':' || schema_digest AS id FROM portable_item_type_mappings"),
            ("app_metadata", "library", "SELECT value AS id FROM app_metadata WHERE key = 'library_id'"),
        ]
        for row in rows where try tableExists(row.table) {
            try execute(
                "INSERT OR IGNORE INTO resource_revisions (resource_type, resource_id, revision, updated_at, is_deleted) SELECT ?, id, 1, ?, 0 FROM (\(row.sql));",
                bindings: [.text(row.kind), .double(now)]
            )
        }
    }

    /// Returns this library's durable identity, creating it once when absent.
    /// The value is stored as metadata so moves and subsequent launches retain it.
    func getOrCreateLibraryID() throws -> UUID {
        let key = "library_id"
        let rows = try query(
            "SELECT value FROM app_metadata WHERE key = ? LIMIT 1;",
            bindings: [.text(key)]
        )
        if let value = rows.first?["value"] as? String {
            guard let id = UUID(uuidString: value) else {
                throw DatabaseError.decodingFailed
            }
            return id
        }

        let id = UUID()
        try execute(
            """
            INSERT INTO app_metadata (key, value)
            VALUES (?, ?)
            ON CONFLICT(key) DO NOTHING;
            """,
            bindings: [.text(key), .text(id.uuidString)]
        )
        guard let persisted = try query(
            "SELECT value FROM app_metadata WHERE key = ? LIMIT 1;",
            bindings: [.text(key)]
        ).first?["value"] as? String,
              let persistedID = UUID(uuidString: persisted)
        else {
            throw DatabaseError.decodingFailed
        }
        return persistedID
    }

    func recordLibraryAlias(_ aliasID: UUID, canonicalID: UUID) throws {
        guard aliasID != canonicalID else { return }
        try execute(
            "INSERT INTO library_aliases (alias_id, canonical_id) VALUES (?, ?) ON CONFLICT(alias_id) DO UPDATE SET canonical_id = excluded.canonical_id;",
            bindings: [.text(aliasID.uuidString), .text(canonicalID.uuidString)]
        )
    }

    func fetchLibraryAliases(canonicalID: UUID) throws -> Set<UUID> {
        Set(try query(
            "SELECT alias_id FROM library_aliases WHERE canonical_id = ? ORDER BY alias_id;",
            bindings: [.text(canonicalID.uuidString)]
        ).compactMap { ($0["alias_id"] as? String).flatMap(UUID.init(uuidString:)) })
    }

    func libraryID() throws -> UUID {
        try getOrCreateLibraryID()
    }

    func metadataValue(forKey key: String) throws -> String? {
        try query(
            "SELECT value FROM app_metadata WHERE key = ? LIMIT 1;",
            bindings: [.text(key)]
        ).first?["value"] as? String
    }

    func setMetadataValue(_ value: String, forKey key: String) throws {
        try execute(
            """
            INSERT INTO app_metadata (key, value)
            VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """,
            bindings: [.text(key), .text(value)]
        )
    }

    func currentChangeCursor() throws -> Int64 {
        try query("SELECT COALESCE(MAX(cursor), 0) AS cursor FROM api_changes;")
            .first?["cursor"] as? Int64 ?? 0
    }

    func oldestChangeCursor() throws -> Int64? {
        try query("SELECT MIN(cursor) AS cursor FROM api_changes;")
            .first?["cursor"] as? Int64
    }

    func fetchLibraryChanges(after cursor: Int64, limit: Int) throws -> [LibraryChange] {
        try query(
            """
            SELECT cursor, transaction_id, sequence, event_type, resource_type,
                   resource_id, revision, is_tombstone, occurred_at
            FROM api_changes
            WHERE cursor > ?
            ORDER BY cursor ASC
            LIMIT ?;
            """,
            bindings: [.int(cursor), .int(Int64(limit))]
        ).map { row in
            guard
                let cursor = row["cursor"] as? Int64,
                let transactionText = row["transaction_id"] as? String,
                let transactionID = UUID(uuidString: transactionText),
                let sequence = row["sequence"] as? Int64,
                let eventType = row["event_type"] as? String,
                let resourceType = row["resource_type"] as? String,
                let resourceID = row["resource_id"] as? String,
                let revision = row["revision"] as? Int64,
                let isTombstone = row["is_tombstone"] as? Int64,
                let occurredAt = row["occurred_at"] as? Double
            else {
                throw DatabaseError.decodingFailed
            }
            return LibraryChange(
                cursor: cursor,
                transactionID: transactionID,
                sequence: Int(sequence),
                eventType: eventType,
                resourceType: resourceType,
                resourceID: resourceID,
                revision: Int(revision),
                isTombstone: isTombstone != 0,
                occurredAt: Date(timeIntervalSince1970: occurredAt)
            )
        }
    }

    func fetchResourceRevision(
        resourceType: String,
        resourceID: String
    ) throws -> LibraryResourceRevision? {
        guard let row = try query(
            """
            SELECT revision, updated_at, is_deleted
            FROM resource_revisions
            WHERE resource_type = ? AND resource_id = ?
            LIMIT 1;
            """,
            bindings: [.text(resourceType), .text(resourceID)]
        ).first else {
            return nil
        }
        guard
            let revision = row["revision"] as? Int64,
            let updatedAt = row["updated_at"] as? Double,
            let isDeleted = row["is_deleted"] as? Int64
        else {
            throw DatabaseError.decodingFailed
        }
        return LibraryResourceRevision(
            resourceType: resourceType,
            resourceID: resourceID,
            revision: Int(revision),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            isDeleted: isDeleted != 0
        )
    }

    func pruneLibraryChanges(before cutoff: Date, minimumRetained: Int) throws -> Int {
        let boundary = try query(
            """
            SELECT cursor FROM api_changes
            ORDER BY cursor DESC
            LIMIT 1 OFFSET ?;
            """,
            bindings: [.int(Int64(minimumRetained - 1))]
        ).first?["cursor"] as? Int64
        guard let boundary else { return 0 }
        try execute(
            """
            DELETE FROM api_changes
            WHERE occurred_at < ? AND cursor < ?;
            """,
            bindings: [.double(cutoff.timeIntervalSince1970), .int(boundary)]
        )
        return Int(sqlite3_changes(handle))
    }

    func claimIdempotency(
        clientID: UUID,
        route: String,
        key: String,
        requestHash: String,
        resultResourceID: String?,
        now: Date
    ) throws -> IdempotencyClaim {
        try inTransaction {
            let bindings: [Binding] = [
                .text(clientID.uuidString.lowercased()),
                .text(route),
                .text(key),
            ]
            if let row = try query(
                """
                SELECT request_hash, state, result_resource_id,
                       response_status, response_body
                FROM api_idempotency
                WHERE client_id = ? AND route = ? AND idempotency_key = ?
                LIMIT 1;
                """,
                bindings: bindings
            ).first {
                guard row["request_hash"] as? String == requestHash else {
                    throw DatabaseError.idempotencyConflict
                }
                let resourceID = row["result_resource_id"] as? String
                if row["state"] as? String == "completed" {
                    guard
                        let status = row["response_status"] as? Int64,
                        let response = row["response_body"] as? Data
                    else {
                        throw DatabaseError.decodingFailed
                    }
                    return .completed(
                        resultResourceID: resourceID,
                        status: Int(status),
                        responseBody: response
                    )
                }
                return .pending(resultResourceID: resourceID)
            }

            try execute(
                """
                INSERT INTO api_idempotency (
                    client_id, route, idempotency_key, request_hash, state,
                    result_resource_id, created_at
                ) VALUES (?, ?, ?, ?, 'pending', ?, ?);
                """,
                bindings: bindings + [
                    .text(requestHash),
                    resultResourceID.map(Binding.text) ?? .null,
                    .double(now.timeIntervalSince1970),
                ]
            )
            return .claimed(resultResourceID: resultResourceID)
        }
    }

    func idempotencyClaim(
        clientID: UUID,
        route: String,
        key: String,
        requestHash: String
    ) throws -> IdempotencyClaim? {
        guard let row = try query(
            """
            SELECT request_hash, state, result_resource_id,
                   response_status, response_body
            FROM api_idempotency
            WHERE client_id = ? AND route = ? AND idempotency_key = ?
            LIMIT 1;
            """,
            bindings: [
                .text(clientID.uuidString.lowercased()),
                .text(route),
                .text(key),
            ]
        ).first else { return nil }
        guard row["request_hash"] as? String == requestHash else {
            throw DatabaseError.idempotencyConflict
        }
        let resourceID = row["result_resource_id"] as? String
        guard row["state"] as? String == "completed" else {
            return .pending(resultResourceID: resourceID)
        }
        guard let status = row["response_status"] as? Int64,
              let response = row["response_body"] as? Data
        else {
            throw DatabaseError.decodingFailed
        }
        return .completed(
            resultResourceID: resourceID,
            status: Int(status),
            responseBody: response
        )
    }

    func completeIdempotency(
        clientID: UUID,
        route: String,
        key: String,
        requestHash: String,
        status: Int,
        responseBody: Data,
        now: Date
    ) throws {
        try inTransaction {
            guard let row = try query(
                """
                SELECT request_hash, state
                FROM api_idempotency
                WHERE client_id = ? AND route = ? AND idempotency_key = ?
                LIMIT 1;
                """,
                bindings: [
                    .text(clientID.uuidString.lowercased()),
                    .text(route),
                    .text(key),
                ]
            ).first else {
                throw DatabaseError.idempotencyRecordNotFound
            }
            guard row["request_hash"] as? String == requestHash else {
                throw DatabaseError.idempotencyConflict
            }
            if row["state"] as? String == "completed" { return }

            try execute(
                """
                UPDATE api_idempotency
                SET state = 'completed', response_status = ?, response_body = ?, completed_at = ?
                WHERE client_id = ? AND route = ? AND idempotency_key = ?;
                """,
                bindings: [
                    .int(Int64(status)),
                    .blob(responseBody),
                    .double(now.timeIntervalSince1970),
                    .text(clientID.uuidString.lowercased()),
                    .text(route),
                    .text(key),
                ]
            )
        }
    }

    func pruneIdempotencyRecords(before cutoff: Date) throws -> Int {
        try execute(
            "DELETE FROM api_idempotency WHERE created_at < ?;",
            bindings: [.double(cutoff.timeIntervalSince1970)]
        )
        return Int(sqlite3_changes(handle))
    }

    func portableDeckLibrarySnapshot(rootDeckID: UUID) throws -> PortableDeckLibrarySnapshot {
        try execute("BEGIN DEFERRED TRANSACTION;")
        do {
            let decks = try fetchAllDecks()
            let summaries = decks.map {
                DeckSummary(
                    id: $0.id,
                    name: $0.name,
                    parentID: $0.parentID,
                    itemCount: 0,
                    dueCount: 0
                )
            }
            let selectedDeckIDs = decks.contains(where: { $0.id == rootDeckID })
                ? DeckTree.descendantIDs(of: rootDeckID, in: summaries)
                : []
            let snapshot = PortableDeckLibrarySnapshot(
                libraryID: try getOrCreateLibraryID(),
                decks: decks,
                items: try fetchItems(deckIDs: selectedDeckIDs),
                itemTypes: try fetchAllItemTypes(),
                mappings: try allPortableItemTypeMappings(),
                includedItemTypes: try fetchIncludedItemTypeOwners(),
                itemTypePolicies: try fetchDeckItemTypePolicyEntries()
            )
            try execute("COMMIT;")
            return snapshot
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func lookupPortableItemTypeMapping(
        originLibraryID: UUID,
        originTypeID: UUID,
        schemaDigest: String
    ) throws -> UUID? {
        guard Self.isValidSHA256Digest(schemaDigest) else {
            throw DatabaseError.queryFailed("Portable item-type schema digest is invalid.")
        }
        let rows = try query(
            """
            SELECT local_type_id
            FROM portable_item_type_mappings
            WHERE origin_library_id = ?
              AND origin_type_id = ?
              AND schema_digest = ?
            LIMIT 1;
            """,
            bindings: [
                .text(originLibraryID.uuidString),
                .text(originTypeID.uuidString),
                .text(schemaDigest),
            ]
        )
        guard let value = rows.first?["local_type_id"] as? String else { return nil }
        guard let id = UUID(uuidString: value) else {
            throw DatabaseError.decodingFailed
        }
        return id
    }

    /// Finds an already mapped local type with the same canonical schema,
    /// regardless of origin, so imports can deduplicate equivalent definitions.
    func lookupPortableItemTypeMapping(schemaDigest: String) throws -> UUID? {
        guard Self.isValidSHA256Digest(schemaDigest) else {
            throw DatabaseError.queryFailed("Portable item-type schema digest is invalid.")
        }
        let rows = try query(
            """
            SELECT local_type_id
            FROM portable_item_type_mappings
            WHERE schema_digest = ?
            ORDER BY rowid ASC
            LIMIT 1;
            """,
            bindings: [.text(schemaDigest)]
        )
        guard let value = rows.first?["local_type_id"] as? String else { return nil }
        guard let id = UUID(uuidString: value) else {
            throw DatabaseError.decodingFailed
        }
        return id
    }

    func persistPortableItemTypeMapping(
        originLibraryID: UUID,
        originTypeID: UUID,
        schemaDigest: String,
        localTypeID: UUID
    ) throws {
        guard Self.isValidSHA256Digest(schemaDigest) else {
            throw DatabaseError.executeFailed("Portable item-type schema digest is invalid.")
        }
        try execute(
            """
            INSERT INTO portable_item_type_mappings (
                origin_library_id, origin_type_id, schema_digest, local_type_id
            )
            VALUES (?, ?, ?, ?)
            ON CONFLICT(origin_library_id, origin_type_id, schema_digest)
            DO UPDATE SET local_type_id = excluded.local_type_id;
            """,
            bindings: [
                .text(originLibraryID.uuidString),
                .text(originTypeID.uuidString),
                .text(schemaDigest),
                .text(localTypeID.uuidString),
            ]
        )
    }

    func portableItemTypeMappings(originLibraryID: UUID, originTypeID: UUID) throws
        -> [(digest: String, localTypeID: UUID)]
    {
        try query(
            """
            SELECT schema_digest, local_type_id FROM portable_item_type_mappings
            WHERE origin_library_id = ? AND origin_type_id = ? ORDER BY rowid;
            """,
            bindings: [.text(originLibraryID.uuidString), .text(originTypeID.uuidString)]
        ).compactMap { row in
            guard let digest = row["schema_digest"] as? String,
                  let local = (row["local_type_id"] as? String).flatMap(UUID.init(uuidString:))
            else { return nil }
            return (digest, local)
        }
    }

    func portableItemTypeOrigin(localTypeID: UUID) throws
        -> (libraryID: UUID, typeID: UUID, digest: String)?
    {
        let rows = try query(
            """
            SELECT origin_library_id, origin_type_id, schema_digest
            FROM portable_item_type_mappings WHERE local_type_id = ?
            ORDER BY rowid LIMIT 1;
            """,
            bindings: [.text(localTypeID.uuidString)]
        )
        guard let row = rows.first,
              let library = (row["origin_library_id"] as? String).flatMap(UUID.init(uuidString:)),
              let type = (row["origin_type_id"] as? String).flatMap(UUID.init(uuidString:)),
              let digest = row["schema_digest"] as? String
        else { return nil }
        return (library, type, digest)
    }

    func allPortableItemTypeMappings() throws -> [PortableDeckTypeMapping] {
        try query(
            """
            SELECT origin_library_id, origin_type_id, schema_digest, local_type_id
            FROM portable_item_type_mappings ORDER BY rowid;
            """
        ).compactMap { row in
            guard let originLibrary = (row["origin_library_id"] as? String)
                    .flatMap(UUID.init(uuidString:)),
                  let originType = (row["origin_type_id"] as? String)
                    .flatMap(UUID.init(uuidString:)),
                  let digest = row["schema_digest"] as? String,
                  Self.isValidSHA256Digest(digest),
                  let local = (row["local_type_id"] as? String)
                    .flatMap(UUID.init(uuidString:))
            else { return nil }
            return PortableDeckTypeMapping(
                originLibraryID: originLibrary,
                originTypeID: originType,
                digest: digest,
                localTypeID: local
            )
        }
    }

    /// Seeds the configured first-run starters exactly once. The marker and
    /// inserts share a transaction so an interrupted launch can safely retry.
    func seedStarterItemTypesIfNeeded(_ itemTypes: [ItemType]) throws {
        try inTransaction {
            let marker = try query(
                "SELECT value FROM app_metadata WHERE key = ? LIMIT 1;",
                bindings: [.text("starter_item_types_seeded")]
            )
            guard marker.isEmpty else { return }

            for itemType in itemTypes {
                let data = try encode(itemType)
                try execute(
                    """
                    INSERT INTO item_types (id, name, definition)
                    VALUES (?, ?, ?)
                    ON CONFLICT(id) DO NOTHING;
                    """,
                    bindings: [
                        .text(itemType.id.uuidString),
                        .text(itemType.name),
                        .blob(data),
                    ]
                )
                try execute(
                    """
                    INSERT INTO library_item_types (item_type_id)
                    VALUES (?)
                    ON CONFLICT(item_type_id) DO NOTHING;
                    """,
                    bindings: [.text(itemType.id.uuidString)]
                )
            }

            try execute(
                """
                INSERT INTO app_metadata (key, value)
                VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                """,
                bindings: [
                    .text("starter_item_types_seeded"),
                    .text("1"),
                ]
            )
        }
    }

    func fetchItemType(id: UUID) throws -> ItemType? {
        let rows = try query(
            "SELECT definition FROM item_types WHERE id = ? LIMIT 1;",
            bindings: [.text(id.uuidString)]
        )
        guard let row = rows.first, let data = payload(row, "definition") else { return nil }
        return try decode(ItemType.self, from: data)
    }

    /// Returns nil for an independently corrupt definition while preserving
    /// database/query failures for the caller.
    func fetchValidatedItemType(id: UUID) throws -> ItemType? {
        let rows = try query(
            "SELECT definition FROM item_types WHERE id = ? LIMIT 1;",
            bindings: [.text(id.uuidString)]
        )
        guard let row = rows.first, let data = payload(row, "definition") else { return nil }
        do {
            let itemType = try decode(ItemType.self, from: data)
            try ItemTypeValidation.validate(itemType)
            return itemType
        } catch is DecodingError {
            return nil
        } catch is DatabaseError {
            return nil
        }
    }

    func fetchItemType(named name: String) throws -> ItemType? {
        let rows = try query(
            "SELECT definition FROM item_types WHERE name = ? LIMIT 1;",
            bindings: [.text(name)]
        )
        guard let row = rows.first, let data = payload(row, "definition") else { return nil }
        return try decode(ItemType.self, from: data)
    }

    func insertItemType(_ itemType: ItemType) throws {
        let data = try encode(itemType)
        try execute(
            """
            INSERT INTO item_types (id, name, definition)
            VALUES (?, ?, ?);
            """,
            bindings: [
                .text(itemType.id.uuidString),
                .text(itemType.name),
                .blob(data),
            ]
        )
    }

    func insertLibraryItemType(_ itemType: ItemType) throws {
        try inTransaction {
            try insertItemType(itemType)
            try markItemTypeAsLibrary(itemType.id)
        }
    }

    func markItemTypeAsLibrary(_ id: UUID) throws {
        try execute(
            """
            INSERT INTO library_item_types (item_type_id)
            VALUES (?)
            ON CONFLICT(item_type_id) DO NOTHING;
            """,
            bindings: [.text(id.uuidString)]
        )
    }

    func fetchLibraryItemTypeIDs() throws -> Set<UUID> {
        Set(try query(
            "SELECT item_type_id FROM library_item_types ORDER BY item_type_id;"
        ).compactMap { row in
            (row["item_type_id"] as? String).flatMap(UUID.init(uuidString:))
        })
    }

    func fetchIncludedItemTypeOwners() throws -> [IncludedItemTypeOwner] {
        try query(
            """
            SELECT root_deck_id, item_type_id, ordinal
            FROM deck_included_item_types
            ORDER BY root_deck_id, ordinal;
            """
        ).compactMap { row in
            guard let rootText = row["root_deck_id"] as? String,
                  let rootID = UUID(uuidString: rootText),
                  let typeText = row["item_type_id"] as? String,
                  let typeID = UUID(uuidString: typeText),
                  let ordinal = row["ordinal"] as? Int64
            else { return nil }
            return IncludedItemTypeOwner(
                rootDeckID: rootID,
                itemTypeID: typeID,
                ordinal: Int(ordinal)
            )
        }
    }

    func fetchDeckItemTypePolicyEntries() throws -> [DeckItemTypePolicyEntry] {
        try query(
            """
            SELECT deck_id, item_type_id, ordinal, is_default
            FROM deck_item_type_policy_entries
            ORDER BY deck_id, ordinal;
            """
        ).compactMap { row in
            guard let deckText = row["deck_id"] as? String,
                  let deckID = UUID(uuidString: deckText),
                  let typeText = row["item_type_id"] as? String,
                  let typeID = UUID(uuidString: typeText),
                  let ordinal = row["ordinal"] as? Int64,
                  let isDefault = row["is_default"] as? Int64
            else { return nil }
            return DeckItemTypePolicyEntry(
                deckID: deckID,
                itemTypeID: typeID,
                ordinal: Int(ordinal),
                isDefault: isDefault != 0
            )
        }
    }

    func updateItemType(_ itemType: ItemType) throws {
        let data = try encode(itemType)
        try execute(
            """
            INSERT INTO item_types (id, name, definition)
            VALUES (?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                definition = excluded.definition;
            """,
            bindings: [
                .text(itemType.id.uuidString),
                .text(itemType.name),
                .blob(data),
            ]
        )
    }

    func updateItemTypeAndSyncCards(
        previous: ItemType?,
        updated: ItemType,
        now: Date
    ) throws {
        try inTransaction {
            try updateItemType(updated)
            if let previous {
                try syncCards(from: previous, to: updated, now: now)
            }
            try refreshBrowseProjection(itemTypeID: updated.id)
        }
    }

    func fetchItemTypesWithCorruption() throws -> ItemTypeLoadResult {
        let rows = try query(
            """
            SELECT id, name, definition
            FROM item_types
            ORDER BY name ASC;
            """
        )

        var itemTypes: [ItemType] = []
        var corruptions: [QuarantinedItemTypeDefinition] = []
        for row in rows {
            let persistedID = row["id"] as? String ?? ""
            let name = row["name"] as? String ?? "Unnamed item type"
            guard let data = payload(row, "definition") else {
                corruptions.append(.init(persistedID: persistedID, name: name))
                continue
            }
            do {
                let itemType = try decode(ItemType.self, from: data)
                try ItemTypeValidation.validate(itemType)
                itemTypes.append(itemType)
            } catch {
                corruptions.append(.init(persistedID: persistedID, name: name))
            }
        }
        return ItemTypeLoadResult(itemTypes: itemTypes, corruptions: corruptions)
    }

    func fetchAllItemTypes() throws -> [ItemType] {
        try fetchItemTypesWithCorruption().itemTypes
    }

    func repairItemTypeDefinition(id: UUID, now: Date) throws -> ItemType {
        let rows = try query(
            "SELECT name, definition FROM item_types WHERE id = ? LIMIT 1;",
            bindings: [.text(id.uuidString)]
        )
        guard let row = rows.first,
              let name = row["name"] as? String,
              let definition = payload(row, "definition")
        else {
            throw DatabaseError.itemTypeNotFound(id)
        }

        let front = FieldDef(name: "Front", type: .text, isRequired: true)
        let back = FieldDef(name: "Back", type: .text, isRequired: true)
        let base = try ItemTypeBuilder.makeItemType(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Recovered Item Type" : name,
            fields: [front, back]
        )
        let repaired = ItemType(id: id, name: base.name, fields: base.fields, templates: base.templates)
        let repairedData = try encode(repaired)

        try inTransaction {
            try execute(
                """
                INSERT INTO quarantined_item_type_definitions
                    (item_type_id, name, definition, archived_at)
                VALUES (?, ?, ?, ?);
                """,
                bindings: [
                    .text(id.uuidString),
                    .text(name),
                    .blob(definition),
                    .double(now.timeIntervalSince1970),
                ]
            )
            try execute(
                "UPDATE item_types SET name = ?, definition = ? WHERE id = ?;",
                bindings: [.text(repaired.name), .blob(repairedData), .text(id.uuidString)]
            )
            for entry in try fetchItems(itemTypeID: id) {
                let cards = CardGenerator.cards(for: entry.item, type: repaired, now: now)
                try insertCards(cards)
                try upsertBrowseProjection(entry.item, itemType: repaired, createdAt: entry.createdAt)
            }
        }
        return repaired
    }

    func quarantinedDefinitionCount(itemTypeID: UUID) throws -> Int {
        let rows = try query(
            "SELECT COUNT(*) AS count FROM quarantined_item_type_definitions WHERE item_type_id = ?;",
            bindings: [.text(itemTypeID.uuidString)]
        )
        return Int(rows.first?["count"] as? Int64 ?? 0)
    }

    func replaceItemTypeDefinition(id: UUID, with data: Data) throws {
        try execute(
            "UPDATE item_types SET definition = ? WHERE id = ?;",
            bindings: [.blob(data), .text(id.uuidString)]
        )
    }

    func insertDeck(_ deck: Deck) throws {
        let sortPosition = try nextDeckSortPosition(parentID: deck.parentID)
        try execute(
            """
            INSERT INTO decks (id, name, parent_id, new_cards_per_day, sort_position)
            VALUES (?, ?, ?, ?, ?);
            """,
            bindings: [
                .text(deck.id.uuidString),
                .text(deck.name),
                deck.parentID.map { .text($0.uuidString) } ?? .null,
                deck.newCardsPerDay.map { .int(Int64($0)) } ?? .null,
                .int(sortPosition),
            ]
        )
    }

    private func nextDeckSortPosition(parentID: UUID?) throws -> Int64 {
        let clause = parentID == nil ? "parent_id IS NULL" : "parent_id = ?"
        let bindings = parentID.map { [Binding.text($0.uuidString)] } ?? []
        let rows = try query(
            "SELECT COALESCE(MAX(sort_position), -1) + 1 AS position FROM decks WHERE \(clause);",
            bindings: bindings
        )
        return rows.first?["position"] as? Int64 ?? 0
    }

    func fetchDeck(id: UUID) throws -> Deck? {
        let rows = try query(
            "SELECT id, name, parent_id, new_cards_per_day FROM decks WHERE id = ? LIMIT 1;",
            bindings: [.text(id.uuidString)]
        )
        guard let row = rows.first,
              let idText = row["id"] as? String,
              let deckID = UUID(uuidString: idText),
              let name = row["name"] as? String
        else { return nil }

        let parentID = (row["parent_id"] as? String).flatMap(UUID.init(uuidString:))
        let newCardsPerDay = (row["new_cards_per_day"] as? Int64).map(Int.init)
        return Deck(
            id: deckID,
            name: name,
            parentID: parentID,
            newCardsPerDay: newCardsPerDay
        )
    }

    func fetchAllDecks() throws -> [Deck] {
        let rows = try query(
            """
            SELECT id, name, parent_id, new_cards_per_day
            FROM decks
            ORDER BY name ASC;
            """
        )
        return rows.compactMap { row in
            guard
                let idText = row["id"] as? String,
                let deckID = UUID(uuidString: idText),
                let name = row["name"] as? String
            else { return nil }
            let parentID = (row["parent_id"] as? String).flatMap(UUID.init(uuidString:))
            let newCardsPerDay = (row["new_cards_per_day"] as? Int64).map(Int.init)
            return Deck(
                id: deckID,
                name: name,
                parentID: parentID,
                newCardsPerDay: newCardsPerDay
            )
        }
    }

    func fetchDeckSortPositions() throws -> [UUID: Int64] {
        Dictionary(uniqueKeysWithValues: try query(
            "SELECT id, sort_position FROM decks;"
        ).compactMap { row in
            guard let idText = row["id"] as? String,
                  let id = UUID(uuidString: idText),
                  let position = row["sort_position"] as? Int64
            else { return nil }
            return (id, position)
        })
    }

    func moveDeck(id: UUID, to destination: DeckMoveDestination) throws {
        try inTransaction {
            guard let movingDeck = try fetchDeck(id: id) else {
                throw DatabaseError.deckNotFound(id)
            }

            let destinationParentID: UUID?
            let targetID: UUID?
            let insertsAfterTarget: Bool
            switch destination {
            case let .before(id):
                guard id != movingDeck.id, let target = try fetchDeck(id: id) else {
                    throw DatabaseError.invalidDeck("Choose another deck as the move target.")
                }
                destinationParentID = target.parentID
                targetID = target.id
                insertsAfterTarget = false
            case let .after(id):
                guard id != movingDeck.id, let target = try fetchDeck(id: id) else {
                    throw DatabaseError.invalidDeck("Choose another deck as the move target.")
                }
                destinationParentID = target.parentID
                targetID = target.id
                insertsAfterTarget = true
            case let .inside(id):
                guard id != movingDeck.id, try fetchDeck(id: id) != nil else {
                    throw DatabaseError.invalidDeck("Choose another deck as the move target.")
                }
                destinationParentID = id
                targetID = nil
                insertsAfterTarget = true
            case .topLevel:
                destinationParentID = nil
                targetID = nil
                insertsAfterTarget = true
            }

            var sourceSiblings = try siblingDeckIDs(parentID: movingDeck.parentID)
            sourceSiblings.removeAll { $0 == movingDeck.id }
            var destinationSiblings = movingDeck.parentID == destinationParentID
                ? sourceSiblings
                : try siblingDeckIDs(parentID: destinationParentID).filter { $0 != movingDeck.id }

            let insertionIndex: Int
            if let targetID,
               let targetIndex = destinationSiblings.firstIndex(of: targetID) {
                insertionIndex = targetIndex + (insertsAfterTarget ? 1 : 0)
            } else if targetID != nil {
                throw DatabaseError.invalidDeck("The move target is not a sibling at that level.")
            } else {
                insertionIndex = destinationSiblings.endIndex
            }
            destinationSiblings.insert(movingDeck.id, at: insertionIndex)

            try execute(
                "UPDATE decks SET parent_id = ? WHERE id = ?;",
                bindings: [
                    destinationParentID.map { .text($0.uuidString) } ?? .null,
                    .text(movingDeck.id.uuidString),
                ]
            )
            if movingDeck.parentID != destinationParentID {
                try writeDeckSortPositions(sourceSiblings)
            }
            try writeDeckSortPositions(destinationSiblings)
        }
    }

    private func siblingDeckIDs(parentID: UUID?) throws -> [UUID] {
        let clause = parentID == nil ? "parent_id IS NULL" : "parent_id = ?"
        let bindings = parentID.map { [Binding.text($0.uuidString)] } ?? []
        return try query(
            """
            SELECT id FROM decks
            WHERE \(clause)
            ORDER BY sort_position ASC, name COLLATE NOCASE ASC, id ASC;
            """,
            bindings: bindings
        ).compactMap { row in
            (row["id"] as? String).flatMap(UUID.init(uuidString:))
        }
    }

    private func writeDeckSortPositions(_ ids: [UUID]) throws {
        for (position, id) in ids.enumerated() {
            try execute(
                "UPDATE decks SET sort_position = ? WHERE id = ?;",
                bindings: [.int(Int64(position)), .text(id.uuidString)]
            )
        }
    }

    func updateDeck(_ deck: Deck) throws {
        let existingParentID = try fetchDeck(id: deck.id)?.parentID
        let parentChanged = existingParentID != deck.parentID
        let sortPosition = parentChanged
            ? try nextDeckSortPosition(parentID: deck.parentID)
            : nil
        try execute(
            """
            UPDATE decks
            SET name = ?, parent_id = ?, new_cards_per_day = ?,
                sort_position = COALESCE(?, sort_position)
            WHERE id = ?;
            """,
            bindings: [
                .text(deck.name),
                deck.parentID.map { .text($0.uuidString) } ?? .null,
                deck.newCardsPerDay.map { .int(Int64($0)) } ?? .null,
                sortPosition.map(Binding.int) ?? .null,
                .text(deck.id.uuidString),
            ]
        )
    }

    func deleteDeck(id: UUID) throws {
        try execute(
            "DELETE FROM decks WHERE id = ?;",
            bindings: [.text(id.uuidString)]
        )
    }

    func reparentChildDecks(from parentID: UUID, to newParentID: UUID?) throws {
        try execute(
            """
            UPDATE decks
            SET parent_id = ?
            WHERE parent_id = ?;
            """,
            bindings: [
                newParentID.map { .text($0.uuidString) } ?? .null,
                .text(parentID.uuidString),
            ]
        )
    }

    func countItems(deckID: UUID) throws -> Int {
        let rows = try query(
            "SELECT COUNT(*) AS count FROM items WHERE deck_id = ?;",
            bindings: [.text(deckID.uuidString)]
        )
        guard let count = rows.first?["count"] as? Int64 else { return 0 }
        return Int(count)
    }

    func countUnassignedItems() throws -> Int {
        let rows = try query("SELECT COUNT(*) AS count FROM items WHERE deck_id IS NULL;")
        guard let count = rows.first?["count"] as? Int64 else { return 0 }
        return Int(count)
    }

    func countItems(deckIDs: Set<UUID>) throws -> Int {
        guard !deckIDs.isEmpty else { return 0 }
        let placeholders = Array(repeating: "?", count: deckIDs.count).joined(separator: ", ")
        let rows = try query(
            """
            SELECT COUNT(*) AS count
            FROM items
            WHERE deck_id IN (\(placeholders));
            """,
            bindings: deckIDs.sorted { $0.uuidString < $1.uuidString }.map { .text($0.uuidString) }
        )
        guard let count = rows.first?["count"] as? Int64 else { return 0 }
        return Int(count)
    }

    /// Direct item counts keyed by deck. Rows with `deck_id IS NULL` are omitted.
    func countItemsGroupedByDeck() throws -> [UUID: Int] {
        let rows = try query(
            """
            SELECT deck_id, COUNT(*) AS count
            FROM items
            WHERE deck_id IS NOT NULL
            GROUP BY deck_id;
            """
        )
        var counts: [UUID: Int] = [:]
        for row in rows {
            guard
                let deckIDText = row["deck_id"] as? String,
                let deckID = UUID(uuidString: deckIDText)
            else { continue }
            counts[deckID] = Int(row["count"] as? Int64 ?? 0)
        }
        return counts
    }

    /// Eligible due counts keyed by the card's deck. Unassigned cards are omitted.
    func countDueCardsGroupedByDeck(asOf now: Date, studyDay: String) throws -> [UUID: Int] {
        try inReadTransaction {
            let eligible = try eligibleDueCardsCTE(scope: .all, asOf: now, studyDay: studyDay)
            let rows = try query(
                eligible.sql
                    + "\nSELECT deck_id, COUNT(*) AS count FROM eligible_due GROUP BY deck_id;",
                bindings: eligible.bindings
            )
            var counts: [UUID: Int] = [:]
            for row in rows {
                guard
                    let deckIDText = row["deck_id"] as? String,
                    let deckID = UUID(uuidString: deckIDText)
                else { continue }
                counts[deckID] = Int(row["count"] as? Int64 ?? 0)
            }
            return counts
        }
    }

    func moveItems(fromDeckID: UUID, toDeckID: UUID?) throws {
        try execute(
            """
            UPDATE items
            SET deck_id = ?, updated_at = ?
            WHERE deck_id = ?;
            """,
            bindings: [
                toDeckID.map { .text($0.uuidString) } ?? .null,
                .double(Date.now.timeIntervalSince1970),
                .text(fromDeckID.uuidString),
            ]
        )
    }

    func updateItemDeck(itemID: UUID, deckID: UUID?) throws {
        try execute(
            """
            UPDATE items
            SET deck_id = ?, updated_at = ?
            WHERE id = ?;
            """,
            bindings: [
                deckID.map { .text($0.uuidString) } ?? .null,
                .double(Date.now.timeIntervalSince1970),
                .text(itemID.uuidString),
            ]
        )
    }

    func updateItemTags(_ updates: [(UUID, [String])], now: Date) throws {
        guard !updates.isEmpty else { return }
        try inTransaction {
            for (id, tags) in updates {
                try execute(
                    "UPDATE items SET tags = ?, updated_at = ? WHERE id = ?;",
                    bindings: [
                        .blob(try encode(tags)),
                        .double(now.timeIntervalSince1970),
                        .text(id.uuidString),
                    ]
                )
            }
        }
    }

    func updateCardsDeck(itemID: UUID, deckID: UUID?) throws {
        try execute(
            """
            UPDATE cards
            SET deck_id = ?
            WHERE item_id = ?;
            """,
            bindings: [
                deckID.map { .text($0.uuidString) } ?? .null,
                .text(itemID.uuidString),
            ]
        )
    }

    func fetchItems(deckID: UUID) throws -> [PersistedItem] {
        let rows = try query(
            """
            SELECT id, item_type_id, fields, tags, deck_id, created_at, updated_at
            FROM items
            WHERE deck_id = ?
            ORDER BY created_at DESC;
            """,
            bindings: [.text(deckID.uuidString)]
        )
        return try rows.map { try decodePersistedItem(from: $0) }
    }

    func fetchItems(deckIDs: Set<UUID>) throws -> [PersistedItem] {
        guard !deckIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: deckIDs.count).joined(separator: ", ")
        let rows = try query(
            """
            SELECT id, item_type_id, fields, tags, deck_id, created_at, updated_at
            FROM items
            WHERE deck_id IN (\(placeholders))
            ORDER BY created_at DESC;
            """,
            bindings: deckIDs.sorted { $0.uuidString < $1.uuidString }.map { .text($0.uuidString) }
        )
        return try rows.map { try decodePersistedItem(from: $0) }
    }

    func fetchUnassignedItems() throws -> [PersistedItem] {
        let rows = try query(
            """
            SELECT id, item_type_id, fields, tags, deck_id, created_at, updated_at
            FROM items
            WHERE deck_id IS NULL
            ORDER BY created_at DESC;
            """
        )
        return try rows.map { try decodePersistedItem(from: $0) }
    }

    func fetchDueCards(
        deckIDs: Set<UUID>,
        asOf now: Date,
        studyDay: String,
        limit: Int? = nil
    ) throws -> [Card] {
        guard !deckIDs.isEmpty else { return [] }
        return try inReadTransaction {
            try fetchStudyQueueCards(
                scope: .decks(deckIDs),
                asOf: now,
                studyDay: studyDay,
                limit: limit
            )
        }
    }

    func fetchUnassignedDueCards(asOf now: Date, limit: Int? = nil) throws -> [Card] {
        try inReadTransaction {
            let effectiveLimit = limit.flatMap { $0 < 0 ? nil : $0 }
            return try fetchStudyQueueCards(
                scope: .unassigned,
                asOf: now,
                studyDay: nil,
                limit: effectiveLimit
            )
        }
    }

    func countDueCards(deckIDs: Set<UUID>, asOf now: Date, studyDay: String) throws -> Int {
        guard !deckIDs.isEmpty else { return 0 }
        return try inReadTransaction {
            let eligible = try eligibleDueCardsCTE(
                scope: .decks(deckIDs),
                asOf: now,
                studyDay: studyDay
            )
            let rows = try query(
                eligible.sql + "\nSELECT COUNT(*) AS count FROM eligible_due;",
                bindings: eligible.bindings
            )
            guard let count = rows.first?["count"] as? Int64 else { return 0 }
            return Int(count)
        }
    }

    func countDueCards(deckID: UUID, asOf now: Date, studyDay: String) throws -> Int {
        try countDueCards(deckIDs: [deckID], asOf: now, studyDay: studyDay)
    }

    func countUnassignedDueCards(asOf now: Date) throws -> Int {
        let rows = try query(
            """
            SELECT COUNT(*) AS count
            FROM cards
            WHERE is_suspended = 0 AND due_at <= ? AND deck_id IS NULL;
            """,
            bindings: [.double(now.timeIntervalSince1970)]
        )
        guard let count = rows.first?["count"] as? Int64 else { return 0 }
        return Int(count)
    }

    func insertItemWithCards(
        _ item: Item,
        cards: [Card],
        createdAt: Date,
        updatedAt: Date,
        mediaDescriptors: [String: MediaAssetDescriptor] = [:]
    ) throws {
        try inTransaction {
            try insertItemWithCardsWithoutTransaction(
                item,
                cards: cards,
                createdAt: createdAt,
                updatedAt: updatedAt,
                mediaDescriptors: mediaDescriptors
            )
        }
    }

    private func insertItemWithCardsWithoutTransaction(
        _ item: Item,
        cards: [Card],
        createdAt: Date,
        updatedAt: Date,
        mediaDescriptors: [String: MediaAssetDescriptor]
    ) throws {
        try validateMediaAdoption(in: item, comparedTo: nil, now: createdAt)
        try applyMediaReferenceDeltas(
            from: [:],
            to: mediaReferenceCounts(in: item),
            descriptors: mediaDescriptors,
            now: createdAt
        )
        try insertItem(item, createdAt: createdAt, updatedAt: updatedAt)
        try insertCards(cards)
        guard let itemType = try fetchValidatedItemType(id: item.itemTypeID) else {
            throw DatabaseError.itemTypeNotFound(item.itemTypeID)
        }
        try upsertBrowseProjection(item, itemType: itemType, createdAt: createdAt)
        try consumeMediaReservations(ids: mediaReservationIDs(in: item))
    }

    func insertItemsWithCards(
        _ entries: [(item: Item, cards: [Card])],
        createdAt: Date,
        updatedAt: Date
    ) throws {
        try inTransaction {
            for entry in entries {
                try applyMediaReferenceDeltas(
                    from: [:],
                    to: mediaReferenceCounts(in: entry.item),
                    descriptors: [:],
                    now: createdAt
                )
                try insertItem(entry.item, createdAt: createdAt, updatedAt: updatedAt)
                try insertCards(entry.cards)
                guard let itemType = try fetchValidatedItemType(id: entry.item.itemTypeID) else {
                    throw DatabaseError.itemTypeNotFound(entry.item.itemTypeID)
                }
                try upsertBrowseProjection(entry.item, itemType: itemType, createdAt: createdAt)
                try consumeMediaReservations(ids: mediaReservationIDs(in: entry.item))
            }
        }
    }

    /// Commits a validated portable-deck plan as one database transaction.
    /// Cards are deliberately generated here rather than accepted from the
    /// package, so imported scheduling state always starts fresh.
    func importPortableDeck(
        _ plan: PortableDeckImportPlan,
        now: Date,
        initialDueDates: [UUID: Date] = [:]
    ) throws {
        try inTransaction {
            for itemType in plan.itemTypes {
                try insertItemType(itemType)
            }
            for itemTypeID in plan.libraryItemTypeIDs {
                try markItemTypeAsLibrary(itemTypeID)
            }
            for mapping in plan.mappings {
                try persistPortableItemTypeMapping(
                    originLibraryID: mapping.originLibraryID,
                    originTypeID: mapping.originTypeID,
                    schemaDigest: mapping.digest,
                    localTypeID: mapping.localTypeID
                )
            }
            for deck in plan.decks {
                try insertDeck(deck)
            }
            for owner in plan.includedItemTypes {
                try execute(
                    """
                    INSERT INTO deck_included_item_types
                        (root_deck_id, item_type_id, ordinal)
                    VALUES (?, ?, ?)
                    ON CONFLICT(root_deck_id, item_type_id) DO UPDATE SET
                        ordinal = excluded.ordinal;
                    """,
                    bindings: [
                        .text(owner.rootDeckID.uuidString),
                        .text(owner.itemTypeID.uuidString),
                        .int(Int64(owner.ordinal)),
                    ]
                )
            }
            for entry in plan.itemTypePolicies {
                try execute(
                    """
                    INSERT INTO deck_item_type_policy_entries
                        (deck_id, item_type_id, ordinal, is_default)
                    VALUES (?, ?, ?, ?);
                    """,
                    bindings: [
                        .text(entry.deckID.uuidString),
                        .text(entry.itemTypeID.uuidString),
                        .int(Int64(entry.ordinal)),
                        .int(entry.isDefault ? 1 : 0),
                    ]
                )
            }
            var itemTypesByID = Dictionary(uniqueKeysWithValues: plan.itemTypes.map { ($0.id, $0) })
            for itemTypeID in Set(plan.items.map(\.item.itemTypeID))
                where itemTypesByID[itemTypeID] == nil
            {
                guard let itemType = try fetchItemType(id: itemTypeID) else {
                    throw DatabaseError.itemTypeNotFound(itemTypeID)
                }
                itemTypesByID[itemTypeID] = itemType
            }
            let itemStatement = try prepareStatement(
                """
                INSERT INTO items (id, item_type_id, fields, tags, deck_id, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """
            )
            let cardStatement = try prepareStatement(
                """
                INSERT INTO cards (
                    id, item_id, template_id, skill, memory, due_at, phase, lapses,
                    is_suspended, deck_id, cloze_group, memory_model_version,
                    memory_parameter_set_id, scheduling_history_origin
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
            )
            let browseStatement = try prepareStatement(
                """
                INSERT INTO item_browse_rows (
                    item_id, item_type_id, item_type_name, title, subtitle,
                    deck_id, created_at, card_count, due_at, phase, lapses
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(item_id) DO UPDATE SET
                    item_type_id = excluded.item_type_id,
                    item_type_name = excluded.item_type_name,
                    title = excluded.title,
                    subtitle = excluded.subtitle,
                    deck_id = excluded.deck_id,
                    created_at = excluded.created_at,
                    card_count = excluded.card_count,
                    due_at = excluded.due_at,
                    phase = excluded.phase,
                    lapses = excluded.lapses;
                """
            )
            defer {
                sqlite3_finalize(itemStatement)
                sqlite3_finalize(cardStatement)
                sqlite3_finalize(browseStatement)
            }
            for entry in plan.items {
                guard let itemType = itemTypesByID[entry.item.itemTypeID] else {
                    throw DatabaseError.itemTypeNotFound(entry.item.itemTypeID)
                }
                try applyMediaReferenceDeltas(
                    from: [:],
                    to: mediaReferenceCounts(in: entry.item),
                    descriptors: [:],
                    now: now
                )
                try executePrepared(
                    itemStatement,
                    bindings: [
                        .text(entry.item.id.uuidString),
                        .text(entry.item.itemTypeID.uuidString),
                        .blob(try encode(entry.item.fields)),
                        .blob(try encode(entry.item.tags)),
                        entry.item.deckID.map { .text($0.uuidString) } ?? .null,
                        .double(entry.createdAt.timeIntervalSince1970),
                        .double(entry.updatedAt.timeIntervalSince1970),
                    ]
                )
                let cards = CardGenerator.cards(
                    for: entry.item,
                    type: itemType,
                    now: initialDueDates[entry.item.id] ?? now
                )
                var earliestActiveCard: Card?
                var maximumActiveLapses = 0
                for card in cards {
                    try executePrepared(
                        cardStatement,
                        bindings: [
                            .text(card.id.uuidString),
                            .text(card.itemID.uuidString),
                            .text(card.templateID.uuidString),
                            .blob(try encode(card.skill)),
                            .blob(try encode(card.memory)),
                            .double(card.memory.due.timeIntervalSince1970),
                            .text(card.memory.phase.rawValue),
                            .int(Int64(card.memory.lapses)),
                            .int(card.isSuspended ? 1 : 0),
                            card.deckID.map { .text($0.uuidString) } ?? .null,
                            card.clozeGroup.map { .int(Int64($0)) } ?? .null,
                            card.memoryModelVersion.map(Binding.text) ?? .null,
                            card.memoryParameterSetID.map { .text($0.uuidString) } ?? .null,
                            card.schedulingHistoryOrigin.map { .double($0.timeIntervalSince1970) } ?? .null,
                        ]
                    )
                    guard !card.isSuspended else { continue }
                    maximumActiveLapses = max(maximumActiveLapses, card.memory.lapses)
                    if let earliest = earliestActiveCard {
                        if card.memory.due < earliest.memory.due
                            || (card.memory.due == earliest.memory.due
                                && card.id.uuidString < earliest.id.uuidString)
                        {
                            earliestActiveCard = card
                        }
                    } else {
                        earliestActiveCard = card
                    }
                }
                try executePrepared(
                    browseStatement,
                    bindings: [
                        .text(entry.item.id.uuidString),
                        .text(itemType.id.uuidString),
                        .text(itemType.name),
                        .text(ItemDisplay.title(for: entry.item, in: itemType)),
                        .text(ItemDisplay.subtitle(for: entry.item, in: itemType)),
                        entry.item.deckID.map { .text($0.uuidString) } ?? .null,
                        .double(entry.createdAt.timeIntervalSince1970),
                        .int(Int64(cards.count)),
                        earliestActiveCard.map { .double($0.memory.due.timeIntervalSince1970) }
                            ?? .null,
                        earliestActiveCard.map { .text($0.memory.phase.rawValue) } ?? .null,
                        .int(Int64(maximumActiveLapses)),
                    ]
                )
                try consumeMediaReservations(ids: mediaReservationIDs(in: entry.item))
            }
        }
    }

    func updateItemWithMedia(
        _ item: Item,
        desiredCards: [Card],
        updatedAt: Date,
        mediaDescriptors: [String: MediaAssetDescriptor]
    ) throws {
        try inTransaction {
            try updateItemWithMediaWithoutTransaction(
                item,
                desiredCards: desiredCards,
                updatedAt: updatedAt,
                mediaDescriptors: mediaDescriptors
            )
        }
    }

    private func updateItemWithMediaWithoutTransaction(
        _ item: Item,
        desiredCards: [Card],
        updatedAt: Date,
        mediaDescriptors: [String: MediaAssetDescriptor]
    ) throws {
        guard let previous = try fetchItem(id: item.id) else {
            throw DatabaseError.invalidMediaAsset("The item being edited no longer exists.")
        }
        try validateMediaAdoption(in: item, comparedTo: previous.item, now: updatedAt)
        try applyMediaReferenceDeltas(
            from: mediaReferenceCounts(in: previous.item),
            to: mediaReferenceCounts(in: item),
            descriptors: mediaDescriptors,
            now: updatedAt
        )
        let fields = try encode(item.fields)
        let tags = try encode(item.tags)
        try execute(
            """
            UPDATE items
            SET item_type_id = ?, fields = ?, tags = ?, deck_id = ?, updated_at = ?
            WHERE id = ?;
            """,
            bindings: [
                .text(item.itemTypeID.uuidString),
                .blob(fields),
                .blob(tags),
                item.deckID.map { .text($0.uuidString) } ?? .null,
                .double(updatedAt.timeIntervalSince1970),
                .text(item.id.uuidString),
            ]
        )
        try reconcileCards(for: item.id, desired: desiredCards)
        guard let itemType = try fetchValidatedItemType(id: item.itemTypeID) else {
            throw DatabaseError.itemTypeNotFound(item.itemTypeID)
        }
        try upsertBrowseProjection(item, itemType: itemType, createdAt: previous.createdAt)
        try consumeMediaReservations(ids: mediaReservationIDs(in: item))
    }

    func applyItemBulk(_ mutations: [ItemBulkDatabaseMutation]) throws {
        try inTransaction {
            for mutation in mutations {
                switch mutation {
                case let .create(item, cards, descriptors, createdAt):
                    try insertItemWithCardsWithoutTransaction(
                        item,
                        cards: cards,
                        createdAt: createdAt,
                        updatedAt: createdAt,
                        mediaDescriptors: descriptors
                    )
                case let .replace(item, cards, descriptors, updatedAt):
                    try updateItemWithMediaWithoutTransaction(
                        item,
                        desiredCards: cards,
                        updatedAt: updatedAt,
                        mediaDescriptors: descriptors
                    )
                case let .delete(id, deletedAt):
                    guard try deleteItemWithMediaWithoutTransaction(id: id, deletedAt: deletedAt) else {
                        throw DatabaseError.itemNotFound(id)
                    }
                }
            }
        }
    }

    func deleteItemWithMedia(id: UUID, deletedAt: Date) throws -> Bool {
        try inTransaction {
            try deleteItemWithMediaWithoutTransaction(id: id, deletedAt: deletedAt)
        }
    }

    func deleteItemWithMediaWithoutTransaction(id: UUID, deletedAt: Date) throws -> Bool {
        guard let persisted = try fetchItem(id: id) else { return false }
        try deactivateReviewHistory(
            cardIDs: try fetchCards(for: id).map(\.id),
            revertedAt: deletedAt
        )
        try applyMediaReferenceDeltas(
            from: mediaReferenceCounts(in: persisted.item),
            to: [:],
            descriptors: [:],
            now: deletedAt
        )
        try deleteItem(id: id)
        return true
    }

    private func deactivateReviewHistory(cardIDs: [UUID], revertedAt: Date) throws {
        guard !cardIDs.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: cardIDs.count).joined(separator: ", ")
        let bindings = cardIDs.map { Binding.text($0.uuidString) }
        let activeLogIDs = try query(
            """
            SELECT review_logs.id
            FROM review_logs
            LEFT JOIN review_reverts
                ON review_reverts.review_log_id = review_logs.id
            WHERE review_logs.card_id IN (\(placeholders))
              AND review_reverts.id IS NULL;
            """,
            bindings: bindings
        ).compactMap { $0["id"] as? String }
        for logID in activeLogIDs {
            try execute(
                """
                INSERT INTO review_reverts (id, review_log_id, reverted_at)
                VALUES (?, ?, ?);
                """,
                bindings: [
                    .text(UUID().uuidString),
                    .text(logID),
                    .double(revertedAt.timeIntervalSince1970),
                ]
            )
        }
    }

    private func deleteReviewHistory(cardIDs: [UUID]) throws {
        guard !cardIDs.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: cardIDs.count).joined(separator: ", ")
        let bindings = cardIDs.map { Binding.text($0.uuidString) }
        try execute(
            """
            DELETE FROM new_card_introductions
            WHERE review_log_id IN (
                SELECT id FROM review_logs WHERE card_id IN (\(placeholders))
            );
            """,
            bindings: bindings
        )
        try execute(
            """
            DELETE FROM review_reverts
            WHERE review_log_id IN (
                SELECT id FROM review_logs WHERE card_id IN (\(placeholders))
            );
            """,
            bindings: bindings
        )
        try execute(
            "DELETE FROM review_logs WHERE card_id IN (\(placeholders));",
            bindings: bindings
        )
    }

    func insertItem(_ item: Item, createdAt: Date, updatedAt: Date) throws {
        let fields = try encode(item.fields)
        let tags = try encode(item.tags)
        try execute(
            """
            INSERT INTO items (id, item_type_id, fields, tags, deck_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .text(item.id.uuidString),
                .text(item.itemTypeID.uuidString),
                .blob(fields),
                .blob(tags),
                item.deckID.map { .text($0.uuidString) } ?? .null,
                .double(createdAt.timeIntervalSince1970),
                .double(updatedAt.timeIntervalSince1970),
            ]
        )
    }

    func insertCards(_ cards: [Card]) throws {
        for card in cards {
            let skill = try encode(card.skill)
            let memory = try encode(card.memory)
            try execute(
                """
                INSERT INTO cards (
                    id, item_id, template_id, skill, memory, due_at, phase, lapses,
                    is_suspended, deck_id, cloze_group, memory_model_version,
                    memory_parameter_set_id, scheduling_history_origin
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                bindings: [
                    .text(card.id.uuidString),
                    .text(card.itemID.uuidString),
                    .text(card.templateID.uuidString),
                    .blob(skill),
                    .blob(memory),
                    .double(card.memory.due.timeIntervalSince1970),
                    .text(card.memory.phase.rawValue),
                    .int(Int64(card.memory.lapses)),
                    .int(card.isSuspended ? 1 : 0),
                    card.deckID.map { .text($0.uuidString) } ?? .null,
                    card.clozeGroup.map { .int(Int64($0)) } ?? .null,
                    card.memoryModelVersion.map(Binding.text) ?? .null,
                    card.memoryParameterSetID.map { .text($0.uuidString) } ?? .null,
                    card.schedulingHistoryOrigin.map { .double($0.timeIntervalSince1970) } ?? .null,
                ]
            )
        }
    }

    /// Applies card state received from another replica without regenerating
    /// its scheduling fields. Item/template foreign keys are still enforced by
    /// SQLite, so callers must dependency-order their batch.
    func upsertSynchronizedCard(_ card: Card) throws {
        let skill = try encode(card.skill)
        let memory = try encode(card.memory)
        try execute(
            """
            INSERT INTO cards (
                id, item_id, template_id, skill, memory, due_at, phase, lapses,
                is_suspended, deck_id, cloze_group, memory_model_version,
                memory_parameter_set_id, scheduling_history_origin
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                item_id = excluded.item_id,
                template_id = excluded.template_id,
                skill = excluded.skill,
                memory = excluded.memory,
                due_at = excluded.due_at,
                phase = excluded.phase,
                lapses = excluded.lapses,
                is_suspended = excluded.is_suspended,
                deck_id = excluded.deck_id,
                cloze_group = excluded.cloze_group,
                memory_model_version = excluded.memory_model_version,
                memory_parameter_set_id = excluded.memory_parameter_set_id,
                scheduling_history_origin = excluded.scheduling_history_origin;
            """,
            bindings: [
                .text(card.id.uuidString), .text(card.itemID.uuidString), .text(card.templateID.uuidString),
                .blob(skill), .blob(memory), .double(card.memory.due.timeIntervalSince1970),
                .text(card.memory.phase.rawValue), .int(Int64(card.memory.lapses)),
                .int(card.isSuspended ? 1 : 0),
                card.deckID.map { .text($0.uuidString) } ?? .null,
                card.clozeGroup.map { .int(Int64($0)) } ?? .null,
                card.memoryModelVersion.map(Binding.text) ?? .null,
                card.memoryParameterSetID.map { .text($0.uuidString) } ?? .null,
                card.schedulingHistoryOrigin.map { .double($0.timeIntervalSince1970) } ?? .null,
            ]
        )
    }

    func fetchCard(id: UUID) throws -> Card? {
        let rows = try query(
            """
            SELECT id, item_id, template_id, skill, memory, is_suspended, deck_id, cloze_group,
                   memory_model_version, memory_parameter_set_id, scheduling_history_origin
            FROM cards
            WHERE id = ?
            LIMIT 1;
            """,
            bindings: [.text(id.uuidString)]
        )
        guard let row = rows.first else { return nil }
        return try decodeCard(from: row)
    }

    func fetchAllCards() throws -> [Card] {
        let rows = try query(
            """
            SELECT id, item_id, template_id, skill, memory, is_suspended, deck_id, cloze_group,
                   memory_model_version, memory_parameter_set_id, scheduling_history_origin
            FROM cards
            ORDER BY id ASC;
            """
        )
        return try rows.map { try decodeCard(from: $0) }
    }

    func supportsVersionedCardReplay() throws -> Bool {
        guard try tableExists("cards") else { return false }
        for column in [
            "id", "item_id", "template_id", "skill", "memory", "is_suspended",
            "deck_id", "cloze_group", "memory_model_version",
            "memory_parameter_set_id", "scheduling_history_origin",
        ] where !(try columnExists(column, in: "cards")) {
            return false
        }
        return true
    }

    func setCardSuspended(id: UUID, isSuspended: Bool) throws {
        try inTransaction {
            guard try fetchCard(id: id) != nil else { throw DatabaseError.cardNotFound(id) }
            try execute(
                "UPDATE cards SET is_suspended = ? WHERE id = ?;",
                bindings: [.int(isSuspended ? 1 : 0), .text(id.uuidString)]
            )
        }
    }

    func resetCardProgress(id: UUID, now: Date) throws {
        try inTransaction {
            guard var card = try fetchCard(id: id) else { throw DatabaseError.cardNotFound(id) }
            try deleteReviewHistory(cardIDs: [id])
            card.memory = .new(due: now)
            try updateCardMemory(id, memory: card.memory)
            try execute(
                "DELETE FROM api_card_reservations WHERE card_id = ?;",
                bindings: [.text(id.uuidString)]
            )
        }
    }

    func fetchDueCards(asOf now: Date, studyDay: String, limit: Int? = nil) throws -> [Card] {
        try inReadTransaction {
            try fetchStudyQueueCards(
                scope: .all,
                asOf: now,
                studyDay: studyDay,
                limit: limit
            )
        }
    }

    func countDueCards(asOf now: Date, studyDay: String) throws -> Int {
        try inReadTransaction {
            let eligible = try eligibleDueCardsCTE(scope: .all, asOf: now, studyDay: studyDay)
            let rows = try query(
                eligible.sql + "\nSELECT COUNT(*) AS count FROM eligible_due;",
                bindings: eligible.bindings
            )
            guard let count = rows.first?["count"] as? Int64 else { return 0 }
            return Int(count)
        }
    }

    func nextUnsuspendedCardDue(after now: Date) throws -> Date? {
        let rows = try query(
            """
            SELECT MIN(due_at) AS next_due_at
            FROM cards
            WHERE is_suspended = 0 AND due_at > ?;
            """,
            bindings: [.double(now.timeIntervalSince1970)]
        )
        return (rows.first?["next_due_at"] as? Double).map {
            Date(timeIntervalSince1970: $0)
        }
    }

    /// Card counts and rolled-up scheduling state for every item, read in one
    /// scan. Browsing a few thousand items otherwise costs a query per row.
    func fetchItemCardStates() throws -> [UUID: ItemCardState] {
        foldItemCardStates(
            try query(
                """
                SELECT item_id, phase, due_at, lapses, is_suspended
                FROM cards
                ORDER BY item_id ASC, due_at ASC;
                """
            )
        )
    }

    func fetchItemCardStates(deckIDs: Set<UUID>) throws -> [UUID: ItemCardState] {
        guard !deckIDs.isEmpty else { return [:] }
        let sortedIDs = deckIDs.sorted { $0.uuidString < $1.uuidString }
        let placeholders = Array(repeating: "?", count: sortedIDs.count).joined(separator: ", ")
        return foldItemCardStates(
            try query(
                """
                SELECT item_id, phase, due_at, lapses, is_suspended
                FROM cards
                WHERE deck_id IN (\(placeholders))
                ORDER BY item_id ASC, due_at ASC;
                """,
                bindings: sortedIDs.map { .text($0.uuidString) }
            )
        )
    }

    func fetchItemCardStatesUnassigned() throws -> [UUID: ItemCardState] {
        foldItemCardStates(
            try query(
                """
                SELECT item_id, phase, due_at, lapses, is_suspended
                FROM cards
                WHERE deck_id IS NULL
                ORDER BY item_id ASC, due_at ASC;
                """
            )
        )
    }

    func fetchItemCardStates(itemIDs: [UUID]) throws -> [UUID: ItemCardState] {
        guard !itemIDs.isEmpty else { return [:] }
        var merged: [UUID: ItemCardState] = [:]
        let chunkSize = 500
        var start = 0
        while start < itemIDs.count {
            let end = min(start + chunkSize, itemIDs.count)
            let chunk = Array(itemIDs[start..<end])
            start = end
            let sortedChunk = chunk.sorted { $0.uuidString < $1.uuidString }
            let placeholders = Array(repeating: "?", count: sortedChunk.count).joined(separator: ", ")
            let states = foldItemCardStates(
                try query(
                    """
                    SELECT item_id, phase, due_at, lapses, is_suspended
                    FROM cards
                    WHERE item_id IN (\(placeholders))
                    ORDER BY item_id ASC, due_at ASC;
                    """,
                    bindings: sortedChunk.map { .text($0.uuidString) }
                )
            )
            merged.merge(states) { _, new in new }
        }
        return merged
    }

    func fetchItemCardState(itemID: UUID) throws -> ItemCardState {
        let states = foldItemCardStates(
            try query(
                """
                SELECT item_id, phase, due_at, lapses, is_suspended
                FROM cards
                WHERE item_id = ?
                ORDER BY due_at ASC;
                """,
                bindings: [.text(itemID.uuidString)]
            )
        )
        return states[itemID] ?? ItemCardState()
    }

    /// Expects rows ordered by `due_at` ascending within each item.
    private func foldItemCardStates(_ rows: [[String: Any?]]) -> [UUID: ItemCardState] {
        var states: [UUID: ItemCardState] = [:]
        for row in rows {
            guard
                let itemIDText = row["item_id"] as? String,
                let itemID = UUID(uuidString: itemIDText)
            else { continue }

            var state = states[itemID] ?? ItemCardState()
            state.cardCount += 1

            let isSuspended = (row["is_suspended"] as? Int64 ?? 0) != 0
            if !isSuspended {
                state.lapses = max(state.lapses, Int(row["lapses"] as? Int64 ?? 0))
                // Rows arrive due-ascending, so the first unsuspended card seen
                // for an item is the one the learner meets next.
                if state.dueAt == nil, let dueAt = row["due_at"] as? Double {
                    state.dueAt = Date(timeIntervalSince1970: dueAt)
                    state.phase = (row["phase"] as? String).flatMap(Phase.init(rawValue:))
                }
            }

            states[itemID] = state
        }
        return states
    }

    /// Resolves every library-summary aggregate in one pass. Conditional
    /// aggregates keep this to a single scan instead of one query per statistic.
    func cardScheduleTotals(
        scope: CardScope,
        asOf now: Date,
        studyDay: String,
        leechThreshold: Int
    ) throws -> CardScheduleTotals {
        try inReadTransaction {
        let cardScope = scope
        let scopeFilter = scopeClause(cardScope, column: "deck_id")
        let rows = try query(
            """
            SELECT
                COUNT(*) AS card_count,
                SUM(CASE WHEN is_suspended = 0 AND phase = 'new' AND due_at <= ?
                    THEN 1 ELSE 0 END) AS due_new_count,
                SUM(CASE WHEN is_suspended = 0 AND phase = 'new' THEN 1 ELSE 0 END) AS new_count,
                SUM(CASE WHEN is_suspended = 0 AND phase = 'learning' THEN 1 ELSE 0 END)
                    AS learning_count,
                SUM(CASE WHEN is_suspended = 0 AND phase = 'relearning' THEN 1 ELSE 0 END)
                    AS relearning_count,
                SUM(CASE WHEN is_suspended = 0 AND phase = 'review' THEN 1 ELSE 0 END)
                    AS review_count,
                SUM(CASE WHEN is_suspended = 0 AND lapses >= ? THEN 1 ELSE 0 END) AS leech_count,
                MIN(CASE WHEN is_suspended = 0 AND due_at > ? THEN due_at END) AS next_due_at
            FROM cards
            WHERE \(scopeFilter.sql);
            """,
            bindings: [
                .double(now.timeIntervalSince1970),
                .int(Int64(leechThreshold)),
                .double(now.timeIntervalSince1970),
            ] + scopeFilter.bindings
        )

        guard let row = rows.first else { return CardScheduleTotals() }
        func count(_ key: String) -> Int {
            guard let value = row[key] as? Int64 else { return 0 }
            return Int(value)
        }

        let eligible = try eligibleDueCardsCTE(
            scope: cardScope,
            asOf: now,
            studyDay: studyDay
        )
        let eligibleRow = try query(
            eligible.sql + """

            SELECT
                COUNT(*) AS due_now,
                SUM(CASE WHEN phase = 'new' THEN 1 ELSE 0 END) AS available_new_count
            FROM eligible_due;
            """,
            bindings: eligible.bindings
        ).first
        func eligibleCount(_ key: String) -> Int {
            guard let value = eligibleRow?[key] as? Int64 else { return 0 }
            return Int(value)
        }
        let availableNewCount = eligibleCount("available_new_count")

        return CardScheduleTotals(
            cardCount: count("card_count"),
            dueNow: eligibleCount("due_now"),
            newCount: count("new_count"),
            availableNewCount: availableNewCount,
            hiddenNewCount: max(count("due_new_count") - availableNewCount, 0),
            learningCount: count("learning_count"),
            relearningCount: count("relearning_count"),
            reviewCount: count("review_count"),
            leechCount: count("leech_count"),
            nextDueAt: (row["next_due_at"] as? Double).map {
                Date(timeIntervalSince1970: $0)
            }
        )
        }
    }

    func countItems(scope: CardScope) throws -> Int {
        let scope = scopeClause(scope, column: "deck_id")
        let rows = try query(
            "SELECT COUNT(*) AS count FROM items WHERE \(scope.sql);",
            bindings: scope.bindings
        )
        guard let count = rows.first?["count"] as? Int64 else { return 0 }
        return Int(count)
    }

    private func eligibleDueCardsCTE(
        scope: CardScope,
        asOf now: Date,
        studyDay: String
    ) throws -> (sql: String, bindings: [Binding]) {
        let scopeFilter = scopeClause(scope, column: "cards.deck_id")
        switch try newCardLimitShape(scope: scope, studyDay: studyDay) {
        case .none:
            return (
                """
                WITH eligible_due AS (
                    SELECT cards.*
                    FROM cards
                    WHERE cards.is_suspended = 0
                      AND cards.due_at <= ?
                      AND \(scopeFilter.sql)
                )
                """,
                [.double(now.timeIntervalSince1970)] + scopeFilter.bindings
            )
        case let .single(limiter):
            return singleLimiterEligibleDueCardsCTE(
                scopeFilter: scopeFilter,
                asOf: now,
                limiter: limiter
            )
        case let .multiple(limiters):
            return multipleLimiterEligibleDueCardsCTE(
                scopeFilter: scopeFilter,
                asOf: now,
                studyDay: studyDay,
                limiters: limiters
            )
        }
    }

    /// Test and profiling diagnostic for keeping startup-sensitive eligibility
    /// reads on their intended SQLite plan.
    func dueEligibilityQueryPlan(
        scope: CardScope,
        asOf now: Date,
        studyDay: String
    ) throws -> [String] {
        try inReadTransaction {
            let eligible = try eligibleDueCardsCTE(scope: scope, asOf: now, studyDay: studyDay)
            return try query(
                "EXPLAIN QUERY PLAN " + eligible.sql
                    + "\nSELECT COUNT(*) AS count FROM eligible_due;",
                bindings: eligible.bindings
            ).compactMap { $0["detail"] as? String }
        }
    }

    /// Test and profiling diagnostic for the two queue partitions selected by
    /// `fetchStudyQueueCards`.
    func studyQueueQueryPlan(
        scope: CardScope,
        asOf now: Date,
        studyDay: String,
        isNew: Bool
    ) throws -> [String] {
        try inReadTransaction {
            let statement = try studyQueueStatement(
                scope: scope,
                asOf: now,
                studyDay: studyDay,
                isNew: isNew,
                limit: 1
            )
            return try query(
                "EXPLAIN QUERY PLAN " + statement.sql,
                bindings: statement.bindings
            ).compactMap { $0["detail"] as? String }
        }
    }

    /// Deterministic regression hook proving that plan selection and execution
    /// share a read snapshot even when another connection commits in between.
    func countDueCardsSnapshotDiagnostic(
        asOf now: Date,
        studyDay: String,
        afterPlanning: @Sendable () throws -> Void
    ) throws -> Int {
        try inReadTransaction {
            let eligible = try eligibleDueCardsCTE(scope: .all, asOf: now, studyDay: studyDay)
            try afterPlanning()
            let rows = try query(
                eligible.sql + "\nSELECT COUNT(*) AS count FROM eligible_due;",
                bindings: eligible.bindings
            )
            guard let count = rows.first?["count"] as? Int64 else { return 0 }
            return Int(count)
        }
    }

    /// Classifies configured limiters before composing the due query. The
    /// single-limiter shape can select only its remaining top-K cards. Multiple
    /// limiters are applied from the deepest deck level toward the roots so a
    /// child rejection does not strand capacity in an ancestor.
    private func newCardLimitShape(
        scope: CardScope,
        studyDay: String
    ) throws -> NewCardLimitShape {
        if case .unassigned = scope {
            return .none
        }

        // Preserve the direct unlimited fast path: most libraries have no
        // limiter, and discovering that should not require materializing the
        // whole deck topology on every due read.
        let preliminaryLimiters: [[String: Any?]]?
        switch scope {
        case .unassigned:
            return .none
        case .all:
            preliminaryLimiters = try query(
                "SELECT id FROM decks WHERE new_cards_per_day IS NOT NULL LIMIT 2;"
            )
        case let .decks(deckIDs) where deckIDs.count <= 800:
            guard !deckIDs.isEmpty else { return .none }
            let ordered = deckIDs.sorted { $0.uuidString < $1.uuidString }
            let values = Array(repeating: "(?)", count: ordered.count)
                .joined(separator: ", ")
            preliminaryLimiters = try query(
                """
                WITH RECURSIVE selected_decks(id) AS (
                    VALUES \(values)
                ),
                relevant_decks(id) AS (
                    SELECT id FROM selected_decks
                    UNION
                    SELECT decks.parent_id
                    FROM decks
                    JOIN relevant_decks ON decks.id = relevant_decks.id
                    WHERE decks.parent_id IS NOT NULL
                )
                SELECT decks.id
                FROM decks
                JOIN relevant_decks ON relevant_decks.id = decks.id
                WHERE decks.new_cards_per_day IS NOT NULL
                LIMIT 2;
                """,
                bindings: ordered.map { .text($0.uuidString) }
            )
        case .decks:
            preliminaryLimiters = nil
        }
        if preliminaryLimiters?.isEmpty == true {
            return .none
        }

        let topologyRows = try query(
            "SELECT id, parent_id, new_cards_per_day FROM decks;"
        )
        var parentByDeck: [String: String] = [:]
        var childrenByParent: [String: [String]] = [:]
        var limitsByDeck: [String: Int] = [:]
        for row in topologyRows {
            guard let id = row["id"] as? String else { continue }
            if let parentID = row["parent_id"] as? String {
                parentByDeck[id] = parentID
                childrenByParent[parentID, default: []].append(id)
            }
            if let limit = row["new_cards_per_day"] as? Int64 {
                limitsByDeck[id] = Int(limit)
            }
        }

        let relevantLimiterIDs: Set<String>
        switch scope {
        case .unassigned:
            return .none
        case .all:
            relevantLimiterIDs = Set(limitsByDeck.keys)
        case let .decks(deckIDs):
            guard !deckIDs.isEmpty else { return .none }
            var relevant: Set<String> = []
            for selectedID in deckIDs.map(\.uuidString) {
                var current: String? = selectedID
                var visited: Set<String> = []
                while let deckID = current, visited.insert(deckID).inserted {
                    if limitsByDeck[deckID] != nil {
                        relevant.insert(deckID)
                    }
                    current = parentByDeck[deckID]
                }
            }
            relevantLimiterIDs = relevant
        }

        guard let limiterID = relevantLimiterIDs.first else { return .none }
        guard relevantLimiterIDs.count == 1,
              let dailyLimit = limitsByDeck[limiterID]
        else {
            func depth(of deckID: String) -> Int {
                var result = 0
                var current = deckID
                var visited: Set<String> = [deckID]
                while let parent = parentByDeck[current], visited.insert(parent).inserted {
                    result += 1
                    current = parent
                }
                return result
            }
            let depths = Set(relevantLimiterIDs.map(depth))
                .sorted(by: >)
            return .multiple(MultipleNewCardLimiters(depths: depths))
        }

        var descendants: Set<String> = [limiterID]
        var frontier = [limiterID]
        while let parentID = frontier.popLast() {
            for childID in childrenByParent[parentID, default: []]
            where descendants.insert(childID).inserted {
                frontier.append(childID)
            }
        }

        let selectedDeckIDs: Set<String>
        switch scope {
        case .all:
            selectedDeckIDs = descendants
        case let .decks(deckIDs):
            selectedDeckIDs = descendants.intersection(deckIDs.map(\.uuidString))
        case .unassigned:
            return .none
        }
        guard !selectedDeckIDs.isEmpty else { return .none }

        // Keep well below SQLite's historical 999-variable ceiling after the
        // outer scope bindings are added. Larger topologies retain the general
        // CTE, which has no variable-per-deck expansion.
        let scopeBindingCount: Int
        if case let .decks(deckIDs) = scope {
            scopeBindingCount = deckIDs.count
        } else {
            scopeBindingCount = 0
        }
        guard selectedDeckIDs.count + scopeBindingCount + 3 <= 900 else {
            var limiterDepth = 0
            var current = limiterID
            var visited: Set<String> = [limiterID]
            while let parent = parentByDeck[current], visited.insert(parent).inserted {
                limiterDepth += 1
                current = parent
            }
            return .multiple(MultipleNewCardLimiters(depths: [limiterDepth]))
        }

        let introductionRows = try query(
            """
            WITH RECURSIVE limiter_decks(id) AS (
                SELECT ?
                UNION
                SELECT decks.id
                FROM decks
                JOIN limiter_decks
                    ON decks.parent_id = limiter_decks.id
            )
            SELECT COUNT(*) AS introduced_count
            FROM new_card_introductions AS introductions
            JOIN limiter_decks
                ON limiter_decks.id = introductions.deck_id
            LEFT JOIN review_reverts
                ON review_reverts.review_log_id = introductions.review_log_id
            WHERE introductions.study_day = ?
              AND review_reverts.id IS NULL;
            """,
            bindings: [.text(limiterID), .text(studyDay)]
        )
        let introduced = Int(
            introductionRows.first?["introduced_count"] as? Int64 ?? 0
        )
        return .single(SingleNewCardLimiter(
            deckIDs: selectedDeckIDs.sorted(),
            remainingCapacity: max(dailyLimit - introduced, 0)
        ))
    }

    /// Applies a laminar family of deck limits bottom-up. At each depth the
    /// earliest surviving cards in every limited subtree consume that subtree's
    /// remaining slots. Ancestors then rank only those survivors, so capacity
    /// rejected by a stricter child is available to a sibling candidate.
    private func multipleLimiterEligibleDueCardsCTE(
        scopeFilter: (sql: String, bindings: [Binding]),
        asOf now: Date,
        studyDay: String,
        limiters: MultipleNewCardLimiters
    ) -> (sql: String, bindings: [Binding]) {
        let cardColumns = [
            "id", "item_id", "template_id", "skill", "memory", "is_suspended",
            "deck_id", "due_at", "cloze_group", "phase", "lapses",
            "memory_model_version", "memory_parameter_set_id", "scheduling_history_origin",
        ].joined(separator: ", ")
        var commonTableExpressions = [
            """
            deck_ancestry(descendant_id, ancestor_id) AS (
                SELECT id, id FROM decks
                UNION
                SELECT ancestry.descendant_id, decks.parent_id
                FROM deck_ancestry AS ancestry
                JOIN decks ON decks.id = ancestry.ancestor_id
                WHERE decks.parent_id IS NOT NULL
            )
            """,
            """
            deck_depth(id, depth) AS (
                SELECT id, 0 FROM decks WHERE parent_id IS NULL
                UNION ALL
                SELECT decks.id, deck_depth.depth + 1
                FROM decks
                JOIN deck_depth ON decks.parent_id = deck_depth.id
            )
            """,
            """
            active_introductions AS (
                SELECT ancestry.ancestor_id AS limiter_id, COUNT(*) AS introduced_count
                FROM new_card_introductions AS introductions
                JOIN deck_ancestry AS ancestry
                    ON ancestry.descendant_id = introductions.deck_id
                LEFT JOIN review_reverts
                    ON review_reverts.review_log_id = introductions.review_log_id
                WHERE introductions.study_day = ?
                  AND review_reverts.id IS NULL
                GROUP BY ancestry.ancestor_id
            )
            """,
            """
            card_limiters AS (
                SELECT
                    ancestry.descendant_id AS deck_id,
                    limiter.id AS limiter_id,
                    deck_depth.depth,
                    MAX(
                        limiter.new_cards_per_day
                            - COALESCE(active_introductions.introduced_count, 0),
                        0
                    ) AS remaining_capacity
                FROM decks AS limiter
                JOIN deck_depth ON deck_depth.id = limiter.id
                JOIN deck_ancestry AS ancestry ON ancestry.ancestor_id = limiter.id
                LEFT JOIN active_introductions
                    ON active_introductions.limiter_id = limiter.id
                WHERE limiter.new_cards_per_day IS NOT NULL
            )
            """,
            """
            due_cards AS (
                SELECT cards.*
                FROM cards
                WHERE cards.is_suspended = 0
                  AND cards.due_at <= ?
                  AND \(scopeFilter.sql)
            )
            """,
            """
            limited_new_0 AS (
                SELECT \(cardColumns)
                FROM due_cards
                WHERE phase = 'new'
            )
            """,
        ]

        var previousStage = "limited_new_0"
        for (offset, depth) in limiters.depths.enumerated() {
            let stage = offset + 1
            let rankedStage = "ranked_new_\(stage)"
            let limitedStage = "limited_new_\(stage)"
            commonTableExpressions.append(
                """
                \(rankedStage) AS (
                    SELECT
                        candidates.*,
                        limiter.limiter_id AS active_limiter_id,
                        limiter.remaining_capacity,
                        ROW_NUMBER() OVER (
                            PARTITION BY limiter.limiter_id
                            ORDER BY candidates.due_at ASC, candidates.id ASC
                        ) AS limiter_rank
                    FROM \(previousStage) AS candidates
                    LEFT JOIN card_limiters AS limiter
                        ON limiter.deck_id = candidates.deck_id
                       AND limiter.depth = \(depth)
                )
                """
            )
            commonTableExpressions.append(
                """
                \(limitedStage) AS (
                    SELECT \(cardColumns)
                    FROM \(rankedStage)
                    WHERE active_limiter_id IS NULL
                       OR limiter_rank <= remaining_capacity
                )
                """
            )
            previousStage = limitedStage
        }

        commonTableExpressions.append(
            """
            eligible_due AS (
                SELECT due_cards.*
                FROM due_cards
                WHERE due_cards.phase != 'new'
                UNION ALL
                SELECT due_cards.*
                FROM due_cards
                JOIN \(previousStage) AS allowed_new
                    ON allowed_new.id = due_cards.id
            )
            """
        )

        return (
            "WITH RECURSIVE " + commonTableExpressions.joined(separator: ",\n"),
            [.text(studyDay), .double(now.timeIntervalSince1970)] + scopeFilter.bindings
        )
    }

    private func singleLimiterEligibleDueCardsCTE(
        scopeFilter: (sql: String, bindings: [Binding]),
        asOf now: Date,
        limiter: SingleNewCardLimiter
    ) -> (sql: String, bindings: [Binding]) {
        let deckValues = Array(repeating: "(?)", count: limiter.deckIDs.count)
            .joined(separator: ", ")
        return (
            """
            WITH limited_decks(deck_id) AS (
                VALUES \(deckValues)
            ),
            allowed_new AS (
                SELECT cards.id
                FROM cards
                JOIN limited_decks
                    ON limited_decks.deck_id = cards.deck_id
                WHERE cards.is_suspended = 0
                  AND cards.phase = 'new'
                  AND cards.due_at <= ?
                ORDER BY cards.due_at ASC, cards.id ASC
                LIMIT ?
            ),
            eligible_due AS (
                SELECT cards.*
                FROM cards
                WHERE cards.is_suspended = 0
                  AND cards.due_at <= ?
                  AND \(scopeFilter.sql)
                  AND (
                      cards.phase != 'new'
                      OR cards.deck_id IS NULL
                      OR NOT EXISTS (
                          SELECT 1
                          FROM limited_decks
                          WHERE limited_decks.deck_id = cards.deck_id
                      )
                      OR EXISTS (
                          SELECT 1
                          FROM allowed_new
                          WHERE allowed_new.id = cards.id
                      )
                  )
            )
            """,
            limiter.deckIDs.map { .text($0) }
                + [
                    .double(now.timeIntervalSince1970),
                    .int(Int64(limiter.remainingCapacity)),
                    .double(now.timeIntervalSince1970),
                ]
                + scopeFilter.bindings
        )
    }

    /// Deck identifiers are interpolated only as `?` placeholders; every value
    /// is bound, never inlined.
    private func scopeClause(
        _ scope: CardScope,
        column: String
    ) -> (sql: String, bindings: [Binding]) {
        switch scope {
        case .all:
            return ("1 = 1", [])
        case .unassigned:
            return ("\(column) IS NULL", [])
        case let .decks(deckIDs):
            guard !deckIDs.isEmpty else { return ("0 = 1", []) }
            let placeholders = Array(repeating: "?", count: deckIDs.count)
                .joined(separator: ", ")
            let ordered = deckIDs.sorted { $0.uuidString < $1.uuidString }
            return ("\(column) IN (\(placeholders))", ordered.map { .text($0.uuidString) })
        }
    }

    func updateCardMemory(_ cardID: UUID, memory: MemoryState) throws {
        let memoryData = try encode(memory)
        try execute(
            """
            UPDATE cards
            SET memory = ?, due_at = ?, phase = ?, lapses = ?
            WHERE id = ?;
            """,
            bindings: [
                .blob(memoryData),
                .double(memory.due.timeIntervalSince1970),
                .text(memory.phase.rawValue),
                .int(Int64(memory.lapses)),
                .text(cardID.uuidString),
            ]
        )
    }

    func updateCardSchedulingMemory(
        _ cardID: UUID,
        memory: MemoryState,
        modelVersion: String,
        parameterSetID: UUID?
    ) throws {
        let memoryData = try encode(memory)
        try execute(
            """
            UPDATE cards
            SET memory = ?, due_at = ?, phase = ?, lapses = ?,
                memory_model_version = ?, memory_parameter_set_id = ?
            WHERE id = ?;
            """,
            bindings: [
                .blob(memoryData),
                .double(memory.due.timeIntervalSince1970),
                .text(memory.phase.rawValue),
                .int(Int64(memory.lapses)),
                .text(modelVersion),
                parameterSetID.map { .text($0.uuidString) } ?? .null,
                .text(cardID.uuidString),
            ]
        )
    }

    func resetCardSchedulingMemory(
        _ cardID: UUID,
        modelVersion: String,
        parameterSetID: UUID,
        historyOrigin: Date
    ) throws {
        let memory = MemoryState.new(due: historyOrigin)
        try execute(
            """
            UPDATE cards
            SET memory = ?, due_at = ?, phase = ?, lapses = 0,
                memory_model_version = ?, memory_parameter_set_id = ?,
                scheduling_history_origin = ?
            WHERE id = ?;
            """,
            bindings: [
                .blob(try encode(memory)), .double(historyOrigin.timeIntervalSince1970),
                .text(Phase.new.rawValue), .text(modelVersion),
                .text(parameterSetID.uuidString), .double(historyOrigin.timeIntervalSince1970),
                .text(cardID.uuidString),
            ]
        )
    }

    private func setCardSchedulingHistoryOrigin(_ cardID: UUID, origin: Date?) throws {
        try execute(
            "UPDATE cards SET scheduling_history_origin = ? WHERE id = ?;",
            bindings: [
                origin.map { .double($0.timeIntervalSince1970) } ?? .null,
                .text(cardID.uuidString),
            ]
        )
    }

    func insertReviewLog(_ log: ReviewLog, memoryBefore: MemoryState) throws {
        let nextSequence = try nextReviewSequence()
        let sequencedLog = log.withSequence(nextSequence)
        let data = try encode(sequencedLog)
        let memoryData = try encode(memoryBefore)
        let memoryAfterData = try sequencedLog.schedulingAudit.map { try encode($0.memoryAfter) }
        let auditData = try sequencedLog.schedulingAudit.map(encode)
        try execute(
            """
            INSERT INTO review_logs (
                id, card_id, reviewed_at, log, memory_before, memory_after,
                scheduling_audit, sequence
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .text(log.id.uuidString),
                .text(log.cardID.uuidString),
                .double(log.reviewedAt.timeIntervalSince1970),
                .blob(data),
                .blob(memoryData),
                memoryAfterData.map(Binding.blob) ?? .null,
                auditData.map(Binding.blob) ?? .null,
                .int(nextSequence),
            ]
        )
    }

    func insertSynchronizedReviewIfMissing(_ log: ReviewLog) throws {
        guard try fetchReviewLog(id: log.id) == nil else { return }
        guard let card = try fetchCard(id: log.cardID) else { throw DatabaseError.cardNotFound(log.cardID) }
        try insertReviewLog(log, memoryBefore: card.memory)
    }

    func fetchActiveReviewLogs() throws -> [ReviewLog] {
        let rows = try query(
            """
            SELECT review_logs.log, review_logs.sequence
            FROM review_logs
            JOIN cards ON cards.id = review_logs.card_id
            LEFT JOIN review_reverts
                ON review_reverts.review_log_id = review_logs.id
            WHERE review_reverts.id IS NULL
              AND (cards.scheduling_history_origin IS NULL
                   OR review_logs.reviewed_at >= cards.scheduling_history_origin)
            ORDER BY review_logs.reviewed_at ASC, review_logs.sequence ASC;
            """
        )
        return rows.compactMap { row in
            guard let data = payload(row, "log"),
                  let sequence = row["sequence"] as? Int64,
                  let log = try? decoder.decode(ReviewLog.self, from: data)
            else { return nil }
            return log.withSequence(sequence)
        }
    }

    func fetchActiveReviewLogs(cardID: UUID) throws -> [ReviewLog] {
        let rows = try query(
            """
            SELECT review_logs.log, review_logs.sequence
            FROM review_logs
            JOIN cards ON cards.id = review_logs.card_id
            LEFT JOIN review_reverts
                ON review_reverts.review_log_id = review_logs.id
            WHERE review_reverts.id IS NULL AND review_logs.card_id = ?
              AND (cards.scheduling_history_origin IS NULL
                   OR review_logs.reviewed_at >= cards.scheduling_history_origin)
            ORDER BY review_logs.reviewed_at ASC, review_logs.sequence ASC;
            """,
            bindings: [.text(cardID.uuidString)]
        )
        return rows.compactMap { row in
            guard let data = payload(row, "log"),
                  let sequence = row["sequence"] as? Int64,
                  let log = try? decoder.decode(ReviewLog.self, from: data)
            else { return nil }
            return log.withSequence(sequence)
        }
    }

    func fetchReviewLog(id: UUID) throws -> ReviewLog? {
        let rows = try query(
            """
            SELECT log, sequence
            FROM review_logs
            WHERE id = ?
            LIMIT 1;
            """,
            bindings: [.text(id.uuidString)]
        )
        guard let row = rows.first,
              let data = payload(row, "log"),
              let sequence = row["sequence"] as? Int64
        else { return nil }
        return try decode(ReviewLog.self, from: data).withSequence(sequence)
    }

    func fetchSchedulerParameters(profileID: String) throws -> FSRSScheduler.Parameters? {
        let rows = try query(
            """
            SELECT parameters
            FROM scheduler_params
            WHERE profile_id = ?
            LIMIT 1;
            """,
            bindings: [.text(profileID)]
        )
        guard let row = rows.first, let data = payload(row, "parameters") else { return nil }
        guard let parameters = try? decoder.decode(FSRSScheduler.Parameters.self, from: data) else {
            return nil
        }
        if let envelope = try? decoder.decode(SchedulerWeightEnvelope.self, from: data),
           envelope.weights.count == 19 {
            // Make the 19→21 migration durable while preserving the row's
            // optimization timestamp, sample count, and loss metadata.
            try execute(
                "UPDATE scheduler_params SET parameters = ? WHERE profile_id = ?;",
                bindings: [.blob(try encode(parameters)), .text(profileID)]
            )
        }
        return parameters
    }

    func saveSchedulerParameters(
        _ parameters: FSRSScheduler.Parameters,
        profileID: String,
        optimizedAt: Date,
        sampleCount: Int,
        logLoss: Double
    ) throws {
        let data = try encode(parameters)
        try execute(
            """
            INSERT INTO scheduler_params (
                profile_id, parameters, optimized_at, sample_count, log_loss
            )
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(profile_id) DO UPDATE SET
                parameters = excluded.parameters,
                optimized_at = excluded.optimized_at,
                sample_count = excluded.sample_count,
                log_loss = excluded.log_loss;
            """,
            bindings: [
                .text(profileID),
                .blob(data),
                .double(optimizedAt.timeIntervalSince1970),
                .int(Int64(sampleCount)),
                .double(logLoss),
            ]
        )
    }

    // MARK: - Versioned scheduler persistence

    func insertFSRSParameterSet(_ parameterSet: FSRSParameterSet) throws {
        try execute(
            """
            INSERT INTO fsrs_parameter_sets (
                id, weights, model_version, upstream_commit, source_checksum,
                fixture_checksum, scope, source, input_fingerprint,
                training_cutoff, metrics, previous_parameter_set_id, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .text(parameterSet.id.uuidString),
                .blob(try encode(parameterSet.weights)),
                .text(parameterSet.modelVersion),
                .text(parameterSet.upstreamCommit),
                .text(parameterSet.sourceChecksum),
                parameterSet.fixtureChecksum.map(Binding.text) ?? .null,
                .text(parameterSet.scope),
                .text(parameterSet.source.rawValue),
                parameterSet.inputFingerprint.map(Binding.text) ?? .null,
                parameterSet.trainingCutoff.map { .double($0.timeIntervalSince1970) } ?? .null,
                .blob(try encode(parameterSet.metrics)),
                parameterSet.previousParameterSetID.map { .text($0.uuidString) } ?? .null,
                .double(parameterSet.createdAt.timeIntervalSince1970),
            ]
        )
    }

    func fetchFSRSParameterSet(id: UUID) throws -> FSRSParameterSet? {
        let rows = try query(
            "SELECT * FROM fsrs_parameter_sets WHERE id = ? LIMIT 1;",
            bindings: [.text(id.uuidString)]
        )
        return try rows.first.map(decodeFSRSParameterSet)
    }

    func fetchFSRSParameterSets() throws -> [FSRSParameterSet] {
        try query(
            "SELECT * FROM fsrs_parameter_sets ORDER BY created_at DESC, id DESC;"
        ).map(decodeFSRSParameterSet)
    }

    func fetchSchedulerPreset(id: UUID) throws -> SchedulerPreset? {
        let rows = try query(
            "SELECT * FROM scheduler_presets WHERE id = ? LIMIT 1;",
            bindings: [.text(id.uuidString)]
        )
        return rows.first.flatMap(decodeSchedulerPreset)
    }

    func saveSchedulerPreset(_ preset: SchedulerPreset) throws {
        guard preset.desiredRetention > 0, preset.desiredRetention < 1,
              preset.maximumIntervalDays > 0 else {
            throw DatabaseError.executeFailed("Invalid scheduler preset values.")
        }
        try execute(
            """
            INSERT INTO scheduler_presets (
                id, name, desired_retention, maximum_interval_days,
                automatic_optimization_enabled, active_parameter_set_id,
                created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                desired_retention = excluded.desired_retention,
                maximum_interval_days = excluded.maximum_interval_days,
                automatic_optimization_enabled = excluded.automatic_optimization_enabled,
                active_parameter_set_id = excluded.active_parameter_set_id,
                updated_at = excluded.updated_at;
            """,
            bindings: [
                .text(preset.id.uuidString), .text(preset.name),
                .double(preset.desiredRetention), .int(Int64(preset.maximumIntervalDays)),
                .int(preset.automaticOptimizationEnabled ? 1 : 0),
                preset.activeParameterSetID.map { .text($0.uuidString) } ?? .null,
                .double(preset.createdAt.timeIntervalSince1970),
                .double(preset.updatedAt.timeIntervalSince1970),
            ]
        )
    }

    func activateFSRSParameterSet(
        _ parameterSetID: UUID,
        presetID: UUID,
        now: Date
    ) throws {
        guard try fetchFSRSParameterSet(id: parameterSetID) != nil else {
            throw DatabaseError.executeFailed("FSRS parameter set does not exist.")
        }
        try execute(
            """
            UPDATE scheduler_presets
            SET active_parameter_set_id = ?, updated_at = ?
            WHERE id = ?;
            """,
            bindings: [
                .text(parameterSetID.uuidString), .double(now.timeIntervalSince1970),
                .text(presetID.uuidString),
            ]
        )
    }

    func insertFSRSOptimizationRun(_ run: FSRSOptimizationRun) throws {
        try execute(
            """
            INSERT INTO fsrs_optimization_runs (
                id, preset_id, started_at, completed_at, training_cutoff,
                input_fingerprint, eligible_target_count, distinct_card_count,
                failure_count, study_day_count, excluded_counts, fold_count,
                metrics, decision, reason, candidate_parameter_set_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .text(run.id.uuidString), .text(run.presetID.uuidString),
                .double(run.startedAt.timeIntervalSince1970),
                .double(run.completedAt.timeIntervalSince1970),
                .double(run.trainingCutoff.timeIntervalSince1970),
                .text(run.inputFingerprint), .int(Int64(run.eligibleTargetCount)),
                .int(Int64(run.distinctCardCount)), .int(Int64(run.failureCount)),
                .int(Int64(run.studyDayCount)), .blob(try encode(run.excludedCounts)),
                .int(Int64(run.foldCount)), .blob(try encode(run.metrics)),
                .text(run.decision.rawValue), run.reason.map(Binding.text) ?? .null,
                run.candidateParameterSetID.map { .text($0.uuidString) } ?? .null,
            ]
        )
    }

    func persistFSRSOptimizationOutcome(
        parameterSet: FSRSParameterSet,
        run: FSRSOptimizationRun,
        activate: Bool,
        now: Date
    ) throws {
        try inTransaction {
            try insertFSRSParameterSet(parameterSet)
            try insertFSRSOptimizationRun(run)
            if activate {
                try activateFSRSParameterSet(
                    parameterSet.id,
                    presetID: run.presetID,
                    now: now
                )
            }
        }
    }

    func persistFSRSProbationRollback(
        run: FSRSOptimizationRun,
        previousParameterSetID: UUID,
        now: Date
    ) throws {
        try inTransaction {
            try insertFSRSOptimizationRun(run)
            try activateFSRSParameterSet(
                previousParameterSetID,
                presetID: run.presetID,
                now: now
            )
        }
    }

    func fetchFSRSOptimizationRuns(limit: Int? = nil) throws -> [FSRSOptimizationRun] {
        var sql = "SELECT * FROM fsrs_optimization_runs ORDER BY completed_at DESC, id DESC"
        var bindings: [Binding] = []
        if let limit {
            sql += " LIMIT ?"
            bindings.append(.int(Int64(max(limit, 0))))
        }
        sql += ";"
        return try query(sql, bindings: bindings).map(decodeFSRSOptimizationRun)
    }

    func schedulerHealthSnapshot() throws -> SchedulingHealthSnapshot {
        guard let preset = try fetchSchedulerPreset(
            id: SchedulerPersistenceConstants.sharedPresetID
        ) else {
            throw DatabaseError.decodingFailed
        }
        let active = try preset.activeParameterSetID.flatMap { id in
            try fetchFSRSParameterSet(id: id)
        }
        let allSets = try fetchFSRSParameterSets()
        let rollbackIDs = allSets.compactMap { candidate -> UUID? in
            guard candidate.id != active?.id else { return nil }
            return candidate.id
        }
        let quarantined = try query(
            "SELECT 1 AS found FROM quarantined_scheduler_params LIMIT 1;"
        ).first != nil
        return SchedulingHealthSnapshot(
            preset: preset,
            activeParameterSet: active,
            lastOptimizationRun: try fetchFSRSOptimizationRuns(limit: 1).first,
            rollbackParameterSetIDs: rollbackIDs,
            legacyParametersQuarantined: quarantined,
            optimizerParityVerified: SchedulerPersistenceConstants.optimizerParityVerified,
            latestMigration: try fetchLatestSchedulerMigration()
        )
    }

    /// Copies mutable legacy rows into the immutable evidence table without
    /// ever making them active. This also captures legacy rows received after
    /// the schema migration (for example from an older replica).
    func quarantineLegacySchedulerParameters(now: Date) throws {
        guard try tableExists("scheduler_params") else { return }
        try execute(
            """
            INSERT OR IGNORE INTO quarantined_scheduler_params (
                profile_id, parameters, optimized_at, sample_count,
                log_loss, archived_at, reason
            )
            SELECT profile_id, parameters, optimized_at, sample_count,
                   log_loss, ?,
                   'Replaced by versioned upstream FSRS implementation'
            FROM scheduler_params;
            """,
            bindings: [.double(now.timeIntervalSince1970)]
        )
    }

    func fetchLatestSchedulerMigration() throws -> SchedulerMigrationRecord? {
        let rows = try query(
            "SELECT * FROM scheduler_migrations ORDER BY started_at DESC, id DESC LIMIT 1;"
        )
        guard let row = rows.first,
              let idText = row["id"] as? String,
              let id = UUID(uuidString: idText),
              let fromVersion = row["from_model_version"] as? String,
              let toVersion = row["to_model_version"] as? String,
              let statusText = row["status"] as? String,
              let status = SchedulerMigrationStatus(rawValue: statusText),
              let startedAt = row["started_at"] as? Double,
              let replayed = row["replayed_card_count"] as? Int64,
              let reset = row["reset_card_count"] as? Int64 else {
            return nil
        }
        return SchedulerMigrationRecord(
            id: id,
            fromModelVersion: fromVersion,
            toModelVersion: toVersion,
            status: status,
            startedAt: Date(timeIntervalSince1970: startedAt),
            completedAt: (row["completed_at"] as? Double).map(Date.init(timeIntervalSince1970:)),
            replayedCardCount: Int(replayed),
            resetCardCount: Int(reset),
            failureReason: row["failure_reason"] as? String
        )
    }

    func beginSchedulerMigration(
        fromModelVersion: String,
        toModelVersion: String,
        now: Date
    ) throws -> UUID {
        try inTransaction {
            let id = UUID()
            let snapshots = try fetchAllCards().map {
                CardSchedulingSnapshot(
                    cardID: $0.id,
                    memory: $0.memory,
                    memoryModelVersion: $0.memoryModelVersion,
                    memoryParameterSetID: $0.memoryParameterSetID,
                    schedulingHistoryOrigin: $0.schedulingHistoryOrigin
                )
            }
            let preset = try fetchSchedulerPreset(
                id: SchedulerPersistenceConstants.sharedPresetID
            )
            try execute(
                """
                INSERT INTO scheduler_migrations (
                    id, from_model_version, to_model_version, status, started_at,
                    card_snapshot, previous_active_parameter_set_id
                ) VALUES (?, ?, ?, 'running', ?, ?, ?);
                """,
                bindings: [
                    .text(id.uuidString), .text(fromModelVersion), .text(toModelVersion),
                    .double(now.timeIntervalSince1970), .blob(try encode(snapshots)),
                    preset?.activeParameterSetID.map { .text($0.uuidString) } ?? .null,
                ]
            )
            return id
        }
    }

    /// Atomically installs replay results and resets histories that cannot be
    /// reconstructed. The original card states remain in the migration row.
    func completeSchedulerMigration(
        id: UUID,
        replayedCards: [CardSchedulingSnapshot],
        resetCardIDs: [UUID],
        activeParameterSetID: UUID,
        now: Date
    ) throws {
        try inTransaction {
            for card in replayedCards {
                try updateCardSchedulingMemory(
                    card.cardID,
                    memory: card.memory,
                    modelVersion: card.memoryModelVersion
                        ?? SchedulerPersistenceConstants.memoryModelVersion,
                    parameterSetID: card.memoryParameterSetID ?? activeParameterSetID
                )
                try setCardSchedulingHistoryOrigin(
                    card.cardID,
                    origin: card.schedulingHistoryOrigin
                )
            }
            for cardID in resetCardIDs {
                try resetCardSchedulingMemory(
                    cardID,
                    modelVersion: SchedulerPersistenceConstants.memoryModelVersion,
                    parameterSetID: activeParameterSetID,
                    historyOrigin: now
                )
            }
            try activateFSRSParameterSet(
                activeParameterSetID,
                presetID: SchedulerPersistenceConstants.sharedPresetID,
                now: now
            )
            try execute(
                """
                UPDATE scheduler_migrations
                SET status = 'completed', completed_at = ?,
                    replayed_card_count = ?, reset_card_count = ?
                WHERE id = ? AND status = 'running';
                """,
                bindings: [
                    .double(now.timeIntervalSince1970), .int(Int64(replayedCards.count)),
                    .int(Int64(resetCardIDs.count)), .text(id.uuidString),
                ]
            )
        }
    }

    func rollbackSchedulerMigration(id: UUID, now: Date) throws {
        try inTransaction {
            let rows = try query(
                "SELECT card_snapshot, previous_active_parameter_set_id FROM scheduler_migrations WHERE id = ? AND status = 'completed' LIMIT 1;",
                bindings: [.text(id.uuidString)]
            )
            guard let row = rows.first, let data = payload(row, "card_snapshot") else {
                throw DatabaseError.executeFailed("Completed scheduler migration not found.")
            }
            for snapshot in try decode([CardSchedulingSnapshot].self, from: data) {
                if let modelVersion = snapshot.memoryModelVersion {
                    try updateCardSchedulingMemory(
                        snapshot.cardID,
                        memory: snapshot.memory,
                        modelVersion: modelVersion,
                        parameterSetID: snapshot.memoryParameterSetID
                    )
                    try setCardSchedulingHistoryOrigin(
                        snapshot.cardID,
                        origin: snapshot.schedulingHistoryOrigin
                    )
                } else {
                    try updateCardMemory(snapshot.cardID, memory: snapshot.memory)
                    try execute(
                        "UPDATE cards SET memory_model_version = NULL, memory_parameter_set_id = NULL, scheduling_history_origin = ? WHERE id = ?;",
                        bindings: [
                            snapshot.schedulingHistoryOrigin.map {
                                .double($0.timeIntervalSince1970)
                            } ?? .null,
                            .text(snapshot.cardID.uuidString),
                        ]
                    )
                }
            }
            if let previousText = row["previous_active_parameter_set_id"] as? String,
               let previousID = UUID(uuidString: previousText) {
                try activateFSRSParameterSet(
                    previousID,
                    presetID: SchedulerPersistenceConstants.sharedPresetID,
                    now: now
                )
            }
            try execute(
                "UPDATE scheduler_migrations SET status = 'rolledBack', completed_at = ? WHERE id = ?;",
                bindings: [.double(now.timeIntervalSince1970), .text(id.uuidString)]
            )
        }
    }

    func persistReview(
        cardID: UUID,
        memoryBefore: MemoryState,
        memoryAfter: MemoryState,
        log: ReviewLog,
        introducedDeckID: UUID?,
        introductionStudyDay: String?
    ) throws {
        try inTransaction {
            if let audit = log.schedulingAudit {
                try updateCardSchedulingMemory(
                    cardID,
                    memory: memoryAfter,
                    modelVersion: audit.modelVersion,
                    parameterSetID: audit.parameterSetID
                )
            } else {
                try updateCardMemory(cardID, memory: memoryAfter)
            }
            try insertReviewLog(log, memoryBefore: memoryBefore)
            if let introducedDeckID, let introductionStudyDay {
                try execute(
                    """
                    INSERT INTO new_card_introductions (review_log_id, deck_id, study_day)
                    VALUES (?, ?, ?);
                    """,
                    bindings: [
                        .text(log.id.uuidString),
                        .text(introducedDeckID.uuidString),
                        .text(introductionStudyDay),
                    ]
                )
            }
        }
    }

    // MARK: - API study sessions

    func insertStudySession(
        id: UUID,
        clientID: UUID,
        scope: StoredStudyScope,
        now: Date
    ) throws {
        try execute(
            """
            INSERT INTO api_study_sessions (
                id, client_id, scope, state, created_at, last_activity_at
            ) VALUES (?, ?, ?, 'active', ?, ?);
            """,
            bindings: [
                .text(id.uuidString),
                .text(clientID.uuidString),
                .blob(try encode(scope)),
                .double(now.timeIntervalSince1970),
                .double(now.timeIntervalSince1970),
            ]
        )
    }

    func fetchStudySession(id: UUID) throws -> StudySessionRecord? {
        let rows = try query(
            """
            SELECT sessions.id, sessions.client_id, sessions.scope, sessions.state,
                   sessions.revision,
                   sessions.created_at, sessions.last_activity_at,
                   reservations.card_id AS current_card_id
            FROM api_study_sessions AS sessions
            LEFT JOIN api_card_reservations AS reservations
                ON reservations.session_id = sessions.id
            WHERE sessions.id = ?
            LIMIT 1;
            """,
            bindings: [.text(id.uuidString)]
        )
        guard let row = rows.first else { return nil }
        return try decodeStudySession(from: row)
    }

    /// Selects and reserves one card within the same write transaction. The
    /// session's extant reservation wins, which makes retried `next` requests
    /// deterministic until the client grades or skips that card.
    func reserveNextStudyCard(
        sessionID: UUID,
        scope: CardScope,
        asOf now: Date,
        studyDay: String,
        expiresAt: Date
    ) throws -> Card? {
        try inTransaction {
            try execute(
                "DELETE FROM api_card_reservations WHERE expires_at <= ?;",
                bindings: [.double(now.timeIntervalSince1970)]
            )
            let sessionRows = try query(
                "SELECT state FROM api_study_sessions WHERE id = ? LIMIT 1;",
                bindings: [.text(sessionID.uuidString)]
            )
            guard let state = sessionRows.first?["state"] as? String else {
                throw DatabaseError.studySessionNotFound(sessionID)
            }
            guard state == StudySessionState.active.rawValue else {
                throw DatabaseError.studyConflict("The study session has ended.")
            }

            let existing = try query(
                """
                SELECT cards.id, cards.item_id, cards.template_id, cards.skill,
                       cards.memory, cards.is_suspended, cards.deck_id, cards.cloze_group,
                       cards.memory_model_version, cards.memory_parameter_set_id,
                       cards.scheduling_history_origin
                FROM api_card_reservations AS reservations
                JOIN cards ON cards.id = reservations.card_id
                WHERE reservations.session_id = ?
                LIMIT 1;
                """,
                bindings: [.text(sessionID.uuidString)]
            )
            if let row = existing.first {
                try touchStudySession(id: sessionID, now: now)
                return try decodeCard(from: row)
            }

            let reservationBinding = Binding.double(now.timeIntervalSince1970)
            let scopeFilter = scopeClause(scope, column: "cards.deck_id")
            var rows = try query(
                """
                SELECT cards.id, cards.item_id, cards.template_id, cards.skill,
                       cards.memory, cards.is_suspended, cards.deck_id, cards.cloze_group,
                       cards.memory_model_version, cards.memory_parameter_set_id,
                       cards.scheduling_history_origin
                FROM cards
                WHERE cards.is_suspended = 0
                  AND cards.due_at <= ?
                  AND \(scopeFilter.sql)
                  AND cards.phase != 'new'
                  AND NOT EXISTS (
                    SELECT 1
                    FROM api_card_reservations AS reservations
                    WHERE reservations.card_id = cards.id
                      AND reservations.expires_at > ?
                )
                ORDER BY cards.due_at ASC, cards.id ASC
                LIMIT 1;
                """,
                bindings: [.double(now.timeIntervalSince1970)]
                    + scopeFilter.bindings
                    + [reservationBinding]
            )
            if rows.isEmpty {
                let eligible = try eligibleDueCardsCTE(
                    scope: scope,
                    asOf: now,
                    studyDay: studyDay
                )
                rows = try query(
                    eligible.sql + """

                    SELECT eligible_due.id, eligible_due.item_id, eligible_due.template_id,
                           eligible_due.skill, eligible_due.memory, eligible_due.is_suspended,
                           eligible_due.deck_id, eligible_due.cloze_group,
                           eligible_due.memory_model_version,
                           eligible_due.memory_parameter_set_id,
                           eligible_due.scheduling_history_origin
                    FROM eligible_due
                    WHERE eligible_due.phase = 'new'
                      AND NOT EXISTS (
                        SELECT 1
                        FROM api_card_reservations AS reservations
                        WHERE reservations.card_id = eligible_due.id
                          AND reservations.expires_at > ?
                    )
                    ORDER BY eligible_due.due_at ASC, eligible_due.id ASC
                    LIMIT 1;
                    """,
                    bindings: eligible.bindings + [reservationBinding]
                )
            }
            guard let row = rows.first else {
                try touchStudySession(id: sessionID, now: now)
                return nil
            }
            let card = try decodeCard(from: row)
            try execute(
                """
                INSERT INTO api_card_reservations (card_id, session_id, expires_at)
                VALUES (?, ?, ?);
                """,
                bindings: [
                    .text(card.id.uuidString),
                    .text(sessionID.uuidString),
                    .double(expiresAt.timeIntervalSince1970),
                ]
            )
            try touchStudySession(id: sessionID, now: now)
            return card
        }
    }

    /// Reads learned cards directly because daily introduction limits never
    /// exclude them. The more expensive limit-aware CTE is built only if the
    /// queue also needs new material.
    private func fetchStudyQueueCards(
        scope: CardScope,
        asOf now: Date,
        studyDay: String?,
        limit: Int?
    ) throws -> [Card] {
        return try fetchStudyQueueCards(limit: limit) { isNew, groupLimit in
            let statement = try studyQueueStatement(
                scope: scope,
                asOf: now,
                studyDay: studyDay,
                isNew: isNew,
                limit: groupLimit
            )
            return try query(statement.sql, bindings: statement.bindings)
        }
    }

    private func studyQueueStatement(
        scope: CardScope,
        asOf now: Date,
        studyDay: String?,
        isNew: Bool,
        limit: Int?
    ) throws -> (sql: String, bindings: [Binding]) {
        if isNew {
            if case .unassigned = scope {
                let scopeFilter = scopeClause(scope, column: "cards.deck_id")
                var sql = """
                    SELECT cards.id, cards.item_id, cards.template_id, cards.skill,
                           cards.memory, cards.is_suspended, cards.deck_id, cards.cloze_group,
                           cards.memory_model_version, cards.memory_parameter_set_id,
                           cards.scheduling_history_origin
                    FROM cards
                    WHERE cards.is_suspended = 0
                      AND cards.due_at <= ?
                      AND \(scopeFilter.sql)
                      AND cards.phase = 'new'
                    ORDER BY cards.due_at ASC, cards.id ASC
                    """
                sql += studyQueueLimitSQL(limit)
                return (
                    sql,
                    [.double(now.timeIntervalSince1970)] + scopeFilter.bindings
                )
            }
            guard let studyDay else {
                throw DatabaseError.queryFailed("A study day is required for deck queues.")
            }
            let eligible = try eligibleDueCardsCTE(
                scope: scope,
                asOf: now,
                studyDay: studyDay
            )
            var sql = eligible.sql + """

                SELECT id, item_id, template_id, skill, memory, is_suspended,
                       deck_id, cloze_group, memory_model_version,
                       memory_parameter_set_id, scheduling_history_origin
                FROM eligible_due
                WHERE phase = 'new'
                ORDER BY due_at ASC, id ASC
                """
            sql += studyQueueLimitSQL(limit)
            return (sql, eligible.bindings)
        }

        let scopeFilter = scopeClause(scope, column: "cards.deck_id")
        var sql = """
            SELECT cards.id, cards.item_id, cards.template_id, cards.skill,
                   cards.memory, cards.is_suspended, cards.deck_id, cards.cloze_group,
                   cards.memory_model_version, cards.memory_parameter_set_id,
                   cards.scheduling_history_origin
            FROM cards
            WHERE cards.is_suspended = 0
              AND cards.due_at <= ?
              AND \(scopeFilter.sql)
              AND cards.phase != 'new'
            ORDER BY cards.due_at ASC, cards.id ASC
            """
        sql += studyQueueLimitSQL(limit)
        return (
            sql,
            [.double(now.timeIntervalSince1970)] + scopeFilter.bindings
        )
    }

    private func fetchStudyQueueCards(
        limit: Int?,
        fetchGroup: (_ isNew: Bool, _ limit: Int?) throws -> [[String: Any?]]
    ) throws -> [Card] {
        let normalizedLimit = limit.map { max($0, 0) }
        guard normalizedLimit != 0 else { return [] }

        var rows = try fetchGroup(false, normalizedLimit)
        if let normalizedLimit {
            if rows.count < normalizedLimit {
                rows += try fetchGroup(true, normalizedLimit - rows.count)
            }
        } else {
            rows += try fetchGroup(true, nil)
        }
        return try rows.map { try decodeCard(from: $0) }
    }

    private func studyQueueLimitSQL(_ limit: Int?) -> String {
        limit.map { " LIMIT \($0);" } ?? ";"
    }

    func releaseStudyCard(sessionID: UUID, cardID: UUID, now: Date) throws -> Bool {
        try inTransaction {
            let sessions = try query(
                "SELECT state FROM api_study_sessions WHERE id = ? LIMIT 1;",
                bindings: [.text(sessionID.uuidString)]
            )
            guard let state = sessions.first?["state"] as? String else {
                throw DatabaseError.studySessionNotFound(sessionID)
            }
            guard state == StudySessionState.active.rawValue else {
                throw DatabaseError.studyConflict("The study session has ended.")
            }
            let reservation = try query(
                """
                SELECT card_id FROM api_card_reservations
                WHERE session_id = ? AND card_id = ? LIMIT 1;
                """,
                bindings: [.text(sessionID.uuidString), .text(cardID.uuidString)]
            )
            guard !reservation.isEmpty else { return false }
            try execute(
                "DELETE FROM api_card_reservations WHERE session_id = ? AND card_id = ?;",
                bindings: [.text(sessionID.uuidString), .text(cardID.uuidString)]
            )
            try touchStudySession(id: sessionID, now: now)
            return true
        }
    }

    func endStudySession(id: UUID, now: Date) throws {
        try inTransaction {
            guard try fetchStudySession(id: id) != nil else {
                throw DatabaseError.studySessionNotFound(id)
            }
            try execute(
                """
                UPDATE api_study_sessions
                SET state = 'ended', revision = revision + 1, last_activity_at = ?
                WHERE id = ?;
                """,
                bindings: [.double(now.timeIntervalSince1970), .text(id.uuidString)]
            )
            try execute(
                "DELETE FROM api_card_reservations WHERE session_id = ?;",
                bindings: [.text(id.uuidString)]
            )
        }
    }

    func persistReservedReview(
        sessionID: UUID,
        cardID: UUID,
        memoryBefore: MemoryState,
        memoryAfter: MemoryState,
        log: ReviewLog,
        introducedDeckID: UUID?,
        introductionStudyDay: String?,
        now: Date
    ) throws {
        try inTransaction {
            let rows = try query(
                """
                SELECT sessions.state, sessions.revision, reservations.expires_at,
                       cards.is_suspended
                FROM api_study_sessions AS sessions
                LEFT JOIN api_card_reservations AS reservations
                    ON reservations.session_id = sessions.id
                   AND reservations.card_id = ?
                LEFT JOIN cards ON cards.id = reservations.card_id
                WHERE sessions.id = ?
                LIMIT 1;
                """,
                bindings: [.text(cardID.uuidString), .text(sessionID.uuidString)]
            )
            guard let row = rows.first else {
                throw DatabaseError.studySessionNotFound(sessionID)
            }
            guard row["state"] as? String == StudySessionState.active.rawValue else {
                throw DatabaseError.studyConflict("The study session has ended.")
            }
            guard let expiry = row["expires_at"] as? Double,
                  expiry > now.timeIntervalSince1970,
                  row["is_suspended"] as? Int64 == 0
            else {
                throw DatabaseError.studyConflict(
                    "The card is not reserved by this active study session."
                )
            }

            try updateCardMemory(cardID, memory: memoryAfter)
            try insertReviewLog(log, memoryBefore: memoryBefore)
            if let introducedDeckID, let introductionStudyDay {
                try execute(
                    """
                    INSERT INTO new_card_introductions (review_log_id, deck_id, study_day)
                    VALUES (?, ?, ?);
                    """,
                    bindings: [
                        .text(log.id.uuidString),
                        .text(introducedDeckID.uuidString),
                        .text(introductionStudyDay),
                    ]
                )
            }
            try execute(
                "DELETE FROM api_card_reservations WHERE session_id = ? AND card_id = ?;",
                bindings: [.text(sessionID.uuidString), .text(cardID.uuidString)]
            )
            try touchStudySession(id: sessionID, now: now)
        }
    }

    private func touchStudySession(id: UUID, now: Date) throws {
        try execute(
            """
            UPDATE api_study_sessions
            SET revision = revision + 1, last_activity_at = ?
            WHERE id = ?;
            """,
            bindings: [.double(now.timeIntervalSince1970), .text(id.uuidString)]
        )
    }

    private func decodeStudySession(from row: [String: Any?]) throws -> StudySessionRecord {
        guard let idText = row["id"] as? String,
              let id = UUID(uuidString: idText),
              let clientText = row["client_id"] as? String,
              let clientID = UUID(uuidString: clientText),
              let scopeData = payload(row, "scope"),
              let stateText = row["state"] as? String,
              let state = StudySessionState(rawValue: stateText),
              let revision = row["revision"] as? Int64,
              let createdAt = row["created_at"] as? Double,
              let lastActivityAt = row["last_activity_at"] as? Double
        else {
            throw DatabaseError.decodingFailed
        }
        let storedScope = try decode(StoredStudyScope.self, from: scopeData)
        guard let scope = storedScope.scope else { throw DatabaseError.decodingFailed }
        return StudySessionRecord(
            id: id,
            clientID: clientID,
            scope: scope,
            state: state,
            revision: Int(revision),
            currentCardID: (row["current_card_id"] as? String).flatMap(UUID.init(uuidString:)),
            createdAt: Date(timeIntervalSince1970: createdAt),
            lastActivityAt: Date(timeIntervalSince1970: lastActivityAt)
        )
    }

    func revertReview(reviewLogID: UUID, revertedAt: Date) throws {
        try inTransaction {
            let rows = try query(
                """
                SELECT review_logs.card_id, review_logs.memory_before
                FROM review_logs
                LEFT JOIN review_reverts
                    ON review_reverts.review_log_id = review_logs.id
                WHERE review_logs.id = ?
                  AND review_reverts.id IS NULL
                  AND NOT EXISTS (
                      SELECT 1
                      FROM review_logs AS newer
                      LEFT JOIN review_reverts AS newer_revert
                          ON newer_revert.review_log_id = newer.id
                      WHERE newer.card_id = review_logs.card_id
                        AND newer.rowid > review_logs.rowid
                        AND newer_revert.id IS NULL
                  )
                LIMIT 1;
                """,
                bindings: [.text(reviewLogID.uuidString)]
            )
            guard
                let row = rows.first,
                let cardIDText = row["card_id"] as? String,
                let cardID = UUID(uuidString: cardIDText)
            else {
                throw DatabaseError.reviewLogNotFound(reviewLogID)
            }
            guard let memoryData = payload(row, "memory_before") else {
                throw DatabaseError.queryFailed(
                    "This legacy review does not contain restorable memory."
                )
            }
            let memory = try decode(MemoryState.self, from: memoryData)
            guard try fetchCard(id: cardID) != nil else {
                throw DatabaseError.cardNotFound(cardID)
            }

            try execute(
                """
                INSERT INTO review_reverts (id, review_log_id, reverted_at)
                VALUES (?, ?, ?);
                """,
                bindings: [
                    .text(UUID().uuidString),
                    .text(reviewLogID.uuidString),
                    .double(revertedAt.timeIntervalSince1970),
                ]
            )
            try updateCardMemory(cardID, memory: memory)
        }
    }

    func countRawReviewLogs(for cardID: UUID) throws -> Int {
        let rows = try query(
            "SELECT COUNT(*) AS count FROM review_logs WHERE card_id = ?;",
            bindings: [.text(cardID.uuidString)]
        )
        guard let count = rows.first?["count"] as? Int64 else { return 0 }
        return Int(count)
    }

    func countActiveReviewLogs(for cardID: UUID) throws -> Int {
        let rows = try query(
            """
            SELECT COUNT(*) AS count
            FROM review_logs
            JOIN cards ON cards.id = review_logs.card_id
            LEFT JOIN review_reverts
                ON review_reverts.review_log_id = review_logs.id
            WHERE review_logs.card_id = ? AND review_reverts.id IS NULL
              AND (cards.scheduling_history_origin IS NULL
                   OR review_logs.reviewed_at >= cards.scheduling_history_origin);
            """,
            bindings: [.text(cardID.uuidString)]
        )
        guard let count = rows.first?["count"] as? Int64 else { return 0 }
        return Int(count)
    }

    /// Counts every log an automatic fit would draw on, across all cards. This
    /// is the whole cost of deciding whether to fit at all.
    func countActiveReviewLogs() throws -> Int {
        let rows = try query(
            """
            SELECT COUNT(*) AS count
            FROM review_logs
            JOIN cards ON cards.id = review_logs.card_id
            LEFT JOIN review_reverts
                ON review_reverts.review_log_id = review_logs.id
            WHERE review_reverts.id IS NULL
              AND (cards.scheduling_history_origin IS NULL
                   OR review_logs.reviewed_at >= cards.scheduling_history_origin);
            """
        )
        guard let count = rows.first?["count"] as? Int64 else { return 0 }
        return Int(count)
    }

    func fetchItem(id: UUID) throws -> PersistedItem? {
        let rows = try query(
            """
            SELECT id, item_type_id, fields, tags, deck_id, created_at, updated_at
            FROM items
            WHERE id = ?
            LIMIT 1;
            """,
            bindings: [.text(id.uuidString)]
        )
        guard let row = rows.first else { return nil }
        return try decodePersistedItem(from: row)
    }

    /// Fetches only the requested items in bounded queries so callers can
    /// hydrate card batches without either scanning the library or issuing one
    /// SQLite statement per card.
    func fetchItems(ids: Set<UUID>) throws -> [PersistedItem] {
        guard !ids.isEmpty else { return [] }

        let sortedIDs = ids.sorted { $0.uuidString < $1.uuidString }
        let chunkSize = 500
        var persisted: [PersistedItem] = []
        persisted.reserveCapacity(sortedIDs.count)

        var start = 0
        while start < sortedIDs.count {
            let end = min(start + chunkSize, sortedIDs.count)
            let chunk = sortedIDs[start..<end]
            start = end
            let placeholders = Array(repeating: "?", count: chunk.count)
                .joined(separator: ", ")
            let rows = try query(
                """
                SELECT id, item_type_id, fields, tags, deck_id, created_at, updated_at
                FROM items
                WHERE id IN (\(placeholders));
                """,
                bindings: chunk.map { .text($0.uuidString) }
            )
            persisted.append(contentsOf: try rows.map { try decodePersistedItem(from: $0) })
        }

        return persisted
    }

    func countCards(for itemID: UUID) throws -> Int {
        let rows = try query(
            "SELECT COUNT(*) AS count FROM cards WHERE item_id = ?;",
            bindings: [.text(itemID.uuidString)]
        )
        guard let count = rows.first?["count"] as? Int64 else { return 0 }
        return Int(count)
    }

    func fetchItems() throws -> [PersistedItem] {
        let rows = try query(
            """
            SELECT id, item_type_id, fields, tags, deck_id, created_at, updated_at
            FROM items
            ORDER BY created_at DESC;
            """
        )
        return try rows.map { try decodePersistedItem(from: $0) }
    }

    func fetchItemsPage(offset: Int, limit: Int) throws -> [PersistedItem] {
        let rows = try query(
            """
            SELECT id, item_type_id, fields, tags, deck_id, created_at, updated_at
            FROM items
            ORDER BY created_at ASC, id ASC
            LIMIT ? OFFSET ?;
            """,
            bindings: [.int(Int64(limit)), .int(Int64(offset))]
        )
        return try rows.map { try decodePersistedItem(from: $0) }
    }

    func fetchBrowseRows(scope: CardScope) throws -> [SavedItemSummary] {
        guard let handle else {
            throw DatabaseError.queryFailed("Database is closed.")
        }
        let clause = scopeClause(scope, column: "deck_id")
        let sql = """
            SELECT item_id, item_type_id, item_type_name, title, subtitle,
                   card_count, deck_id, created_at, due_at, phase, lapses
            FROM item_browse_rows
            WHERE \(clause.sql)
            ORDER BY created_at ASC, item_id ASC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw DatabaseError.queryFailed(errorMessage(from: handle))
        }
        defer { sqlite3_finalize(statement) }
        try bind(clause.bindings, to: statement)

        func text(_ column: Int32) -> String? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL,
                  let value = sqlite3_column_text(statement, column)
            else { return nil }
            return String(cString: value)
        }

        var rows: [SavedItemSummary] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW,
                  let itemIDText = text(0),
                  let itemID = UUID(uuidString: itemIDText),
                  let itemTypeIDText = text(1),
                  let itemTypeID = UUID(uuidString: itemTypeIDText),
                  let itemTypeName = text(2),
                  let title = text(3),
                  let subtitle = text(4)
            else {
                throw DatabaseError.decodingFailed
            }

            let dueAt: Date?
            let phase: Phase?
            if sqlite3_column_type(statement, 8) == SQLITE_NULL {
                dueAt = nil
                phase = nil
            } else {
                dueAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))
                guard let phaseText = text(9),
                      let decodedPhase = Phase(rawValue: phaseText)
                else {
                    throw DatabaseError.decodingFailed
                }
                phase = decodedPhase
            }
            let deckID = text(6).flatMap(UUID.init(uuidString:))
            rows.append(
                SavedItemSummary(
                    id: itemID,
                    itemTypeID: itemTypeID,
                    itemTypeName: itemTypeName,
                    title: title,
                    subtitle: subtitle,
                    cardCount: Int(sqlite3_column_int64(statement, 5)),
                    deckID: deckID,
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
                    schedule: ItemScheduleSummary(
                        dueAt: dueAt,
                        phase: phase,
                        lapses: Int(sqlite3_column_int64(statement, 10))
                    )
                )
            )
        }
        return rows
    }

    func fetchItems(itemTypeID: UUID) throws -> [PersistedItem] {
        let rows = try query(
            """
            SELECT id, item_type_id, fields, tags, deck_id, created_at, updated_at
            FROM items
            WHERE item_type_id = ?
            ORDER BY created_at DESC;
            """,
            bindings: [.text(itemTypeID.uuidString)]
        )
        return try rows.map { try decodePersistedItem(from: $0) }
    }

    func countItems(itemTypeID: UUID) throws -> Int {
        let rows = try query(
            "SELECT COUNT(*) AS count FROM items WHERE item_type_id = ?;",
            bindings: [.text(itemTypeID.uuidString)]
        )
        guard let count = rows.first?["count"] as? Int64 else { return 0 }
        return Int(count)
    }

    func itemTypeEditingImpact(itemTypeID: UUID) throws -> ItemTypeEditingImpact {
        let rows = try query(
            """
            SELECT COUNT(*) AS item_count,
                   COUNT(DISTINCT deck_id) AS deck_count,
                   SUM(CASE WHEN deck_id IS NULL THEN 1 ELSE 0 END) AS unassigned_count
            FROM items
            WHERE item_type_id = ?;
            """,
            bindings: [.text(itemTypeID.uuidString)]
        )
        guard let row = rows.first else {
            return ItemTypeEditingImpact(itemCount: 0, deckCount: 0, unassignedItemCount: 0)
        }
        return ItemTypeEditingImpact(
            itemCount: Int(row["item_count"] as? Int64 ?? 0),
            deckCount: Int(row["deck_count"] as? Int64 ?? 0),
            unassignedItemCount: Int(row["unassigned_count"] as? Int64 ?? 0)
        )
    }

    func deleteItemType(id: UUID) throws {
        try execute(
            "DELETE FROM item_types WHERE id = ?;",
            bindings: [.text(id.uuidString)]
        )
    }

    func fetchCards(for itemID: UUID) throws -> [Card] {
        let rows = try query(
            """
            SELECT id, item_id, template_id, skill, memory, is_suspended, deck_id, cloze_group,
                   memory_model_version, memory_parameter_set_id, scheduling_history_origin
            FROM cards
            WHERE item_id = ?;
            """,
            bindings: [.text(itemID.uuidString)]
        )
        return try rows.map { try decodeCard(from: $0) }
    }

    func deleteCards(itemID: UUID, templateID: UUID) throws {
        try execute(
            """
            DELETE FROM cards
            WHERE item_id = ? AND template_id = ?;
            """,
            bindings: [
                .text(itemID.uuidString),
                .text(templateID.uuidString),
            ]
        )
    }

    func deleteCard(id: UUID) throws {
        try execute(
            "DELETE FROM cards WHERE id = ?;",
            bindings: [.text(id.uuidString)]
        )
    }

    func deleteItem(id: UUID) throws {
        try execute(
            "DELETE FROM items WHERE id = ?;",
            bindings: [.text(id.uuidString)]
        )
    }

    func fetchMediaAsset(hash: String) throws -> MediaAsset? {
        let rows = try query(
            """
            SELECT hash, kind, byte_size, file_extension, created_at, ref_count
            FROM media_assets
            WHERE hash = ?
            LIMIT 1;
            """,
            bindings: [.text(hash)]
        )
        guard let row = rows.first else { return nil }
        return try decodeMediaAsset(from: row)
    }

    func registerMediaAsset(_ descriptor: MediaAssetDescriptor, createdAt: Date) throws {
        guard isValidMediaHash(descriptor.hash),
              descriptor.byteSize >= 0,
              MediaValidation.allowedExtensions(for: descriptor.kind)
                  .contains(descriptor.fileExtension)
        else {
            throw DatabaseError.invalidMediaAsset("Media metadata is invalid.")
        }
        try execute(
            """
            INSERT INTO media_assets
                (hash, kind, byte_size, file_extension, created_at, ref_count)
            VALUES (?, ?, ?, ?, ?, 0)
            ON CONFLICT(hash) DO NOTHING;
            """,
            bindings: [
                .text(descriptor.hash),
                .text(descriptor.kind.rawValue),
                .int(Int64(descriptor.byteSize)),
                .text(descriptor.fileExtension),
                .double(createdAt.timeIntervalSince1970),
            ]
        )
    }

    func completeStudyResponse(
        id: UUID,
        cardID: UUID,
        media: MediaRef,
        reservationID: UUID,
        durationMilliseconds: Int,
        capturedAt: Date,
        submittedAt: Date
    ) throws -> StudyResponse {
        if let existing = try fetchStudyResponse(id: id) {
            guard existing.cardID == cardID,
                  existing.mediaHash == media.assetHash,
                  existing.durationMilliseconds == durationMilliseconds,
                  abs(existing.capturedAt.timeIntervalSince(capturedAt)) < 1e-6
            else { throw DatabaseError.studyConflict("The response identifier was reused.") }
            return existing
        }
        guard (1 ... 1_800_000).contains(durationMilliseconds) else {
            throw DatabaseError.studyConflict("Audio submissions must be between one millisecond and 30 minutes.")
        }
        guard media.kind == .audio, media.fileExtension.lowercased() == "m4a" else {
            throw DatabaseError.invalidMediaAsset("Audio submissions must use validated M4A audio.")
        }

        try inTransaction {
            guard let card = try fetchCard(id: cardID) else {
                throw DatabaseError.cardNotFound(cardID)
            }
            guard !card.isSuspended else {
                throw DatabaseError.studyConflict("This Audio Submission card is already complete.")
            }
            guard card.isDue(asOf: submittedAt) else {
                throw DatabaseError.studyConflict("This Audio Submission card is not currently due.")
            }
            guard let item = try fetchItem(id: card.itemID)?.item,
                  let itemType = try fetchItemType(id: item.itemTypeID),
                  let template = itemType.templates.first(where: { $0.id == card.templateID }),
                  template.interaction == .audioSubmission
            else {
                throw DatabaseError.studyConflict("This card is not an Audio Submission card.")
            }
            if let existing = try fetchStudyResponse(cardID: cardID) {
                throw DatabaseError.studyConflict(
                    "This card already has response \(existing.id.uuidString)."
                )
            }
            guard let asset = try fetchMediaAsset(hash: media.assetHash),
                  asset.kind == .audio,
                  asset.fileExtension == media.fileExtension.lowercased()
            else { throw DatabaseError.invalidMediaAsset("The reserved audio asset is unavailable.") }
            let reservation = try query(
                "SELECT hash FROM media_reservations WHERE id = ? LIMIT 1;",
                bindings: [.text(reservationID.uuidString)]
            ).first
            guard reservation?["hash"] as? String == media.assetHash else {
                throw DatabaseError.invalidMediaAsset("The audio reservation is unavailable or mismatched.")
            }
            try execute(
                """
                INSERT INTO study_responses (
                    id, card_id, media_hash, kind, duration_ms, captured_at, submitted_at
                ) VALUES (?, ?, ?, 'audio', ?, ?, ?);
                """,
                bindings: [
                    .text(id.uuidString), .text(cardID.uuidString), .text(media.assetHash),
                    .int(Int64(durationMilliseconds)), .double(capturedAt.timeIntervalSince1970),
                    .double(submittedAt.timeIntervalSince1970),
                ]
            )
            try consumeMediaReservations(ids: [reservationID])
            try execute(
                "UPDATE cards SET is_suspended = 1 WHERE id = ?;",
                bindings: [.text(cardID.uuidString)]
            )
        }
        guard let response = try fetchStudyResponse(id: id) else {
            throw DatabaseError.studyResponseNotFound(id)
        }
        return response
    }

    func fetchStudyResponse(id: UUID) throws -> StudyResponse? {
        try fetchStudyResponse(where: "study_responses.id = ?", bindings: [.text(id.uuidString)])
    }

    func fetchStudyResponse(cardID: UUID) throws -> StudyResponse? {
        try fetchStudyResponse(where: "study_responses.card_id = ?", bindings: [.text(cardID.uuidString)])
    }

    func fetchStudyResponses(
        cardID: UUID? = nil,
        itemID: UUID? = nil,
        createdAfter: Date? = nil,
        submittedBefore: Date? = nil,
        submittedBeforeID: UUID? = nil,
        limit: Int = 100
    ) throws -> [StudyResponse] {
        guard (1 ... 1_000).contains(limit) else {
            throw DatabaseError.queryFailed("Study response limit must be between 1 and 1000.")
        }
        var clauses: [String] = []
        var bindings: [Binding] = []
        if let cardID {
            clauses.append("study_responses.card_id = ?")
            bindings.append(.text(cardID.uuidString))
        }
        if let itemID {
            clauses.append("cards.item_id = ?")
            bindings.append(.text(itemID.uuidString))
        }
        if let createdAfter {
            clauses.append("study_responses.submitted_at > ?")
            bindings.append(.double(createdAfter.timeIntervalSince1970))
        }
        if let submittedBefore {
            if let submittedBeforeID {
                clauses.append("(study_responses.submitted_at < ? OR (study_responses.submitted_at = ? AND study_responses.id < ?))")
                bindings.append(.double(submittedBefore.timeIntervalSince1970))
                bindings.append(.double(submittedBefore.timeIntervalSince1970))
                bindings.append(.text(submittedBeforeID.uuidString))
            } else {
                clauses.append("study_responses.submitted_at < ?")
                bindings.append(.double(submittedBefore.timeIntervalSince1970))
            }
        }
        let filter = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        bindings.append(.int(Int64(limit)))
        return try query(
            studyResponseSelectSQL + " \(filter) ORDER BY study_responses.submitted_at DESC, study_responses.id DESC LIMIT ?;",
            bindings: bindings
        ).map(decodeStudyResponse(from:))
    }

    @discardableResult
    func deleteStudyResponse(id: UUID) throws -> Bool {
        try inTransaction {
            guard try fetchStudyResponse(id: id) != nil else { return false }
            try execute(
                "DELETE FROM study_responses WHERE id = ?;",
                bindings: [.text(id.uuidString)]
            )
            return true
        }
    }

    func countStudyResponses(cardIDs: Set<UUID>) throws -> Int {
        guard !cardIDs.isEmpty else { return 0 }
        let ordered = cardIDs.sorted { $0.uuidString < $1.uuidString }
        let placeholders = Array(repeating: "?", count: ordered.count).joined(separator: ",")
        let rows = try query(
            "SELECT COUNT(*) AS count FROM study_responses WHERE card_id IN (\(placeholders));",
            bindings: ordered.map { .text($0.uuidString) }
        )
        return Int(rows.first?["count"] as? Int64 ?? 0)
    }

    func countStudyResponses(itemIDs: Set<UUID>) throws -> Int {
        try countStudyResponses(joinColumn: "cards.item_id", ids: itemIDs)
    }

    func countStudyResponses(templateIDs: Set<UUID>) throws -> Int {
        try countStudyResponses(joinColumn: "cards.template_id", ids: templateIDs)
    }

    private func countStudyResponses(joinColumn: String, ids: Set<UUID>) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        let ordered = ids.sorted { $0.uuidString < $1.uuidString }
        let placeholders = Array(repeating: "?", count: ordered.count).joined(separator: ",")
        let rows = try query(
            """
            SELECT COUNT(*) AS count
            FROM study_responses
            JOIN cards ON cards.id = study_responses.card_id
            WHERE \(joinColumn) IN (\(placeholders));
            """,
            bindings: ordered.map { .text($0.uuidString) }
        )
        return Int(rows.first?["count"] as? Int64 ?? 0)
    }

    func ordinaryMediaReferenceCount(hash: String) throws -> Int {
        let rows = try query(
            """
            SELECT media_assets.ref_count - COUNT(study_responses.id) AS ordinary_count
            FROM media_assets
            LEFT JOIN study_responses ON study_responses.media_hash = media_assets.hash
            WHERE media_assets.hash = ?
            GROUP BY media_assets.hash, media_assets.ref_count;
            """,
            bindings: [.text(hash)]
        )
        return max(0, Int(rows.first?["ordinary_count"] as? Int64 ?? 0))
    }

    func isStudyResponseMediaHash(_ hash: String) throws -> Bool {
        try query(
            "SELECT 1 AS present FROM study_response_media_privacy WHERE media_hash = ? LIMIT 1;",
            bindings: [.text(hash)]
        ).first != nil
    }

    private var studyResponseSelectSQL: String {
        """
        SELECT study_responses.id, study_responses.card_id, cards.item_id,
               study_responses.media_hash, media_assets.file_extension,
               media_assets.byte_size, study_responses.duration_ms,
               study_responses.captured_at, study_responses.submitted_at,
               COALESCE(item_browse_rows.title, 'Audio response') AS source_title
        FROM study_responses
        JOIN cards ON cards.id = study_responses.card_id
        JOIN media_assets ON media_assets.hash = study_responses.media_hash
        LEFT JOIN item_browse_rows ON item_browse_rows.item_id = cards.item_id
        """
    }

    private func fetchStudyResponse(
        where clause: String,
        bindings: [Binding]
    ) throws -> StudyResponse? {
        try query(studyResponseSelectSQL + " WHERE \(clause) LIMIT 1;", bindings: bindings)
            .first.map(decodeStudyResponse(from:))
    }

    private func decodeStudyResponse(from row: [String: Any?]) throws -> StudyResponse {
        guard let idText = row["id"] as? String, let id = UUID(uuidString: idText),
              let cardText = row["card_id"] as? String, let cardID = UUID(uuidString: cardText),
              let itemText = row["item_id"] as? String, let itemID = UUID(uuidString: itemText),
              let hash = row["media_hash"] as? String,
              let fileExtension = row["file_extension"] as? String,
              let byteSize = row["byte_size"] as? Int64,
              let duration = row["duration_ms"] as? Int64,
              let captured = row["captured_at"] as? Double,
              let submitted = row["submitted_at"] as? Double
        else { throw DatabaseError.decodingFailed }
        return StudyResponse(
            id: id,
            cardID: cardID,
            itemID: itemID,
            mediaHash: hash,
            fileExtension: fileExtension,
            byteSize: Int(byteSize),
            durationMilliseconds: Int(duration),
            capturedAt: Date(timeIntervalSince1970: captured),
            submittedAt: Date(timeIntervalSince1970: submitted),
            sourceTitle: row["source_title"] as? String ?? "Audio response"
        )
    }

    /// Registers metadata and a GC reservation in one transaction. The caller
    /// may safely suspend after this returns without exposing a zero-ref asset.
    func reserveMediaAsset(
        _ descriptor: MediaAssetDescriptor,
        reservationID: UUID,
        scopeID: UUID?,
        createdAt: Date,
        expiresAt: Date
    ) throws -> Bool {
        try inTransaction {
            if let reservation = try query(
                "SELECT hash FROM media_reservations WHERE id = ? LIMIT 1;",
                bindings: [.text(reservationID.uuidString)]
            ).first {
                guard reservation["hash"] as? String == descriptor.hash else {
                    throw DatabaseError.invalidMediaAsset(
                        "A media reservation identifier was reused for different bytes."
                    )
                }
                return false
            }
            let existing = try fetchMediaAsset(hash: descriptor.hash)
            if let existing {
                guard existing.kind == descriptor.kind,
                      existing.byteSize == descriptor.byteSize,
                      existing.fileExtension == descriptor.fileExtension
                else {
                    throw DatabaseError.invalidMediaAsset("Conflicting media metadata uses the same hash.")
                }
            } else {
                try registerMediaAsset(descriptor, createdAt: createdAt)
            }
            try execute(
                """
                INSERT INTO media_reservations (id, hash, scope_id, expires_at, created_asset)
                VALUES (?, ?, ?, ?, ?);
                """,
                bindings: [
                    .text(reservationID.uuidString),
                    .text(descriptor.hash),
                    scopeID.map { .text($0.uuidString) } ?? .null,
                    .double(expiresAt.timeIntervalSince1970),
                    .int(existing == nil ? 1 : 0),
                ]
            )
            return existing == nil
        }
    }

    func mediaReservationExpiresAt(id: UUID) throws -> Date? {
        let rows = try query(
            "SELECT expires_at FROM media_reservations WHERE id = ? LIMIT 1;",
            bindings: [.text(id.uuidString)]
        )
        guard let value = rows.first?["expires_at"] as? Double else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    func cancelMediaReservation(id: UUID, deleteNewAsset: Bool) throws -> MediaAsset? {
        try inTransaction {
            let rows = try query(
                "SELECT hash FROM media_reservations WHERE id = ? LIMIT 1;",
                bindings: [.text(id.uuidString)]
            )
            guard let hash = rows.first?["hash"] as? String else { return nil }
            try execute(
                "DELETE FROM media_reservations WHERE id = ?;",
                bindings: [.text(id.uuidString)]
            )
            guard deleteNewAsset,
                  try mediaReservationCount(hash: hash) == 0,
                  let asset = try fetchMediaAsset(hash: hash),
                  asset.refCount == 0
            else { return nil }
            try deleteMediaAssetIfOrphaned(hash: hash)
            return asset
        }
    }

    func rollbackMediaReservations(scopeID: UUID) throws -> [MediaAsset] {
        try inTransaction {
            let rows = try query(
                """
                SELECT hash, MAX(created_asset) AS created_asset
                FROM media_reservations
                WHERE scope_id = ?
                GROUP BY hash;
                """,
                bindings: [.text(scopeID.uuidString)]
            )
            try execute(
                "DELETE FROM media_reservations WHERE scope_id = ?;",
                bindings: [.text(scopeID.uuidString)]
            )
            var removable: [MediaAsset] = []
            for row in rows {
                guard let hash = row["hash"] as? String,
                      row["created_asset"] as? Int64 == 1,
                      try mediaReservationCount(hash: hash) == 0,
                      let asset = try fetchMediaAsset(hash: hash),
                      asset.refCount == 0
                else { continue }
                try deleteMediaAssetIfOrphaned(hash: hash)
                removable.append(asset)
            }
            return removable
        }
    }

    func removeExpiredMediaReservations(asOf now: Date) throws {
        try execute(
            "DELETE FROM media_reservations WHERE expires_at <= ?;",
            bindings: [.double(now.timeIntervalSince1970)]
        )
    }

    func releaseMediaReservations(scopeID: UUID) throws {
        try execute(
            "DELETE FROM media_reservations WHERE scope_id = ?;",
            bindings: [.text(scopeID.uuidString)]
        )
    }

    func fetchOrphanedMediaAssets() throws -> [MediaAsset] {
        let rows = try query(
            """
            SELECT hash, kind, byte_size, file_extension, created_at, ref_count
            FROM media_assets
            WHERE ref_count = 0
              AND NOT EXISTS (
                  SELECT 1 FROM media_reservations
                  WHERE media_reservations.hash = media_assets.hash
              )
            ORDER BY created_at ASC;
            """
        )
        return try rows.map { try decodeMediaAsset(from: $0) }
    }

    func deleteMediaAssetIfOrphaned(hash: String) throws {
        try execute(
            "DELETE FROM media_assets WHERE hash = ? AND ref_count = 0;",
            bindings: [.text(hash)]
        )
    }

    func updateCardSkill(_ cardID: UUID, skill: Skill) throws {
        let skillData = try encode(skill)
        try execute(
            """
            UPDATE cards
            SET skill = ?
            WHERE id = ?;
            """,
            bindings: [
                .blob(skillData),
                .text(cardID.uuidString),
            ]
        )
    }

    // MARK: - Private

    private struct CardIdentity: Hashable {
        let templateID: UUID
        let clozeGroup: Int?
    }

    private func reconcileCards(for itemID: UUID, desired: [Card]) throws {
        var existingByIdentity: [CardIdentity: Card] = [:]
        for card in try fetchCards(for: itemID) {
            let identity = CardIdentity(templateID: card.templateID, clozeGroup: card.clozeGroup)
            if existingByIdentity[identity] == nil {
                existingByIdentity[identity] = card
            } else {
                try deleteCard(id: card.id)
            }
        }

        let desiredIdentities = Set(desired.map {
            CardIdentity(templateID: $0.templateID, clozeGroup: $0.clozeGroup)
        })
        for (identity, card) in existingByIdentity where !desiredIdentities.contains(identity) {
            try deleteCard(id: card.id)
        }

        for card in desired {
            let identity = CardIdentity(templateID: card.templateID, clozeGroup: card.clozeGroup)
            if let existing = existingByIdentity[identity] {
                let skillData = try encode(card.skill)
                try execute(
                    """
                    UPDATE cards
                    SET skill = ?, deck_id = ?
                    WHERE id = ?;
                    """,
                    bindings: [
                        .blob(skillData),
                        card.deckID.map { .text($0.uuidString) } ?? .null,
                        .text(existing.id.uuidString),
                    ]
                )
            } else {
                try insertCards([card])
            }
        }
    }

    private func nextReviewSequence() throws -> Int64 {
        let rows = try query("SELECT COALESCE(MAX(sequence), 0) + 1 AS next FROM review_logs;")
        guard let next = rows.first?["next"] as? Int64 else {
            throw DatabaseError.queryFailed("Could not allocate review append order.")
        }
        return next
    }

    private func syncCards(from previous: ItemType, to updated: ItemType, now: Date) throws {
        let previousTemplateIDs = Set(previous.templates.map(\.id))
        let updatedTemplateIDs = Set(updated.templates.map(\.id))
        let added = updatedTemplateIDs.subtracting(previousTemplateIDs)
        let removed = previousTemplateIDs.subtracting(updatedTemplateIDs)
        let kept = previousTemplateIDs.intersection(updatedTemplateIDs)
        let items = try fetchItems(itemTypeID: updated.id)

        for entry in items {
            let item = entry.item

            for templateID in removed {
                try deleteCards(itemID: item.id, templateID: templateID)
            }

            let existingCards = try fetchCards(for: item.id)

            for template in updated.templates where added.contains(template.id) || kept.contains(template.id) {
                var singleTemplateType = updated
                singleTemplateType.templates = [template]
                let desiredCards = CardGenerator.cards(for: item, type: singleTemplateType, now: now)
                let desiredGroups = Set(desiredCards.map(\.clozeGroup))
                let currentCards = existingCards.filter { $0.templateID == template.id }

                for card in currentCards where !desiredGroups.contains(card.clozeGroup) {
                    try deleteCard(id: card.id)
                }

                let currentGroups = Set(currentCards.map(\.clozeGroup))
                let missingCards = desiredCards.filter { !currentGroups.contains($0.clozeGroup) }
                if !missingCards.isEmpty {
                    try insertCards(missingCards)
                }

                for card in currentCards
                    where desiredGroups.contains(card.clozeGroup) && card.skill != template.skill {
                    try updateCardSkill(card.id, skill: template.skill)
                }
            }
        }
    }

    private func mediaReferenceCounts(in item: Item) -> [String: Int] {
        var counts: [String: Int] = [:]
        for field in item.fields {
            guard case let .media(ref) = field.value,
                  isValidMediaHash(ref.assetHash),
                  MediaValidation.allowedExtensions(for: ref.kind)
                      .contains(ref.fileExtension.lowercased())
            else {
                continue
            }
            counts[ref.assetHash, default: 0] += 1
        }
        return counts
    }

    private func mediaReservationIDs(in item: Item) -> Set<UUID> {
        Set(item.fields.compactMap { field in
            guard case let .media(ref) = field.value else { return nil }
            return ref.reservationID
        })
    }

    private func applyMediaReferenceDeltas(
        from previous: [String: Int],
        to updated: [String: Int],
        descriptors: [String: MediaAssetDescriptor],
        now: Date
    ) throws {
        for hash in Set(previous.keys).union(updated.keys).sorted() {
            let delta = updated[hash, default: 0] - previous[hash, default: 0]
            guard delta != 0 else { continue }

            if delta > 0 {
                if try fetchMediaAsset(hash: hash) == nil {
                    guard let descriptor = descriptors[hash],
                          descriptor.hash == hash,
                          isValidMediaHash(descriptor.hash),
                          MediaValidation.allowedExtensions(for: descriptor.kind)
                              .contains(descriptor.fileExtension)
                    else {
                        throw DatabaseError.invalidMediaAsset("Media metadata is missing or invalid.")
                    }
                    try execute(
                        """
                        INSERT INTO media_assets
                            (hash, kind, byte_size, file_extension, created_at, ref_count)
                        VALUES (?, ?, ?, ?, ?, ?);
                        """,
                        bindings: [
                            .text(hash),
                            .text(descriptor.kind.rawValue),
                            .int(Int64(descriptor.byteSize)),
                            .text(descriptor.fileExtension),
                            .double(now.timeIntervalSince1970),
                            .int(Int64(delta)),
                        ]
                    )
                } else {
                    try execute(
                        "UPDATE media_assets SET ref_count = ref_count + ? WHERE hash = ?;",
                        bindings: [.int(Int64(delta)), .text(hash)]
                    )
                }
            } else {
                guard let current = try fetchMediaAsset(hash: hash),
                      current.refCount >= -delta
                else {
                    throw DatabaseError.invalidMediaAsset("Media reference count would become negative.")
                }
                try execute(
                    "UPDATE media_assets SET ref_count = ref_count + ? WHERE hash = ?;",
                    bindings: [.int(Int64(delta)), .text(hash)]
                )
            }
        }
    }

    private func mediaReservationCount(hash: String) throws -> Int {
        let rows = try query(
            "SELECT COUNT(*) AS count FROM media_reservations WHERE hash = ?;",
            bindings: [.text(hash)]
        )
        return Int(rows.first?["count"] as? Int64 ?? 0)
    }

    private func consumeMediaReservations(ids: Set<UUID>) throws {
        for id in ids {
            try execute(
                "DELETE FROM media_reservations WHERE id = ?;",
                bindings: [.text(id.uuidString)]
            )
        }
    }

    private func validateMediaAdoption(
        in item: Item,
        comparedTo previous: Item?,
        now: Date
    ) throws {
        var existingCounts = previous.map(mediaReferenceCounts(in:)) ?? [:]
        for field in item.fields {
            guard case let .media(ref) = field.value else { continue }
            if existingCounts[ref.assetHash, default: 0] > 0 {
                existingCounts[ref.assetHash, default: 0] -= 1
                continue
            }
            if let reservationID = ref.reservationID {
                let row = try query(
                    "SELECT hash, expires_at FROM media_reservations WHERE id = ? LIMIT 1;",
                    bindings: [.text(reservationID.uuidString)]
                ).first
                guard row?["hash"] as? String == ref.assetHash,
                      let expiresAt = row?["expires_at"] as? Double,
                      expiresAt > now.timeIntervalSince1970
                else {
                    throw DatabaseError.invalidMediaAsset(
                        "The media reservation is missing, expired, or belongs to another asset."
                    )
                }
            } else {
                guard let asset = try fetchMediaAsset(hash: ref.assetHash), asset.refCount > 0 else {
                    throw DatabaseError.invalidMediaAsset(
                        "A live reservation is required to adopt an unreferenced media asset."
                    )
                }
            }
        }
    }

    private func decodeMediaAsset(from row: [String: Any?]) throws -> MediaAsset {
        guard let hash = row["hash"] as? String,
              let kindText = row["kind"] as? String,
              let kind = MediaKind(rawValue: kindText),
              let byteSize = row["byte_size"] as? Int64,
              let fileExtension = row["file_extension"] as? String,
              let createdAt = row["created_at"] as? Double,
              let refCount = row["ref_count"] as? Int64
        else {
            throw DatabaseError.decodingFailed
        }
        return MediaAsset(
            hash: hash,
            kind: kind,
            byteSize: Int(byteSize),
            fileExtension: fileExtension,
            createdAt: Date(timeIntervalSince1970: createdAt),
            refCount: Int(refCount)
        )
    }

    private func isValidMediaHash(_ hash: String) -> Bool {
        hash.count == 64 && hash.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// Renames legacy `note_types` / `notes` tables from early builds to `item_types` / `items`.
    private func migrateNotesToItemsSchemaIfNeeded() throws {
        guard try tableExists("note_types"), !(try tableExists("item_types")) else { return }

        try execute("ALTER TABLE note_types RENAME TO item_types;")
        try execute("ALTER TABLE notes RENAME TO items;")
        try execute("ALTER TABLE items RENAME COLUMN note_type_id TO item_type_id;")
        try execute("ALTER TABLE cards RENAME COLUMN note_id TO item_id;")
        try execute("DROP INDEX IF EXISTS idx_notes_note_type_id;")
        try execute("CREATE INDEX IF NOT EXISTS idx_items_item_type_id ON items(item_type_id);")
        try execute("DROP INDEX IF EXISTS idx_cards_note_id;")
        try execute("CREATE INDEX IF NOT EXISTS idx_cards_item_id ON cards(item_id);")
    }

    private func backfillMediaReferenceCounts() throws {
        try execute("UPDATE media_assets SET ref_count = 0;")
        guard try tableExists("items") else { return }
        for persisted in try fetchItems() {
            var descriptors: [String: MediaAssetDescriptor] = [:]
            for field in persisted.item.fields {
                guard case let .media(ref) = field.value,
                      isValidMediaHash(ref.assetHash),
                      MediaValidation.allowedExtensions(for: ref.kind)
                          .contains(ref.fileExtension.lowercased())
                else {
                    continue
                }
                descriptors[ref.assetHash] = MediaAssetDescriptor(
                    hash: ref.assetHash,
                    kind: ref.kind,
                    byteSize: 0,
                    fileExtension: ref.fileExtension.lowercased()
                )
            }
            try applyMediaReferenceDeltas(
                from: [:],
                to: mediaReferenceCounts(in: persisted.item),
                descriptors: descriptors,
                now: persisted.createdAt
            )
        }
    }

    private func migrateReviewHistorySchemaIfNeeded() throws {
        guard try tableExists("review_logs") else {
            try execute(
                """
                CREATE TABLE review_logs (
                    id TEXT PRIMARY KEY NOT NULL,
                    card_id TEXT NOT NULL,
                    reviewed_at REAL NOT NULL,
                    log BLOB NOT NULL,
                    memory_before BLOB NOT NULL
                );
                """
            )
            try execute("CREATE INDEX idx_review_logs_card_id ON review_logs(card_id);")
            try execute(
                """
                CREATE TABLE review_reverts (
                    id TEXT PRIMARY KEY NOT NULL,
                    review_log_id TEXT NOT NULL UNIQUE REFERENCES review_logs(id),
                    reverted_at REAL NOT NULL
                );
                """
            )
            try execute("CREATE INDEX idx_review_reverts_log_id ON review_reverts(review_log_id);")
            return
        }

        for sql in Schema.migrationV6Statements {
            try execute(sql)
        }
    }

    private func migrateReviewSequenceSchemaIfNeeded() throws {
        guard try tableExists("review_logs") else {
            try execute(
                """
                CREATE TABLE review_logs (
                    id TEXT PRIMARY KEY NOT NULL,
                    card_id TEXT NOT NULL,
                    reviewed_at REAL NOT NULL,
                    log BLOB NOT NULL,
                    memory_before BLOB NOT NULL,
                    sequence INTEGER NOT NULL UNIQUE
                );
                """
            )
            try execute("CREATE INDEX idx_review_logs_card_id ON review_logs(card_id);")
            return
        }
        let columns = try query("PRAGMA table_info(review_logs);")
        if !columns.contains(where: { $0["name"] as? String == "sequence" }) {
            for sql in Schema.migrationV11Statements {
                try execute(sql)
            }
        }
    }

    private func migrateMediaReferenceSchemaIfNeeded() throws {
        guard try tableExists("media_assets") else {
            try execute(
                """
                CREATE TABLE media_assets (
                    hash TEXT PRIMARY KEY NOT NULL,
                    kind TEXT NOT NULL,
                    byte_size INTEGER NOT NULL,
                    file_extension TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    ref_count INTEGER NOT NULL DEFAULT 0 CHECK(ref_count >= 0)
                );
                """
            )
            try migrateLegacyMediaReferences()
            try backfillMediaReferenceCounts()
            return
        }

        let columns = try query("PRAGMA table_info(media_assets);")
        if !columns.contains(where: { $0["name"] as? String == "ref_count" }) {
            for sql in Schema.migrationV7Statements {
                try execute(sql)
            }
        }
        try migrateLegacyMediaReferences()
        try backfillMediaReferenceCounts()
    }

    private func tableExists(_ name: String) throws -> Bool {
        let rows = try query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;",
            bindings: [.text(name)]
        )
        return !rows.isEmpty
    }

    /// Absent tables report no columns, so this answers for both questions.
    /// Uses the table-valued pragma so the table name stays a bound value.
    private func columnExists(_ column: String, in table: String) throws -> Bool {
        let rows = try query(
            "SELECT name FROM pragma_table_info(?) WHERE name = ? LIMIT 1;",
            bindings: [.text(table), .text(column)]
        )
        return !rows.isEmpty
    }

    private func backfillCardDueDates() throws {
        let rows = try query(
            """
            SELECT id, memory
            FROM cards
            WHERE due_at = 0;
            """
        )
        for row in rows {
            guard
                let idText = row["id"] as? String,
                let cardID = UUID(uuidString: idText),
                let memoryData = payload(row, "memory")
            else { continue }

            let memory = try decode(MemoryState.self, from: memoryData)
            try execute(
                "UPDATE cards SET due_at = ? WHERE id = ?;",
                bindings: [
                    .double(memory.due.timeIntervalSince1970),
                    .text(cardID.uuidString),
                ]
            )
        }
    }

    /// Every pre-v14 card carries the column defaults, so each row is rewritten
    /// from its own encoded memory rather than filtered on a sentinel value.
    private func backfillCardScheduleColumns() throws {
        guard try columnExists("memory", in: "cards") else { return }
        let rows = try query("SELECT id, memory FROM cards;")
        for row in rows {
            guard
                let idText = row["id"] as? String,
                let cardID = UUID(uuidString: idText),
                let memoryData = payload(row, "memory")
            else { continue }

            // A card whose memory cannot be decoded is already unschedulable.
            // Leaving it on the column defaults beats failing the whole upgrade.
            guard let memory = try? decode(MemoryState.self, from: memoryData) else { continue }
            try execute(
                "UPDATE cards SET phase = ?, lapses = ? WHERE id = ?;",
                bindings: [
                    .text(memory.phase.rawValue),
                    .int(Int64(memory.lapses)),
                    .text(cardID.uuidString),
                ]
            )
        }
    }

    /// Legacy URL decoding exists only inside the upgrade transaction. Runtime
    /// decoding continues to reject URL-backed MediaRef values.
    private func migrateLegacyMediaReferences() throws {
        guard try tableExists("items") else { return }
        let rows = try query("SELECT id, fields FROM items;")
        for row in rows {
            guard let id = row["id"] as? String,
                  let data = payload(row, "fields"),
                  let object = try? JSONSerialization.jsonObject(with: data)
            else { continue }
            let (converted, changed) = try convertLegacyMediaObject(object)
            guard changed else { continue }
            let encoded = try JSONSerialization.data(
                withJSONObject: converted,
                options: [.sortedKeys]
            )
            try execute(
                "UPDATE items SET fields = ? WHERE id = ?;",
                bindings: [.blob(encoded), .text(id)]
            )
        }
    }

    private func convertLegacyMediaObject(_ object: Any) throws -> (Any, Bool) {
        if var dictionary = object as? [String: Any] {
            if let urlText = dictionary["url"] as? String,
               let kindText = dictionary["kind"] as? String,
               let kind = MediaKind(rawValue: kindText)
            {
                return (try convertedLegacyMedia(dictionary, urlText: urlText, kind: kind), true)
            }
            var changed = false
            for (key, value) in dictionary {
                let (converted, childChanged) = try convertLegacyMediaObject(value)
                dictionary[key] = converted
                changed = changed || childChanged
            }
            return (dictionary, changed)
        }
        if let array = object as? [Any] {
            var changed = false
            let converted = try array.map { value -> Any in
                let (newValue, childChanged) = try convertLegacyMediaObject(value)
                changed = changed || childChanged
                return newValue
            }
            return (converted, changed)
        }
        return (object, false)
    }

    private func convertedLegacyMedia(
        _ legacy: [String: Any],
        urlText: String,
        kind: MediaKind
    ) throws -> [String: Any] {
        let idText = (legacy["id"] as? String).flatMap(UUID.init(uuidString:))?.uuidString
            ?? UUID().uuidString
        var replacement: [String: Any] = [
            "id": idText,
            "kind": kind.rawValue,
        ]
        if let duration = legacy["durationMs"] as? NSNumber {
            replacement["durationMs"] = duration
        }

        if let converted = try securelyConvertLegacyFile(urlText: urlText, kind: kind) {
            replacement["assetHash"] = converted.hash
            replacement["fileExtension"] = converted.fileExtension
            if let altText = legacy["altText"] as? String {
                replacement["altText"] = altText
            }
        } else {
            let missingSeed = Data("missing-legacy-media:\(idText)".utf8)
            replacement["assetHash"] = Self.sha256Hex(missingSeed)
            replacement["fileExtension"] = MediaValidation.defaultExtension(for: kind)
            replacement["altText"] =
                "Media unavailable after a secure upgrade. Re-import this file to restore it."
        }
        return replacement
    }

    private func securelyConvertLegacyFile(
        urlText: String,
        kind: MediaKind
    ) throws -> MediaAssetDescriptor? {
        guard let sourceURL = URL(string: urlText), sourceURL.isFileURL else { return nil }
        let trustedDirectory = databaseURL.deletingLastPathComponent()
            .appendingPathComponent("media", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let source = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        guard source.deletingLastPathComponent() == trustedDirectory else {
            return nil
        }
        let data = try readLegacyMedia(
            named: source.lastPathComponent,
            in: trustedDirectory,
            kind: kind,
            maximumBytes: MediaValidation.maxBytes(for: kind)
        )
        let claimedExtension = source.pathExtension.lowercased().isEmpty
            ? MediaValidation.defaultExtension(for: kind)
            : source.pathExtension.lowercased()
        guard let fileExtension = try? MediaValidation.validatedExtension(
            data: data,
            kind: kind,
            fileExtension: claimedExtension
        ) else {
            return nil
        }

        let hash = Self.sha256Hex(data)
        let destination = trustedDirectory.appendingPathComponent("\(hash).\(fileExtension)")
        guard destination.deletingLastPathComponent() == trustedDirectory else { return nil }
        if !FileManager.default.fileExists(atPath: destination.path) {
            try data.write(to: destination, options: .atomic)
        }
        let descriptor = MediaAssetDescriptor(
            hash: hash,
            kind: kind,
            byteSize: data.count,
            fileExtension: fileExtension
        )
        try registerMediaAsset(descriptor, createdAt: .now)
        return descriptor
    }

    private func readLegacyMedia(
        named filename: String,
        in directory: URL,
        kind: MediaKind,
        maximumBytes: Int
    ) throws -> Data {
        let directoryFD = directory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard directoryFD >= 0 else { throw MediaError.readFailed }
        defer { Darwin.close(directoryFD) }
        let fileFD = filename.withCString {
            Darwin.openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fileFD >= 0 else { throw MediaError.readFailed }
        var status = stat()
        guard fstat(fileFD, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0,
              status.st_size <= maximumBytes
        else {
            Darwin.close(fileFD)
            throw MediaError.invalidPath
        }
        let handle = FileHandle(fileDescriptor: fileFD, closeOnDealloc: true)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maximumBytes {
            let remaining = maximumBytes - data.count + 1
            guard let chunk = try handle.read(upToCount: min(64 * 1024, remaining)),
                  !chunk.isEmpty
            else { return data }
            data.append(chunk)
        }
        throw MediaError.fileTooLarge(kind, maxBytes: maximumBytes)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isValidSHA256Digest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { character in
            ("0"..."9").contains(String(character))
                || ("a"..."f").contains(String(character))
        }
    }

    private func decodeCard(from row: [String: Any?]) throws -> Card {
        guard
            let idText = row["id"] as? String,
            let id = UUID(uuidString: idText),
            let itemIDText = row["item_id"] as? String,
            let itemID = UUID(uuidString: itemIDText),
            let templateIDText = row["template_id"] as? String,
            let templateID = UUID(uuidString: templateIDText),
            let skillData = payload(row, "skill"),
            let memoryData = payload(row, "memory"),
            let suspendedValue = row["is_suspended"] as? Int64
        else {
            throw DatabaseError.decodingFailed
        }

        let skill = try decode(Skill.self, from: skillData)
        let memory = try decode(MemoryState.self, from: memoryData)
        let deckID = (row["deck_id"] as? String).flatMap(UUID.init(uuidString:))
        let clozeGroup = (row["cloze_group"] as? Int64).map(Int.init)
        let memoryModelVersion = row["memory_model_version"] as? String
        let memoryParameterSetID = (row["memory_parameter_set_id"] as? String)
            .flatMap(UUID.init(uuidString:))
        let schedulingHistoryOrigin = (row["scheduling_history_origin"] as? Double)
            .map(Date.init(timeIntervalSince1970:))

        return Card(
            id: id,
            itemID: itemID,
            templateID: templateID,
            skill: skill,
            memory: memory,
            memoryModelVersion: memoryModelVersion,
            memoryParameterSetID: memoryParameterSetID,
            schedulingHistoryOrigin: schedulingHistoryOrigin,
            isSuspended: suspendedValue != 0,
            deckID: deckID,
            clozeGroup: clozeGroup
        )
    }

    private func decodeSchedulerPreset(from row: [String: Any?]) -> SchedulerPreset? {
        guard let idText = row["id"] as? String,
              let id = UUID(uuidString: idText),
              let name = row["name"] as? String,
              let desiredRetention = row["desired_retention"] as? Double,
              let maximumIntervalDays = row["maximum_interval_days"] as? Int64,
              let automatic = row["automatic_optimization_enabled"] as? Int64,
              let createdAt = row["created_at"] as? Double,
              let updatedAt = row["updated_at"] as? Double else { return nil }
        return SchedulerPreset(
            id: id,
            name: name,
            desiredRetention: desiredRetention,
            maximumIntervalDays: Int(maximumIntervalDays),
            automaticOptimizationEnabled: automatic != 0,
            activeParameterSetID: (row["active_parameter_set_id"] as? String)
                .flatMap(UUID.init(uuidString:)),
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    private func decodeFSRSParameterSet(from row: [String: Any?]) throws -> FSRSParameterSet {
        guard let idText = row["id"] as? String,
              let id = UUID(uuidString: idText),
              let weightsData = payload(row, "weights"),
              let modelVersion = row["model_version"] as? String,
              let upstreamCommit = row["upstream_commit"] as? String,
              let sourceChecksum = row["source_checksum"] as? String,
              let scope = row["scope"] as? String,
              let sourceText = row["source"] as? String,
              let source = FSRSParameterSource(rawValue: sourceText),
              let metricsData = payload(row, "metrics"),
              let createdAt = row["created_at"] as? Double else {
            throw DatabaseError.decodingFailed
        }
        return FSRSParameterSet(
            id: id,
            weights: try decode([Double].self, from: weightsData),
            modelVersion: modelVersion,
            upstreamCommit: upstreamCommit,
            sourceChecksum: sourceChecksum,
            fixtureChecksum: row["fixture_checksum"] as? String,
            scope: scope,
            source: source,
            inputFingerprint: row["input_fingerprint"] as? String,
            trainingCutoff: (row["training_cutoff"] as? Double)
                .map(Date.init(timeIntervalSince1970:)),
            metrics: try decode([String: Double].self, from: metricsData),
            previousParameterSetID: (row["previous_parameter_set_id"] as? String)
                .flatMap(UUID.init(uuidString:)),
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }

    private func decodeFSRSOptimizationRun(
        from row: [String: Any?]
    ) throws -> FSRSOptimizationRun {
        guard let idText = row["id"] as? String, let id = UUID(uuidString: idText),
              let presetText = row["preset_id"] as? String,
              let presetID = UUID(uuidString: presetText),
              let startedAt = row["started_at"] as? Double,
              let completedAt = row["completed_at"] as? Double,
              let trainingCutoff = row["training_cutoff"] as? Double,
              let fingerprint = row["input_fingerprint"] as? String,
              let eligible = row["eligible_target_count"] as? Int64,
              let cards = row["distinct_card_count"] as? Int64,
              let failures = row["failure_count"] as? Int64,
              let days = row["study_day_count"] as? Int64,
              let excludedData = payload(row, "excluded_counts"),
              let folds = row["fold_count"] as? Int64,
              let metricsData = payload(row, "metrics"),
              let decisionText = row["decision"] as? String,
              let decision = FSRSOptimizationDecision(rawValue: decisionText) else {
            throw DatabaseError.decodingFailed
        }
        return FSRSOptimizationRun(
            id: id,
            presetID: presetID,
            startedAt: Date(timeIntervalSince1970: startedAt),
            completedAt: Date(timeIntervalSince1970: completedAt),
            trainingCutoff: Date(timeIntervalSince1970: trainingCutoff),
            inputFingerprint: fingerprint,
            eligibleTargetCount: Int(eligible),
            distinctCardCount: Int(cards),
            failureCount: Int(failures),
            studyDayCount: Int(days),
            excludedCounts: try decode([String: Int].self, from: excludedData),
            foldCount: Int(folds),
            metrics: try decode([String: Double].self, from: metricsData),
            decision: decision,
            reason: row["reason"] as? String,
            candidateParameterSetID: (row["candidate_parameter_set_id"] as? String)
                .flatMap(UUID.init(uuidString:))
        )
    }

    private func decodePersistedItem(from row: [String: Any?]) throws -> PersistedItem {
        guard
            let idText = row["id"] as? String,
            let id = UUID(uuidString: idText),
            let itemTypeText = row["item_type_id"] as? String,
            let itemTypeID = UUID(uuidString: itemTypeText),
            let fieldsData = payload(row, "fields"),
            let tagsData = payload(row, "tags"),
            let createdAt = row["created_at"] as? Double,
            let updatedAt = row["updated_at"] as? Double
        else {
            throw DatabaseError.decodingFailed
        }

        let fields = try decode([FieldValue].self, from: fieldsData)
        let tags = try decode([String].self, from: tagsData)
        let deckID = (row["deck_id"] as? String).flatMap(UUID.init(uuidString:))

        return PersistedItem(
            item: Item(
                id: id,
                itemTypeID: itemTypeID,
                fields: fields,
                tags: tags,
                deckID: deckID
            ),
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    private func schemaVersion() throws -> Int {
        do {
            guard try tableExists("schema_version") else { return 0 }
            let rows = try query("SELECT version FROM schema_version LIMIT 1;")
            guard let version = rows.first?["version"] as? Int64 else {
                throw DatabaseError.schemaVersionReadFailed
            }
            return Int(version)
        } catch {
            throw DatabaseError.schemaVersionReadFailed
        }
    }

    func updateItemDeckSync(itemID: UUID, deckID: UUID?) throws {
        try inTransaction {
            try updateItemDeck(itemID: itemID, deckID: deckID)
            try updateCardsDeck(itemID: itemID, deckID: deckID)
        }
    }

    func deleteAllUnassignedItems(deletedAt: Date) throws -> Int {
        try inTransaction {
            let items = try fetchUnassignedItems()
            var deleted = 0
            for entry in items {
                if try deleteItemWithMediaWithoutTransaction(id: entry.item.id, deletedAt: deletedAt) {
                    deleted += 1
                }
            }
            return deleted
        }
    }

    func deleteDeckRecursively(descendantIDs: Set<UUID>) throws {
        try inTransaction {
            for deckID in descendantIDs {
                let items = try fetchItems(deckID: deckID)
                for entry in items {
                    _ = try deleteItemWithMediaWithoutTransaction(id: entry.item.id, deletedAt: .now)
                }
            }
            for deckID in try deckDeletionOrder(ids: descendantIDs) {
                try deleteDeck(id: deckID)
            }
            try reconcileOrphanedIncludedItemTypes()
        }
    }

    func applyDeckDeletion(
        rootID: UUID,
        descendantIDs: Set<UUID>,
        parentID: UUID?,
        policy: DeckDeletionPolicy,
        deletedAt: Date
    ) throws {
        try inTransaction {
            guard try fetchDeck(id: rootID) != nil else {
                throw DatabaseError.deckNotFound(rootID)
            }
            switch policy {
            case .rejectIfNonempty:
                guard descendantIDs == [rootID], try fetchItems(deckID: rootID).isEmpty else {
                    throw DatabaseError.resourceInUse(
                        "The deck has child decks or assigned items."
                    )
                }

            case .unassignItems, .moveItemsToParent:
                let destination = policy == .moveItemsToParent ? parentID : nil
                for deckID in descendantIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                    for entry in try fetchItems(deckID: deckID) {
                        try updateItemDeck(itemID: entry.item.id, deckID: destination)
                        try updateCardsDeck(itemID: entry.item.id, deckID: destination)
                        try execute(
                            "UPDATE item_browse_rows SET deck_id = ? WHERE item_id = ?;",
                            bindings: [
                                destination.map { .text($0.uuidString) } ?? .null,
                                .text(entry.item.id.uuidString),
                            ]
                        )
                    }
                }

            case .deleteSubtreeAndItems:
                for deckID in descendantIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                    for entry in try fetchItems(deckID: deckID) {
                        _ = try deleteItemWithMediaWithoutTransaction(
                            id: entry.item.id,
                            deletedAt: deletedAt
                        )
                    }
                }
            }

            for deckID in try deckDeletionOrder(ids: descendantIDs) {
                try deleteDeck(id: deckID)
            }
            try reconcileOrphanedIncludedItemTypes()
        }
    }

    func resetDeckProgress(deckIDs: Set<UUID>, now: Date) throws -> Int {
        guard !deckIDs.isEmpty else { return 0 }

        let orderedDeckIDs = deckIDs.sorted { $0.uuidString < $1.uuidString }
        let placeholders = Array(repeating: "?", count: orderedDeckIDs.count)
            .joined(separator: ", ")
        let deckBindings = orderedDeckIDs.map { Binding.text($0.uuidString) }
        let cardLogIDs = """
            SELECT review_logs.id
            FROM review_logs
            JOIN cards ON cards.id = review_logs.card_id
            WHERE cards.deck_id IN (\(placeholders))
            """

        return try inTransaction {
            let rows = try query(
                """
                SELECT cards.id
                FROM cards
                JOIN items ON items.id = cards.item_id
                WHERE cards.deck_id IN (\(placeholders))
                ORDER BY items.created_at ASC, items.rowid ASC, cards.rowid ASC;
                """,
                bindings: deckBindings
            )
            let orderedCardIDs = try rows.map { row -> UUID in
                guard let idText = row["id"] as? String,
                      let id = UUID(uuidString: idText)
                else { throw DatabaseError.decodingFailed }
                return id
            }

            // These child records reference review_logs without cascade rules,
            // so remove them before their parent history rows.
            try execute(
                "DELETE FROM new_card_introductions WHERE review_log_id IN (\(cardLogIDs));",
                bindings: deckBindings
            )
            try execute(
                "DELETE FROM review_reverts WHERE review_log_id IN (\(cardLogIDs));",
                bindings: deckBindings
            )
            try execute(
                "DELETE FROM review_logs WHERE id IN (\(cardLogIDs));",
                bindings: deckBindings
            )

            // Cards created in one import often share a timestamp. Give each a
            // tiny, already-due offset in insertion order so a reset restores
            // authored order instead of falling back to random UUID order.
            let updateStatement = try prepareStatement(
                """
                UPDATE cards
                SET memory = ?, due_at = ?, phase = ?, lapses = ?
                WHERE id = ?;
                """
            )
            defer { sqlite3_finalize(updateStatement) }
            for (index, cardID) in orderedCardIDs.enumerated() {
                let millisecondsBeforeReset = orderedCardIDs.count - index
                let due = now.addingTimeInterval(-Double(millisecondsBeforeReset) / 1_000)
                let memory = MemoryState.new(due: due)
                try executePrepared(
                    updateStatement,
                    bindings: [
                        .blob(try encode(memory)),
                        .double(memory.due.timeIntervalSince1970),
                        .text(memory.phase.rawValue),
                        .int(Int64(memory.lapses)),
                        .text(cardID.uuidString),
                    ]
                )
            }

            return orderedCardIDs.count
        }
    }

    private func reconcileOrphanedIncludedItemTypes() throws {
        let rows = try query(
            """
            SELECT item_types.id AS id, COUNT(items.id) AS item_count
            FROM item_types
            LEFT JOIN items ON items.item_type_id = item_types.id
            WHERE NOT EXISTS (
                SELECT 1 FROM library_item_types
                WHERE library_item_types.item_type_id = item_types.id
            )
            AND NOT EXISTS (
                SELECT 1 FROM deck_included_item_types
                WHERE deck_included_item_types.item_type_id = item_types.id
            )
            GROUP BY item_types.id;
            """
        )
        for row in rows {
            guard let idText = row["id"] as? String,
                  let id = UUID(uuidString: idText),
                  let itemCount = row["item_count"] as? Int64
            else { continue }
            if itemCount > 0 {
                try markItemTypeAsLibrary(id)
            } else {
                try deleteItemType(id: id)
            }
        }
    }

    private func deckDeletionOrder(ids: Set<UUID>) throws -> [UUID] {
        var depth: [UUID: Int] = [:]
        for id in ids {
            depth[id] = try deckDepth(id: id, within: ids)
        }
        return ids.sorted { depth[$0, default: 0] > depth[$1, default: 0] }
    }

    private func deckDepth(id: UUID, within ids: Set<UUID>) throws -> Int {
        guard let deck = try fetchDeck(id: id) else { return 0 }
        guard let parentID = deck.parentID, ids.contains(parentID) else { return 0 }
        return 1 + (try deckDepth(id: parentID, within: ids))
    }

    private func backfillBrowseProjection() throws {
        try execute("DELETE FROM item_browse_rows;")
        let itemTypes = try fetchItemTypesWithCorruption().itemTypes
        let itemTypesByID = Dictionary(uniqueKeysWithValues: itemTypes.map { ($0.id, $0) })
        // Libraries old enough to predate the card scheduling columns still get
        // browsable rows. The aggregates stay at their defaults until the cards
        // themselves are rewritten, which beats failing the whole upgrade.
        let includeCardAggregates = try cardsSupportScheduleAggregates()
        for entry in try fetchItems() {
            guard let itemType = itemTypesByID[entry.item.itemTypeID] else { continue }
            try upsertBrowseProjection(
                entry.item,
                itemType: itemType,
                createdAt: entry.createdAt,
                includeCardAggregates: includeCardAggregates
            )
        }
    }

    private func cardsSupportScheduleAggregates() throws -> Bool {
        guard try tableExists("cards") else { return false }
        for column in ["item_id", "due_at", "phase", "lapses", "is_suspended"] {
            guard try columnExists(column, in: "cards") else { return false }
        }
        return true
    }

    private func refreshBrowseProjection(itemTypeID: UUID) throws {
        guard let itemType = try fetchValidatedItemType(id: itemTypeID) else {
            try execute(
                "DELETE FROM item_browse_rows WHERE item_type_id = ?;",
                bindings: [.text(itemTypeID.uuidString)]
            )
            return
        }
        for entry in try fetchItems(itemTypeID: itemTypeID) {
            try upsertBrowseProjection(
                entry.item,
                itemType: itemType,
                createdAt: entry.createdAt
            )
        }
    }

    private func upsertBrowseProjection(
        _ item: Item,
        itemType: ItemType,
        createdAt: Date,
        includeCardAggregates: Bool = true
    ) throws {
        guard includeCardAggregates else {
            try upsertBrowseProjectionWithoutCards(
                item,
                itemType: itemType,
                createdAt: createdAt
            )
            return
        }
        try execute(
            """
            INSERT INTO item_browse_rows (
                item_id, item_type_id, item_type_name, title, subtitle,
                deck_id, created_at, card_count, due_at, phase, lapses
            )
            SELECT ?, ?, ?, ?, ?, ?, ?,
                   COUNT(cards.id),
                   (
                       SELECT due_at FROM cards AS due_card
                       WHERE due_card.item_id = ?
                         AND due_card.is_suspended = 0
                       ORDER BY due_at ASC, id ASC LIMIT 1
                   ),
                   (
                       SELECT phase FROM cards AS phase_card
                       WHERE phase_card.item_id = ?
                         AND phase_card.is_suspended = 0
                       ORDER BY due_at ASC, id ASC LIMIT 1
                   ),
                   COALESCE(MAX(CASE WHEN cards.is_suspended = 0 THEN cards.lapses END), 0)
            FROM cards
            WHERE cards.item_id = ?
            ON CONFLICT(item_id) DO UPDATE SET
                item_type_id = excluded.item_type_id,
                item_type_name = excluded.item_type_name,
                title = excluded.title,
                subtitle = excluded.subtitle,
                deck_id = excluded.deck_id,
                created_at = excluded.created_at,
                card_count = excluded.card_count,
                due_at = excluded.due_at,
                phase = excluded.phase,
                lapses = excluded.lapses;
            """,
            bindings: [
                .text(item.id.uuidString),
                .text(itemType.id.uuidString),
                .text(itemType.name),
                .text(ItemDisplay.title(for: item, in: itemType)),
                .text(ItemDisplay.subtitle(for: item, in: itemType)),
                item.deckID.map { .text($0.uuidString) } ?? .null,
                .double(createdAt.timeIntervalSince1970),
                .text(item.id.uuidString),
                .text(item.id.uuidString),
                .text(item.id.uuidString),
            ]
        )
    }

    /// Writes the display half of a projected row for libraries whose `cards`
    /// table has not reached the scheduling columns yet.
    private func upsertBrowseProjectionWithoutCards(
        _ item: Item,
        itemType: ItemType,
        createdAt: Date
    ) throws {
        try execute(
            """
            INSERT INTO item_browse_rows (
                item_id, item_type_id, item_type_name, title, subtitle,
                deck_id, created_at, card_count, due_at, phase, lapses
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, 0, NULL, NULL, 0)
            ON CONFLICT(item_id) DO UPDATE SET
                item_type_id = excluded.item_type_id,
                item_type_name = excluded.item_type_name,
                title = excluded.title,
                subtitle = excluded.subtitle,
                deck_id = excluded.deck_id,
                created_at = excluded.created_at;
            """,
            bindings: [
                .text(item.id.uuidString),
                .text(itemType.id.uuidString),
                .text(itemType.name),
                .text(ItemDisplay.title(for: item, in: itemType)),
                .text(ItemDisplay.subtitle(for: item, in: itemType)),
                item.deckID.map { .text($0.uuidString) } ?? .null,
                .double(createdAt.timeIntervalSince1970),
            ]
        )
    }

    func fetchSynchronizedReviewRecord(id: UUID) throws -> SynchronizedReviewRecord? {
        let rows = try query(
            "SELECT log, memory_before, sequence FROM review_logs WHERE id = ? LIMIT 1;",
            bindings: [.text(id.uuidString)]
        )
        guard let row = rows.first,
              let logData = payload(row, "log"),
              let memoryData = payload(row, "memory_before"),
              let sequence = row["sequence"] as? Int64 else { return nil }
        return SynchronizedReviewRecord(
            log: try decode(ReviewLog.self, from: logData).withSequence(sequence),
            memoryBefore: try decode(MemoryState.self, from: memoryData)
        )
    }

    func fetchReviewRevertRecord(id: UUID) throws -> ReviewRevertRecord? {
        let rows = try query(
            "SELECT review_log_id, reverted_at FROM review_reverts WHERE id = ? LIMIT 1;",
            bindings: [.text(id.uuidString)]
        )
        guard let row = rows.first,
              let logText = row["review_log_id"] as? String,
              let logID = UUID(uuidString: logText),
              let revertedAt = row["reverted_at"] as? Double else { return nil }
        return ReviewRevertRecord(
            id: id,
            reviewLogID: logID,
            revertedAt: Date(timeIntervalSince1970: revertedAt)
        )
    }

    func fetchItemTypeMembershipRecord(id: String) throws -> ItemTypeMembershipRecord? {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "library" where parts.count == 2:
            guard let typeID = UUID(uuidString: parts[1]) else { return nil }
            let found = try query(
                "SELECT 1 AS found FROM library_item_types WHERE item_type_id = ? LIMIT 1;",
                bindings: [.text(typeID.uuidString)]
            )
            return found.isEmpty ? nil : .library(itemTypeID: typeID)
        case "included" where parts.count == 3:
            guard let rootID = UUID(uuidString: parts[1]), let typeID = UUID(uuidString: parts[2]) else { return nil }
            let rows = try query(
                "SELECT ordinal FROM deck_included_item_types WHERE root_deck_id = ? AND item_type_id = ? LIMIT 1;",
                bindings: [.text(rootID.uuidString), .text(typeID.uuidString)]
            )
            guard let ordinal = rows.first?["ordinal"] as? Int64 else { return nil }
            return .included(rootDeckID: rootID, itemTypeID: typeID, ordinal: Int(ordinal))
        case "policy" where parts.count == 3:
            guard let deckID = UUID(uuidString: parts[1]), let typeID = UUID(uuidString: parts[2]) else { return nil }
            let rows = try query(
                "SELECT ordinal, is_default FROM deck_item_type_policy_entries WHERE deck_id = ? AND item_type_id = ? LIMIT 1;",
                bindings: [.text(deckID.uuidString), .text(typeID.uuidString)]
            )
            guard let row = rows.first,
                  let ordinal = row["ordinal"] as? Int64,
                  let isDefault = row["is_default"] as? Int64 else { return nil }
            return .policy(deckID: deckID, itemTypeID: typeID, ordinal: Int(ordinal), isDefault: isDefault != 0)
        default:
            return nil
        }
    }

    func fetchSchedulingSettingsRecord(id: String) throws -> SchedulingSettingsRecord? {
        if id == "rollover" {
            guard let value = try metadataValue(forKey: ItemStore.studyDayRolloverMetadataKeyForSync),
                  let minutes = Int(value) else { return nil }
            return .studyDayRollover(minutes: minutes)
        }
        guard id.hasPrefix("profile:") else { return nil }
        let profileID = String(id.dropFirst("profile:".count))
        let rows = try query(
            "SELECT parameters, optimized_at, sample_count, log_loss FROM scheduler_params WHERE profile_id = ? LIMIT 1;",
            bindings: [.text(profileID)]
        )
        guard let row = rows.first,
              let data = payload(row, "parameters"),
              let optimizedAt = row["optimized_at"] as? Double,
              let sampleCount = row["sample_count"] as? Int64,
              let logLoss = row["log_loss"] as? Double else { return nil }
        return .scheduler(
            profileID: profileID,
            parameters: try decode(FSRSScheduler.Parameters.self, from: data),
            optimizedAt: Date(timeIntervalSince1970: optimizedAt),
            sampleCount: Int(sampleCount),
            logLoss: logLoss
        )
    }

    func fetchPortableItemTypeMappingRecord(id: String) throws -> PortableItemTypeMappingRecord? {
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let libraryID = UUID(uuidString: parts[0]),
              let typeID = UUID(uuidString: parts[1]) else { return nil }
        let rows = try query(
            "SELECT local_type_id FROM portable_item_type_mappings WHERE origin_library_id = ? AND origin_type_id = ? AND schema_digest = ? LIMIT 1;",
            bindings: [.text(libraryID.uuidString), .text(typeID.uuidString), .text(parts[2])]
        )
        guard let localText = rows.first?["local_type_id"] as? String,
              let localID = UUID(uuidString: localText) else { return nil }
        return PortableItemTypeMappingRecord(
            originLibraryID: libraryID,
            originTypeID: typeID,
            schemaDigest: parts[2],
            localTypeID: localID
        )
    }

    func applySynchronizedBatch(_ mutations: [SynchronizedLibraryMutation]) throws {
        try inTransaction {
            for mutation in mutations {
                switch mutation {
                case let .deck(deck):
                    try execute(
                        """
                        INSERT INTO decks (id, name, parent_id, new_cards_per_day) VALUES (?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET name = excluded.name, parent_id = excluded.parent_id,
                            new_cards_per_day = excluded.new_cards_per_day;
                        """,
                        bindings: [.text(deck.id.uuidString), .text(deck.name), deck.parentID.map { .text($0.uuidString) } ?? .null, deck.newCardsPerDay.map { .int(Int64($0)) } ?? .null]
                    )
                case let .itemType(type):
                    try updateItemType(type)
                case let .item(item, createdAt, updatedAt):
                    guard let itemType = try fetchValidatedItemType(id: item.itemTypeID) else {
                        throw DatabaseError.itemTypeNotFound(item.itemTypeID)
                    }
                    try validateSynchronizedItem(item, against: itemType)
                    try execute(
                        """
                        INSERT INTO items (id, item_type_id, fields, tags, deck_id, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET item_type_id = excluded.item_type_id,
                            fields = excluded.fields, tags = excluded.tags, deck_id = excluded.deck_id,
                            updated_at = excluded.updated_at;
                        """,
                        bindings: [.text(item.id.uuidString), .text(item.itemTypeID.uuidString), .blob(try encode(item.fields)), .blob(try encode(item.tags)), item.deckID.map { .text($0.uuidString) } ?? .null, .double(createdAt.timeIntervalSince1970), .double(updatedAt.timeIntervalSince1970)]
                    )
                    try upsertBrowseProjection(item, itemType: itemType, createdAt: createdAt)
                case let .card(card):
                    try upsertSynchronizedCard(card)
                case let .review(record):
                    if try fetchReviewLog(id: record.log.id) == nil {
                        try insertReviewLog(record.log, memoryBefore: record.memoryBefore)
                    }
                case let .reviewRevert(record):
                    try execute(
                        "INSERT OR IGNORE INTO review_reverts (id, review_log_id, reverted_at) VALUES (?, ?, ?);",
                        bindings: [.text(record.id.uuidString), .text(record.reviewLogID.uuidString), .double(record.revertedAt.timeIntervalSince1970)]
                    )
                case let .itemTypeMembership(record):
                    switch record {
                    case let .library(itemTypeID):
                        try execute("INSERT OR IGNORE INTO library_item_types (item_type_id) VALUES (?);", bindings: [.text(itemTypeID.uuidString)])
                    case let .included(rootDeckID, itemTypeID, ordinal):
                        try execute(
                            "INSERT INTO deck_included_item_types (root_deck_id, item_type_id, ordinal) VALUES (?, ?, ?) ON CONFLICT(root_deck_id, item_type_id) DO UPDATE SET ordinal = excluded.ordinal;",
                            bindings: [.text(rootDeckID.uuidString), .text(itemTypeID.uuidString), .int(Int64(ordinal))]
                        )
                    case let .policy(deckID, itemTypeID, ordinal, isDefault):
                        if isDefault { try execute("UPDATE deck_item_type_policy_entries SET is_default = 0 WHERE deck_id = ?;", bindings: [.text(deckID.uuidString)]) }
                        try execute(
                            "INSERT INTO deck_item_type_policy_entries (deck_id, item_type_id, ordinal, is_default) VALUES (?, ?, ?, ?) ON CONFLICT(deck_id, item_type_id) DO UPDATE SET ordinal = excluded.ordinal, is_default = excluded.is_default;",
                            bindings: [.text(deckID.uuidString), .text(itemTypeID.uuidString), .int(Int64(ordinal)), .int(isDefault ? 1 : 0)]
                        )
                    }
                case let .schedulingSettings(record):
                    switch record {
                    case let .studyDayRollover(minutes):
                        guard StudyDay.validRolloverMinutes.contains(minutes) else { throw DatabaseError.invalidDeck("Study day rollover must be a valid local time.") }
                        try setMetadataValue(String(minutes), forKey: ItemStore.studyDayRolloverMetadataKeyForSync)
                    case let .scheduler(profileID, parameters, optimizedAt, sampleCount, logLoss):
                        try saveSchedulerParameters(parameters, profileID: profileID, optimizedAt: optimizedAt, sampleCount: sampleCount, logLoss: logLoss)
                    }
                case let .portableTypeMapping(record):
                    try persistPortableItemTypeMapping(originLibraryID: record.originLibraryID, originTypeID: record.originTypeID, schemaDigest: record.schemaDigest, localTypeID: record.localTypeID)
                case let .tombstone(kind, id):
                    try applySynchronizedTombstone(kind: kind, id: id)
                }
            }
        }
    }

    private func applySynchronizedTombstone(kind: LibraryResourceKind, id: String) throws {
        switch kind {
        case .deck:
            guard let uuid = UUID(uuidString: id) else { return }
            try execute("UPDATE decks SET parent_id = NULL WHERE parent_id = ?;", bindings: [.text(uuid.uuidString)])
            try execute("UPDATE items SET deck_id = NULL WHERE deck_id = ?;", bindings: [.text(uuid.uuidString)])
            try execute("UPDATE cards SET deck_id = NULL WHERE deck_id = ?;", bindings: [.text(uuid.uuidString)])
            try deleteDeck(id: uuid)
        case .item:
            if let uuid = UUID(uuidString: id) { try deleteItem(id: uuid) }
        case .itemType:
            if let uuid = UUID(uuidString: id), try countItems(itemTypeID: uuid) == 0 { try deleteItemType(id: uuid) }
        case .card:
            if let uuid = UUID(uuidString: id) { try deleteCard(id: uuid) }
        case .reviewRevert:
            if let uuid = UUID(uuidString: id) { try execute("DELETE FROM review_reverts WHERE id = ?;", bindings: [.text(uuid.uuidString)]) }
        case .itemTypeMembership:
            let parts = id.split(separator: ":").map(String.init)
            if parts.count == 2, parts[0] == "library" { try execute("DELETE FROM library_item_types WHERE item_type_id = ?;", bindings: [.text(parts[1])]) }
            if parts.count == 3, parts[0] == "included" { try execute("DELETE FROM deck_included_item_types WHERE root_deck_id = ? AND item_type_id = ?;", bindings: [.text(parts[1]), .text(parts[2])]) }
            if parts.count == 3, parts[0] == "policy" { try execute("DELETE FROM deck_item_type_policy_entries WHERE deck_id = ? AND item_type_id = ?;", bindings: [.text(parts[1]), .text(parts[2])]) }
        case .schedulingSettings:
            if id == "rollover" { try execute("DELETE FROM app_metadata WHERE key = ?;", bindings: [.text(ItemStore.studyDayRolloverMetadataKeyForSync)]) }
            else if id.hasPrefix("profile:") { try execute("DELETE FROM scheduler_params WHERE profile_id = ?;", bindings: [.text(String(id.dropFirst("profile:".count)))]) }
        case .portableTypeMapping:
            let parts = id.split(separator: ":", maxSplits: 2).map(String.init)
            if parts.count == 3 { try execute("DELETE FROM portable_item_type_mappings WHERE origin_library_id = ? AND origin_type_id = ? AND schema_digest = ?;", bindings: [.text(parts[0]), .text(parts[1]), .text(parts[2])]) }
        case .library, .review, .studyResponse, .media:
            break
        }
    }

    private func validateSynchronizedItem(_ item: Item, against itemType: ItemType) throws {
        let definitions = Dictionary(uniqueKeysWithValues: itemType.fields.map { ($0.id, $0) })
        var seen: Set<UUID> = []
        for value in item.fields {
            guard seen.insert(value.fieldID).inserted, definitions[value.fieldID] != nil else {
                throw DatabaseError.invalidItem("The synchronized item has invalid fields.")
            }
        }
        for field in itemType.fields where field.isRequired {
            guard let value = item.value(for: field.id), !value.isEmpty else {
                throw DatabaseError.requiredFieldEmpty(field.name)
            }
        }
        if let deckID = item.deckID, try fetchDeck(id: deckID) == nil {
            throw DatabaseError.deckNotFound(deckID)
        }
    }

    private func inTransaction<Result>(_ body: () throws -> Result) throws -> Result {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            if changeTrackingReady {
                try execute(
                    """
                    INSERT OR REPLACE INTO api_transaction_context (
                        singleton, transaction_id, occurred_at, is_implicit
                    ) VALUES (1, ?, ?, 0);
                    """,
                    bindings: [
                        .text(UUID().uuidString.lowercased()),
                        .double(Date.now.timeIntervalSince1970),
                    ]
                )
            }
            let result = try body()
            if changeTrackingReady {
                try execute("DELETE FROM api_transaction_context WHERE singleton = 1;")
            }
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// Keeps multi-statement query planning and consumption on one SQLite
    /// snapshot without making read-only transaction control look like a data
    /// revision to cache clients.
    private func inReadTransaction<Result>(_ body: () throws -> Result) throws -> Result {
        try executeTransactionControl("BEGIN DEFERRED TRANSACTION;")
        do {
            let result = try body()
            try executeTransactionControl("COMMIT;")
            return result
        } catch {
            try? executeTransactionControl("ROLLBACK;")
            throw error
        }
    }

    private func executeTransactionControl(_ sql: String) throws {
        guard let handle else {
            throw DatabaseError.executeFailed("Database is closed.")
        }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.executeFailed(errorMessage(from: handle))
        }
    }

    private func execute(_ sql: String, bindings: [Binding] = []) throws {
        guard let handle else {
            throw DatabaseError.executeFailed("Database is closed.")
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw DatabaseError.executeFailed(errorMessage(from: handle))
        }
        defer { sqlite3_finalize(statement) }

        try bind(bindings, to: statement)

        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else {
            throw DatabaseError.executeFailed(errorMessage(from: handle))
        }
        localRevision &+= 1
    }

    private func prepareStatement(_ sql: String) throws -> OpaquePointer {
        guard let handle else {
            throw DatabaseError.executeFailed("Database is closed.")
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw DatabaseError.executeFailed(errorMessage(from: handle))
        }
        return statement
    }

    private func executePrepared(
        _ statement: OpaquePointer,
        bindings: [Binding]
    ) throws {
        guard let handle else {
            throw DatabaseError.executeFailed("Database is closed.")
        }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        try bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.executeFailed(errorMessage(from: handle))
        }
        localRevision &+= 1
    }

    private func query(_ sql: String, bindings: [Binding] = []) throws -> [[String: Any?]] {
        guard let handle else {
            throw DatabaseError.queryFailed("Database is closed.")
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw DatabaseError.queryFailed(errorMessage(from: handle))
        }
        defer { sqlite3_finalize(statement) }

        try bind(bindings, to: statement)

        var rows: [[String: Any?]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else {
                throw DatabaseError.queryFailed(errorMessage(from: handle))
            }
            rows.append(readRow(from: statement))
        }
        return rows
    }

    private enum Binding {
        case text(String)
        case blob(Data)
        case double(Double)
        case int(Int64)
        case null
    }

    private func bind(_ bindings: [Binding], to statement: OpaquePointer) throws {
        for (index, binding) in bindings.enumerated() {
            let position = Int32(index + 1)
            let code: Int32
            switch binding {
            case let .text(value):
                code = sqlite3_bind_text(statement, position, value, -1, SQLITE_TRANSIENT)
            case let .blob(value):
                if value.isEmpty {
                    code = sqlite3_bind_zeroblob(statement, position, 0)
                } else {
                    code = value.withUnsafeBytes { buffer in
                        sqlite3_bind_blob(
                            statement,
                            position,
                            buffer.baseAddress,
                            Int32(buffer.count),
                            SQLITE_TRANSIENT
                        )
                    }
                }
            case let .double(value):
                code = sqlite3_bind_double(statement, position, value)
            case let .int(value):
                code = sqlite3_bind_int64(statement, position, value)
            case .null:
                code = sqlite3_bind_null(statement, position)
            }
            guard code == SQLITE_OK else {
                throw DatabaseError.executeFailed("Failed to bind parameter \(position).")
            }
        }
    }

    private func readRow(from statement: OpaquePointer) -> [String: Any?] {
        let columnCount = sqlite3_column_count(statement)
        var row: [String: Any?] = [:]
        row.reserveCapacity(Int(columnCount))

        for index in 0..<columnCount {
            let name = String(cString: sqlite3_column_name(statement, index))
            switch sqlite3_column_type(statement, index) {
            case SQLITE_INTEGER:
                row[name] = sqlite3_column_int64(statement, index)
            case SQLITE_FLOAT:
                row[name] = sqlite3_column_double(statement, index)
            case SQLITE_TEXT:
                row[name] = String(cString: sqlite3_column_text(statement, index))
            case SQLITE_BLOB:
                let length = Int(sqlite3_column_bytes(statement, index))
                if length == 0 {
                    row[name] = Data()
                } else if let bytes = sqlite3_column_blob(statement, index) {
                    row[name] = Data(bytes: bytes, count: length)
                } else {
                    row[name] = nil
                }
            default:
                row[name] = nil
            }
        }
        return row
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try encoder.encode(value)
        } catch {
            throw DatabaseError.encodingFailed
        }
    }

    /// Encoded columns are always written as blobs, but a BLOB column has blob
    /// affinity, so SQLite keeps whatever storage class a writer bound. A row
    /// repaired by an external tool that bound the same JSON as text is still
    /// readable, and reading it beats failing every query that selects the row.
    private func payload(_ row: [String: Any?], _ column: String) -> Data? {
        switch row[column] ?? nil {
        case let data as Data:
            return data
        case let text as String:
            return Data(text.utf8)
        default:
            return nil
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw DatabaseError.decodingFailed
        }
    }

    private func errorMessage(from handle: OpaquePointer?) -> String {
        if let handle, let message = sqlite3_errmsg(handle) {
            return String(cString: message)
        }
        return "Unknown SQLite error."
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
