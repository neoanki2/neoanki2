import Foundation

enum Schema {
    static let version = 8

    static let createStatements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS schema_version (
            version INTEGER NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS app_metadata (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS item_types (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            definition BLOB NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS items (
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
        CREATE TABLE IF NOT EXISTS cards (
            id TEXT PRIMARY KEY NOT NULL,
            item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
            template_id TEXT NOT NULL,
            skill BLOB NOT NULL,
            memory BLOB NOT NULL,
            due_at REAL NOT NULL DEFAULT 0,
            is_suspended INTEGER NOT NULL DEFAULT 0,
            deck_id TEXT
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS review_logs (
            id TEXT PRIMARY KEY NOT NULL,
            card_id TEXT NOT NULL,
            reviewed_at REAL NOT NULL,
            log BLOB NOT NULL,
            memory_before BLOB NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS review_reverts (
            id TEXT PRIMARY KEY NOT NULL,
            review_log_id TEXT NOT NULL UNIQUE REFERENCES review_logs(id),
            reverted_at REAL NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS decks (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            parent_id TEXT REFERENCES decks(id)
        );
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_items_item_type_id ON items(item_type_id);
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_cards_item_id ON cards(item_id);
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_cards_due_at ON cards(due_at);
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_review_logs_card_id ON review_logs(card_id);
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_review_reverts_log_id ON review_reverts(review_log_id);
        """,
        """
        CREATE TABLE IF NOT EXISTS media_assets (
            hash TEXT PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL,
            byte_size INTEGER NOT NULL,
            file_extension TEXT NOT NULL,
            created_at REAL NOT NULL,
            ref_count INTEGER NOT NULL DEFAULT 0 CHECK(ref_count >= 0)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS scheduler_params (
            profile_id TEXT PRIMARY KEY NOT NULL,
            parameters BLOB NOT NULL,
            optimized_at REAL NOT NULL,
            sample_count INTEGER NOT NULL,
            log_loss REAL NOT NULL
        );
        """,
    ]

    /// Applied when upgrading from schema version 7.
    static let migrationV8Statements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS scheduler_params (
            profile_id TEXT PRIMARY KEY NOT NULL,
            parameters BLOB NOT NULL,
            optimized_at REAL NOT NULL,
            sample_count INTEGER NOT NULL,
            log_loss REAL NOT NULL
        );
        """,
    ]

    /// Applied when upgrading from schema version 4. Existing libraries have
    /// already passed first-run seeding, so the marker prevents resurrection.
    static let migrationV5Statements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS app_metadata (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        """,
        """
        INSERT INTO app_metadata (key, value)
        VALUES ('starter_item_types_seeded', '1')
        ON CONFLICT(key) DO NOTHING;
        """,
    ]

    /// Applied when upgrading from schema version 5.
    ///
    /// Rebuilding `review_logs` deliberately removes its cascading card foreign
    /// key. Review history must survive item/card deletion, while compensating
    /// reversals are recorded separately instead of mutating or deleting logs.
    static let migrationV6Statements: [String] = [
        """
        CREATE TABLE review_logs_v5 (
            id TEXT PRIMARY KEY NOT NULL,
            card_id TEXT NOT NULL,
            reviewed_at REAL NOT NULL,
            log BLOB NOT NULL,
            memory_before BLOB
        );
        """,
        """
        INSERT INTO review_logs_v5 (id, card_id, reviewed_at, log)
        SELECT id, card_id, reviewed_at, log FROM review_logs;
        """,
        """
        DROP TABLE review_logs;
        """,
        """
        ALTER TABLE review_logs_v5 RENAME TO review_logs;
        """,
        """
        CREATE INDEX idx_review_logs_card_id ON review_logs(card_id);
        """,
        """
        CREATE TABLE review_reverts (
            id TEXT PRIMARY KEY NOT NULL,
            review_log_id TEXT NOT NULL UNIQUE REFERENCES review_logs(id),
            reverted_at REAL NOT NULL
        );
        """,
        """
        CREATE INDEX idx_review_reverts_log_id ON review_reverts(review_log_id);
        """,
    ]

    /// Applied when upgrading from schema version 3.
    static let migrationV4Statements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS media_assets (
            hash TEXT PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL,
            byte_size INTEGER NOT NULL,
            file_extension TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        """,
    ]

    /// Applied when upgrading from schema version 6. Reference counts are
    /// backfilled from persisted item fields by SQLiteDatabase.
    static let migrationV7Statements: [String] = [
        """
        ALTER TABLE media_assets
        ADD COLUMN ref_count INTEGER NOT NULL DEFAULT 0 CHECK(ref_count >= 0);
        """,
    ]

    /// Applied when upgrading from schema version 1.
    static let migrationV2Statements: [String] = [
        """
        ALTER TABLE cards ADD COLUMN due_at REAL NOT NULL DEFAULT 0;
        """,
        """
        CREATE TABLE IF NOT EXISTS review_logs (
            id TEXT PRIMARY KEY NOT NULL,
            card_id TEXT NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
            reviewed_at REAL NOT NULL,
            log BLOB NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS decks (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            parent_id TEXT REFERENCES decks(id)
        );
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_cards_due_at ON cards(due_at);
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_review_logs_card_id ON review_logs(card_id);
        """,
    ]
}
