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
    case cardNotFound(UUID)
    case reviewLogNotFound(UUID)
    case templateNotFound(UUID)
    case deckNotFound(UUID)
    case requiredFieldEmpty(String)
    case invalidItemType(String)
    case invalidDeck(String)
    case invalidMediaAsset(String)
    case encodingFailed
    case decodingFailed
    case unsupportedSchemaVersion(Int)
    case schemaVersionReadFailed

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
        case let .cardNotFound(id):
            return "Card not found: \(id.uuidString)"
        case let .reviewLogNotFound(id):
            return "Review log not found: \(id.uuidString)"
        case let .templateNotFound(id):
            return "Template not found: \(id.uuidString)"
        case let .deckNotFound(id):
            return "Deck not found: \(id.uuidString)"
        case let .requiredFieldEmpty(name):
            return "\(name) is required."
        case let .invalidItemType(message):
            return message
        case let .invalidDeck(message):
            return message
        case let .invalidMediaAsset(message):
            return message
        case .encodingFailed:
            return "Could not encode data for storage."
        case .decodingFailed:
            return "Could not decode stored data."
        case let .unsupportedSchemaVersion(version):
            return "Database schema version \(version) is newer than this app supports."
        case .schemaVersionReadFailed:
            return "Could not read the database schema version."
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

private enum NewCardLimitShape {
    case none
    case single(SingleNewCardLimiter)
    case multiple
}

