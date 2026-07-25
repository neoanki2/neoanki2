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
    case encodingFailed
    case decodingFailed

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
            return "No review log found for card: \(id.uuidString)"
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
        case .encodingFailed:
            return "Could not encode data for storage."
        case .decodingFailed:
            return "Could not decode stored data."
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
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(path: URL) throws {
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

            try execute(
                "UPDATE schema_version SET version = ?;",
                bindings: [.int(Int64(Schema.version))]
            )
        }
    }

    func seedBuiltInItemTypesIfNeeded() throws {
        for itemType in BuiltInItemTypes.all {
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

    func fetchAllItemTypes() throws -> [ItemType] {
        let rows = try query(
            """
            SELECT definition
            FROM item_types
            ORDER BY name ASC;
            """
        )
        return try rows.compactMap { row in
            guard let data = row["definition"] as? Data else { return nil }
            return try decode(ItemType.self, from: data)
        }
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
            SELECT id, item_id, template_id, skill, memory, is_suspended, deck_id
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
            SELECT id, item_id, template_id, skill, memory, is_suspended, deck_id
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
        updatedAt: Date
    ) throws {
        try inTransaction {
            try insertItem(item, createdAt: createdAt, updatedAt: updatedAt)
            try insertCards(cards)
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
                INSERT INTO cards (id, item_id, template_id, skill, memory, due_at, is_suspended, deck_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
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
                ]
            )
        }
    }

    func fetchCard(id: UUID) throws -> Card? {
        let rows = try query(
            """
            SELECT id, item_id, template_id, skill, memory, is_suspended, deck_id
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
            SELECT id, item_id, template_id, skill, memory, is_suspended, deck_id
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

    func insertReviewLog(_ log: ReviewLog) throws {
        let data = try encode(log)
        try execute(
            """
            INSERT INTO review_logs (id, card_id, reviewed_at, log)
            VALUES (?, ?, ?, ?);
            """,
            bindings: [
                .text(log.id.uuidString),
                .text(log.cardID.uuidString),
                .double(log.reviewedAt.timeIntervalSince1970),
                .blob(data),
            ]
        )
    }

    func persistReview(cardID: UUID, memory: MemoryState, log: ReviewLog) throws {
        try inTransaction {
            try updateCardMemory(cardID, memory: memory)
            try insertReviewLog(log)
        }
    }

    func revertReview(cardID: UUID, restoring memory: MemoryState) throws {
        try inTransaction {
            let rows = try query(
                """
                SELECT id FROM review_logs
                WHERE card_id = ?
                ORDER BY reviewed_at DESC
                LIMIT 1;
                """,
                bindings: [.text(cardID.uuidString)]
            )
            guard let row = rows.first, let logID = row["id"] as? String else {
                throw DatabaseError.reviewLogNotFound(cardID)
            }
            try execute(
                "DELETE FROM review_logs WHERE id = ?;",
                bindings: [.text(logID)]
            )
            try updateCardMemory(cardID, memory: memory)
        }
    }

    func countReviewLogs(for cardID: UUID) throws -> Int {
        let rows = try query(
            "SELECT COUNT(*) AS count FROM review_logs WHERE card_id = ?;",
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
            SELECT id, item_id, template_id, skill, memory, is_suspended, deck_id
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

    func deleteItem(id: UUID) throws {
        try execute(
            "DELETE FROM items WHERE id = ?;",
            bindings: [.text(id.uuidString)]
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

        return Card(
            id: id,
            itemID: itemID,
            templateID: templateID,
            skill: skill,
            memory: memory,
            isSuspended: suspendedValue != 0,
            deckID: deckID
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
            let rows = try query("SELECT version FROM schema_version LIMIT 1;")
            guard let version = rows.first?["version"] as? Int64 else { return 0 }
            return Int(version)
        } catch DatabaseError.queryFailed {
            return 0
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

    private func inTransaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try body()
            try execute("COMMIT;")
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
