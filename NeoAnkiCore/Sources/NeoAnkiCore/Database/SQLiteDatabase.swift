import CryptoKit
import Darwin
import Foundation
import SQLite3

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

struct PersistedItem {
    var item: Item
    var createdAt: Date
    var updatedAt: Date
}

/// Low-level SQLite connection. An actor so callers serialize access.
actor SQLiteDatabase {
    private nonisolated(unsafe) var handle: OpaquePointer?
    private let databaseURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

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
            }
            return
        }

        guard current < Schema.version else { return }

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

            try execute(
                "UPDATE schema_version SET version = ?;",
                bindings: [.int(Int64(Schema.version))]
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
        guard let row = rows.first, let data = row["definition"] as? Data else { return nil }
        return try decode(ItemType.self, from: data)
    }

    func fetchItemType(named name: String) throws -> ItemType? {
        let rows = try query(
            "SELECT definition FROM item_types WHERE name = ? LIMIT 1;",
            bindings: [.text(name)]
        )
        guard let row = rows.first, let data = row["definition"] as? Data else { return nil }
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
            guard let data = row["definition"] as? Data else {
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
              let definition = row["definition"] as? Data
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
            INSERT INTO decks (id, name, parent_id)
            VALUES (?, ?, ?);
            """,
            bindings: [
                .text(deck.id.uuidString),
                .text(deck.name),
                deck.parentID.map { .text($0.uuidString) } ?? .null,
            ]
        )
    }

    func fetchDeck(id: UUID) throws -> Deck? {
        let rows = try query(
            "SELECT id, name, parent_id FROM decks WHERE id = ? LIMIT 1;",
            bindings: [.text(id.uuidString)]
        )
        guard let row = rows.first,
              let idText = row["id"] as? String,
              let deckID = UUID(uuidString: idText),
              let name = row["name"] as? String
        else { return nil }

        let parentID = (row["parent_id"] as? String).flatMap(UUID.init(uuidString:))
        return Deck(id: deckID, name: name, parentID: parentID)
    }

    func fetchAllDecks() throws -> [Deck] {
        let rows = try query(
            """
            SELECT id, name, parent_id
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
            return Deck(id: deckID, name: name, parentID: parentID)
        }
    }

    func updateDeck(_ deck: Deck) throws {
        try execute(
            """
            UPDATE decks
            SET name = ?, parent_id = ?
            WHERE id = ?;
            """,
            bindings: [
                .text(deck.name),
                deck.parentID.map { .text($0.uuidString) } ?? .null,
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

    func fetchDueCards(deckIDs: Set<UUID>, asOf now: Date, limit: Int? = nil) throws -> [Card] {
        guard !deckIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: deckIDs.count).joined(separator: ", ")
        var sql = """
            SELECT id, item_id, template_id, skill, memory, is_suspended, deck_id, cloze_group
            FROM cards
            WHERE is_suspended = 0 AND due_at <= ? AND deck_id IN (\(placeholders))
            ORDER BY due_at ASC
            """
        var bindings: [Binding] = [.double(now.timeIntervalSince1970)]
        bindings.append(contentsOf: deckIDs.sorted { $0.uuidString < $1.uuidString }.map { .text($0.uuidString) })
        if let limit {
            sql += " LIMIT \(limit);"
        } else {
            sql += ";"
        }
        let rows = try query(sql, bindings: bindings)
        return try rows.map { try decodeCard(from: $0) }
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

    func countDueCards(deckIDs: Set<UUID>, asOf now: Date) throws -> Int {
        guard !deckIDs.isEmpty else { return 0 }
        let placeholders = Array(repeating: "?", count: deckIDs.count).joined(separator: ", ")
        var bindings: [Binding] = [.double(now.timeIntervalSince1970)]
        bindings.append(contentsOf: deckIDs.sorted { $0.uuidString < $1.uuidString }.map { .text($0.uuidString) })
        let rows = try query(
            """
            SELECT COUNT(*) AS count
            FROM cards
            WHERE is_suspended = 0 AND due_at <= ? AND deck_id IN (\(placeholders));
            """,
            bindings: bindings
        )
        guard let count = rows.first?["count"] as? Int64 else { return 0 }
        return Int(count)
    }

    func countDueCards(deckID: UUID, asOf now: Date) throws -> Int {
        try countDueCards(deckIDs: [deckID], asOf: now)
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
            try consumeMediaReservations(ids: mediaReservationIDs(in: item))
        }
    }

    func deleteItemWithMedia(id: UUID, deletedAt: Date) throws -> Bool {
        try inTransaction {
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
                    id, item_id, template_id, skill, memory, due_at, is_suspended, deck_id, cloze_group
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                bindings: [
                    .text(card.id.uuidString),
                    .text(card.itemID.uuidString),
                    .text(card.templateID.uuidString),
                    .blob(skill),
                    .blob(memory),
                    .double(card.memory.due.timeIntervalSince1970),
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

    func fetchDueCards(asOf now: Date, limit: Int? = nil) throws -> [Card] {
        var sql = """
            SELECT id, item_id, template_id, skill, memory, is_suspended, deck_id, cloze_group
            FROM cards
            WHERE is_suspended = 0 AND due_at <= ?
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

    func countDueCards(asOf now: Date) throws -> Int {
        let rows = try query(
            """
            SELECT COUNT(*) AS count
            FROM cards
            WHERE is_suspended = 0 AND due_at <= ?;
            """,
            bindings: [.double(now.timeIntervalSince1970)]
        )
        guard let count = rows.first?["count"] as? Int64 else { return 0 }
        return Int(count)
    }

    func updateCardMemory(_ cardID: UUID, memory: MemoryState) throws {
        let memoryData = try encode(memory)
        try execute(
            """
            UPDATE cards
            SET memory = ?, due_at = ?
            WHERE id = ?;
            """,
            bindings: [
                .blob(memoryData),
                .double(memory.due.timeIntervalSince1970),
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
            guard let data = row["log"] as? Data,
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
        guard let data = rows.first?["parameters"] as? Data else { return nil }
        return try? decoder.decode(FSRSScheduler.Parameters.self, from: data)
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
        log: ReviewLog
    ) throws {
        try inTransaction {
            try updateCardMemory(cardID, memory: memoryAfter)
            try insertReviewLog(log, memoryBefore: memoryBefore)
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
            guard let memoryData = row["memory_before"] as? Data else {
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
                let memoryData = row["memory"] as? Data
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

    /// Legacy URL decoding exists only inside the upgrade transaction. Runtime
    /// decoding continues to reject URL-backed MediaRef values.
    private func migrateLegacyMediaReferences() throws {
        guard try tableExists("items") else { return }
        let rows = try query("SELECT id, fields FROM items;")
        for row in rows {
            guard let id = row["id"] as? String,
                  let data = row["fields"] as? Data,
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

    private func decodeCard(from row: [String: Any?]) throws -> Card {
        guard
            let idText = row["id"] as? String,
            let id = UUID(uuidString: idText),
            let itemIDText = row["item_id"] as? String,
            let itemID = UUID(uuidString: itemIDText),
            let templateIDText = row["template_id"] as? String,
            let templateID = UUID(uuidString: templateIDText),
            let skillData = row["skill"] as? Data,
            let memoryData = row["memory"] as? Data,
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
            let fieldsData = row["fields"] as? Data,
            let tagsData = row["tags"] as? Data,
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

    func deleteDeckMovingContents(id: UUID, reassignTo: UUID?) throws {
        try inTransaction {
            try reparentChildDecks(from: id, to: reassignTo)
            let items = try fetchItems(deckID: id)
            for entry in items {
                try updateItemDeck(itemID: entry.item.id, deckID: reassignTo)
                try updateCardsDeck(itemID: entry.item.id, deckID: reassignTo)
            }
            try deleteDeck(id: id)
        }
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