/// Low-level SQLite connection. An actor so callers serialize access.
actor SQLiteDatabase {
    private nonisolated(unsafe) var handle: OpaquePointer?
    private let databaseURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var localRevision: UInt64 = 0

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
            return
        }

        guard current < Schema.version else {
            _ = try getOrCreateLibraryID()
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
                for sql in Schema.migrationV17Statements {
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

            try execute(
                "UPDATE schema_version SET version = ?;",
                bindings: [.int(Int64(Schema.version))]
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
        try execute(
            """
            INSERT INTO decks (id, name, parent_id, new_cards_per_day)
            VALUES (?, ?, ?, ?);
            """,
            bindings: [
                .text(deck.id.uuidString),
                .text(deck.name),
                deck.parentID.map { .text($0.uuidString) } ?? .null,
                deck.newCardsPerDay.map { .int(Int64($0)) } ?? .null,
            ]
        )
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

    func updateDeck(_ deck: Deck) throws {
        try execute(
            """
            UPDATE decks
            SET name = ?, parent_id = ?, new_cards_per_day = ?
            WHERE id = ?;
            """,
            bindings: [
                .text(deck.name),
                deck.parentID.map { .text($0.uuidString) } ?? .null,
                deck.newCardsPerDay.map { .int(Int64($0)) } ?? .null,
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
            let eligible = try eligibleDueCardsCTE(
                scope: .decks(deckIDs),
                asOf: now,
                studyDay: studyDay
            )
            var sql = eligible.sql + """

                SELECT id, item_id, template_id, skill, memory, is_suspended, deck_id, cloze_group
                FROM eligible_due
                ORDER BY due_at ASC, id ASC
                """
            if let limit {
                sql += " LIMIT \(max(limit, 0));"
            } else {
                sql += ";"
            }
            let rows = try query(sql, bindings: eligible.bindings)
            return try rows.map { try decodeCard(from: $0) }
        }
    }

    func fetchUnassignedDueCards(asOf now: Date, limit: Int? = nil) throws -> [Card] {
        var sql = """
            SELECT id, item_id, template_id, skill, memory, is_suspended, deck_id, cloze_group
            FROM cards
            WHERE is_suspended = 0 AND due_at <= ? AND deck_id IS NULL
            ORDER BY due_at ASC
            """
        if let limit {
            sql += " LIMIT \(limit);"
        } else {
            sql += ";"
        }
        let rows = try query(sql, bindings: [.double(now.timeIntervalSince1970)])
        return try rows.map { try decodeCard(from: $0) }
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
                    is_suspended, deck_id, cloze_group
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
            guard let previous = try fetchItem(id: item.id) else {
                throw DatabaseError.invalidMediaAsset("The item being edited no longer exists.")
            }
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
    }

    func deleteItemWithMedia(id: UUID, deletedAt: Date) throws -> Bool {
        try inTransaction {
            try deleteItemWithMediaWithoutTransaction(id: id, deletedAt: deletedAt)
        }
    }

    func deleteItemWithMediaWithoutTransaction(id: UUID, deletedAt: Date) throws -> Bool {
        guard let persisted = try fetchItem(id: id) else { return false }
        try applyMediaReferenceDeltas(
            from: mediaReferenceCounts(in: persisted.item),
            to: [:],
            descriptors: [:],
            now: deletedAt
        )
        try deleteItem(id: id)
        return true
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
                    is_suspended, deck_id, cloze_group
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
                ]
            )
        }
    }

    func fetchCard(id: UUID) throws -> Card? {
        let rows = try query(
            """
            SELECT id, item_id, template_id, skill, memory, is_suspended, deck_id, cloze_group
            FROM cards
            WHERE id = ?
            LIMIT 1;
            """,
            bindings: [.text(id.uuidString)]
        )
        guard let row = rows.first else { return nil }
        return try decodeCard(from: row)
    }

    func fetchDueCards(asOf now: Date, studyDay: String, limit: Int? = nil) throws -> [Card] {
        try inReadTransaction {
            let eligible = try eligibleDueCardsCTE(scope: .all, asOf: now, studyDay: studyDay)
            var sql = eligible.sql + """

                SELECT id, item_id, template_id, skill, memory, is_suspended, deck_id, cloze_group
                FROM eligible_due
                ORDER BY due_at ASC, id ASC
                """
            if let limit {
                sql += " LIMIT \(max(limit, 0));"
            } else {
                sql += ";"
            }

            let rows = try query(sql, bindings: eligible.bindings)
            return try rows.map { try decodeCard(from: $0) }
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
        case .multiple:
            break
        }

        let sql = """
            WITH RECURSIVE deck_ancestry(descendant_id, ancestor_id) AS (
                SELECT id, id FROM decks
                UNION
                SELECT ancestry.descendant_id, decks.parent_id
                FROM deck_ancestry AS ancestry
                JOIN decks ON decks.id = ancestry.ancestor_id
                WHERE decks.parent_id IS NOT NULL
            ),
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
            ),
            due_cards AS (
                SELECT cards.*
                FROM cards
                WHERE cards.is_suspended = 0
                  AND cards.due_at <= ?
                  AND \(scopeFilter.sql)
            ),
            new_positions AS (
                SELECT
                    due_cards.id AS card_id,
                    limiter.id AS limiter_id,
                    limiter.new_cards_per_day,
                    COALESCE(active_introductions.introduced_count, 0) AS introduced_count,
                    ROW_NUMBER() OVER (
                        PARTITION BY limiter.id
                        ORDER BY due_cards.due_at ASC, due_cards.id ASC
                    ) AS new_rank
                FROM due_cards
                JOIN deck_ancestry AS ancestry
                    ON ancestry.descendant_id = due_cards.deck_id
                JOIN decks AS limiter
                    ON limiter.id = ancestry.ancestor_id
                   AND limiter.new_cards_per_day IS NOT NULL
                LEFT JOIN active_introductions
                    ON active_introductions.limiter_id = limiter.id
                WHERE due_cards.phase = 'new'
            ),
            blocked_new AS (
                SELECT DISTINCT card_id
                FROM new_positions
                WHERE new_rank > MAX(new_cards_per_day - introduced_count, 0)
            ),
            eligible_due AS (
                SELECT due_cards.*
                FROM due_cards
                WHERE (
                      due_cards.phase != 'new'
                      OR due_cards.deck_id IS NULL
                      OR NOT EXISTS (
                          SELECT 1
                          FROM blocked_new
                          WHERE blocked_new.card_id = due_cards.id
                      )
                  )
            )
            """
        return (
            sql,
            [.text(studyDay), .double(now.timeIntervalSince1970)] + scopeFilter.bindings
        )
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
    /// single-limiter shape can select only its remaining top-K cards; multiple
    /// limiters retain the general intersection-by-rank query below.
    private func newCardLimitShape(
        scope: CardScope,
        studyDay: String
    ) throws -> NewCardLimitShape {
        if case .unassigned = scope {
            return .none
        }

        let limiterRows: [[String: Any?]]
        switch scope {
        case .unassigned:
            return .none
        case let .decks(deckIDs):
            guard !deckIDs.isEmpty else { return .none }
            guard deckIDs.count <= 800 else { return .multiple }
            let ordered = deckIDs.sorted { $0.uuidString < $1.uuidString }
            let values = Array(repeating: "(?)", count: ordered.count)
                .joined(separator: ", ")
            limiterRows = try query(
                """
                WITH RECURSIVE selected_decks(id) AS (
                    VALUES \(values)
                ),
                relevant_decks(id) AS (
                    SELECT id FROM selected_decks
                    UNION
                    SELECT decks.parent_id
                    FROM decks
                    JOIN relevant_decks
                        ON decks.id = relevant_decks.id
                    WHERE decks.parent_id IS NOT NULL
                )
                SELECT DISTINCT decks.id, decks.new_cards_per_day
                FROM decks
                JOIN relevant_decks
                    ON relevant_decks.id = decks.id
                WHERE decks.new_cards_per_day IS NOT NULL
                ORDER BY decks.id
                LIMIT 2;
                """,
                bindings: ordered.map { .text($0.uuidString) }
            )
        case .all:
            limiterRows = try query(
                """
                SELECT id, new_cards_per_day
                FROM decks
                WHERE new_cards_per_day IS NOT NULL
                ORDER BY id
                LIMIT 2;
                """
            )
        }

        guard let firstLimiter = limiterRows.first else { return .none }
        guard
            limiterRows.count == 1,
            let limiterID = firstLimiter["id"] as? String,
            let dailyLimitValue = firstLimiter["new_cards_per_day"] as? Int64
        else {
            return .multiple
        }
        let dailyLimit = Int(dailyLimitValue)

        let topologyRows = try query("SELECT id, parent_id FROM decks;")
        var childrenByParent: [String: [String]] = [:]
        for row in topologyRows {
            guard
                let id = row["id"] as? String,
                let parentID = row["parent_id"] as? String
            else { continue }
            childrenByParent[parentID, default: []].append(id)
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
            return .multiple
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

    func insertReviewLog(_ log: ReviewLog, memoryBefore: MemoryState) throws {
        let nextSequence = try nextReviewSequence()
        let sequencedLog = log.withSequence(nextSequence)
        let data = try encode(sequencedLog)
        let memoryData = try encode(memoryBefore)
        try execute(
            """
            INSERT INTO review_logs (id, card_id, reviewed_at, log, memory_before, sequence)
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .text(log.id.uuidString),
                .text(log.cardID.uuidString),
                .double(log.reviewedAt.timeIntervalSince1970),
                .blob(data),
                .blob(memoryData),
                .int(nextSequence),
            ]
        )
    }

    func fetchActiveReviewLogs() throws -> [ReviewLog] {
        let rows = try query(
            """
            SELECT review_logs.log, review_logs.sequence
            FROM review_logs
            LEFT JOIN review_reverts
                ON review_reverts.review_log_id = review_logs.id
            WHERE review_reverts.id IS NULL
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

    func persistReview(
        cardID: UUID,
        memoryBefore: MemoryState,
        memoryAfter: MemoryState,
        log: ReviewLog,
        introducedDeckID: UUID?,
        introductionStudyDay: String?
    ) throws {
        try inTransaction {
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
        }
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
            LEFT JOIN review_reverts
                ON review_reverts.review_log_id = review_logs.id
            WHERE review_logs.card_id = ? AND review_reverts.id IS NULL;
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
            LEFT JOIN review_reverts
                ON review_reverts.review_log_id = review_logs.id
            WHERE review_reverts.id IS NULL;
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

    func deleteItemType(id: UUID) throws {
        try execute(
            "DELETE FROM item_types WHERE id = ?;",
            bindings: [.text(id.uuidString)]
        )
    }

    func fetchCards(for itemID: UUID) throws -> [Card] {
        let rows = try query(
            """
            SELECT id, item_id, template_id, skill, memory, is_suspended, deck_id, cloze_group
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

        return Card(
            id: id,
            itemID: itemID,
            templateID: templateID,
            skill: skill,
            memory: memory,
            isSuspended: suspendedValue != 0,
            deckID: deckID,
            clozeGroup: clozeGroup
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

    private func inTransaction<Result>(_ body: () throws -> Result) throws -> Result {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let result = try body()
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
                code = value.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(
                        statement,
                        position,
                        buffer.baseAddress,
                        Int32(buffer.count),
                        SQLITE_TRANSIENT
                    )
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
                if let bytes = sqlite3_column_blob(statement, index) {
                    let length = Int(sqlite3_column_bytes(statement, index))
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
