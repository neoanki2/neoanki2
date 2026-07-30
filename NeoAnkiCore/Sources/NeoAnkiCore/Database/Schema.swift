import Foundation

enum Schema {
    static let version = 20

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
        CREATE TABLE IF NOT EXISTS quarantined_item_type_definitions (
            item_type_id TEXT NOT NULL,
            name TEXT NOT NULL,
            definition BLOB NOT NULL,
            archived_at REAL NOT NULL
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
            phase TEXT NOT NULL DEFAULT 'new',
            lapses INTEGER NOT NULL DEFAULT 0,
            is_suspended INTEGER NOT NULL DEFAULT 0,
            deck_id TEXT,
            cloze_group INTEGER
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS review_logs (
            id TEXT PRIMARY KEY NOT NULL,
            card_id TEXT NOT NULL,
            reviewed_at REAL NOT NULL,
            log BLOB NOT NULL,
            memory_before BLOB NOT NULL,
            sequence INTEGER NOT NULL UNIQUE
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
        CREATE TRIGGER IF NOT EXISTS review_logs_sequence_insert_required
        BEFORE INSERT ON review_logs
        WHEN NEW.sequence IS NULL
        BEGIN
            SELECT RAISE(ABORT, 'review log sequence is required');
        END;
        """,
        """
        CREATE TRIGGER IF NOT EXISTS review_logs_sequence_update_required
        BEFORE UPDATE OF sequence ON review_logs
        WHEN NEW.sequence IS NULL
        BEGIN
            SELECT RAISE(ABORT, 'review log sequence is required');
        END;
        """,
        """
        CREATE TABLE IF NOT EXISTS decks (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            parent_id TEXT REFERENCES decks(id),
            new_cards_per_day INTEGER CHECK(new_cards_per_day >= 0)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS new_card_introductions (
            review_log_id TEXT PRIMARY KEY NOT NULL REFERENCES review_logs(id),
            deck_id TEXT NOT NULL REFERENCES decks(id) ON DELETE CASCADE,
            study_day TEXT NOT NULL
        );
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_items_item_type_id ON items(item_type_id);
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_items_deck_id ON items(deck_id);
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_cards_item_id ON cards(item_id);
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_cards_due_at ON cards(due_at);
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_cards_phase ON cards(phase);
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_cards_deck_due
        ON cards(deck_id, due_at, id);
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_cards_active_new_due
        ON cards(due_at, id)
        WHERE is_suspended = 0 AND phase = 'new';
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_decks_with_new_card_limit
        ON decks(id)
        WHERE new_cards_per_day IS NOT NULL;
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_review_logs_card_id ON review_logs(card_id);
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_review_reverts_log_id ON review_reverts(review_log_id);
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_new_card_introductions_deck_day
        ON new_card_introductions(deck_id, study_day);
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_new_card_introductions_day_deck_log
        ON new_card_introductions(study_day, deck_id, review_log_id);
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
        CREATE TABLE IF NOT EXISTS media_reservations (
            id TEXT PRIMARY KEY NOT NULL,
            hash TEXT NOT NULL REFERENCES media_assets(hash) ON DELETE CASCADE,
            scope_id TEXT,
            expires_at REAL NOT NULL,
            created_asset INTEGER NOT NULL DEFAULT 0
        );
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_media_reservations_hash
        ON media_reservations(hash);
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_media_reservations_expiry
        ON media_reservations(expires_at);
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
        """
        CREATE TABLE IF NOT EXISTS portable_item_type_mappings (
            origin_library_id TEXT NOT NULL,
            origin_type_id TEXT NOT NULL,
            schema_digest TEXT NOT NULL CHECK(length(schema_digest) = 64),
            local_type_id TEXT NOT NULL REFERENCES item_types(id) ON DELETE CASCADE,
            PRIMARY KEY (origin_library_id, origin_type_id, schema_digest)
        );
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_portable_item_type_mappings_digest
        ON portable_item_type_mappings(schema_digest);
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_portable_item_type_mappings_local_type
        ON portable_item_type_mappings(local_type_id);
        """,
        """
        CREATE TABLE IF NOT EXISTS library_item_types (
            item_type_id TEXT PRIMARY KEY NOT NULL
                REFERENCES item_types(id) ON DELETE CASCADE
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS deck_included_item_types (
            root_deck_id TEXT NOT NULL REFERENCES decks(id) ON DELETE CASCADE,
            item_type_id TEXT NOT NULL REFERENCES item_types(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
            PRIMARY KEY (root_deck_id, item_type_id),
            UNIQUE (root_deck_id, ordinal)
        );
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_deck_included_item_types_type
        ON deck_included_item_types(item_type_id);
        """,
        """
        CREATE TABLE IF NOT EXISTS deck_item_type_policy_entries (
            deck_id TEXT NOT NULL REFERENCES decks(id) ON DELETE CASCADE,
            item_type_id TEXT NOT NULL REFERENCES item_types(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
            is_default INTEGER NOT NULL CHECK(is_default IN (0, 1)),
            PRIMARY KEY (deck_id, item_type_id),
            UNIQUE (deck_id, ordinal)
        );
        """,
        """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_deck_item_type_policy_default
        ON deck_item_type_policy_entries(deck_id)
        WHERE is_default = 1;
        """,
    ] + browseProjectionStatements

    static let browseProjectionStatements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS item_browse_rows (
            item_id TEXT PRIMARY KEY NOT NULL REFERENCES items(id) ON DELETE CASCADE,
            item_type_id TEXT NOT NULL,
            item_type_name TEXT NOT NULL,
            title TEXT NOT NULL,
            subtitle TEXT NOT NULL,
            deck_id TEXT,
            created_at REAL NOT NULL,
            card_count INTEGER NOT NULL DEFAULT 0,
            due_at REAL,
            phase TEXT,
            lapses INTEGER NOT NULL DEFAULT 0
        );
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_item_browse_rows_deck_created
        ON item_browse_rows(deck_id, created_at, item_id);
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_item_browse_rows_created
        ON item_browse_rows(created_at, item_id);
        """,
        """
        CREATE TRIGGER IF NOT EXISTS item_browse_cards_insert
        AFTER INSERT ON cards
        BEGIN
            UPDATE item_browse_rows
            SET card_count = (SELECT COUNT(*) FROM cards WHERE item_id = NEW.item_id),
                due_at = (
                    SELECT due_at FROM cards
                    WHERE item_id = NEW.item_id AND is_suspended = 0
                    ORDER BY due_at ASC, id ASC LIMIT 1
                ),
                phase = (
                    SELECT phase FROM cards
                    WHERE item_id = NEW.item_id AND is_suspended = 0
                    ORDER BY due_at ASC, id ASC LIMIT 1
                ),
                lapses = COALESCE((
                    SELECT MAX(lapses) FROM cards
                    WHERE item_id = NEW.item_id AND is_suspended = 0
                ), 0)
            WHERE item_id = NEW.item_id;
        END;
        """,
        """
        CREATE TRIGGER IF NOT EXISTS item_browse_cards_update
        AFTER UPDATE OF item_id, due_at, phase, lapses, is_suspended ON cards
        BEGIN
            UPDATE item_browse_rows
            SET card_count = (SELECT COUNT(*) FROM cards WHERE item_id = OLD.item_id),
                due_at = (
                    SELECT due_at FROM cards
                    WHERE item_id = OLD.item_id AND is_suspended = 0
                    ORDER BY due_at ASC, id ASC LIMIT 1
                ),
                phase = (
                    SELECT phase FROM cards
                    WHERE item_id = OLD.item_id AND is_suspended = 0
                    ORDER BY due_at ASC, id ASC LIMIT 1
                ),
                lapses = COALESCE((
                    SELECT MAX(lapses) FROM cards
                    WHERE item_id = OLD.item_id AND is_suspended = 0
                ), 0)
            WHERE item_id = OLD.item_id;
            UPDATE item_browse_rows
            SET card_count = (SELECT COUNT(*) FROM cards WHERE item_id = NEW.item_id),
                due_at = (
                    SELECT due_at FROM cards
                    WHERE item_id = NEW.item_id AND is_suspended = 0
                    ORDER BY due_at ASC, id ASC LIMIT 1
                ),
                phase = (
                    SELECT phase FROM cards
                    WHERE item_id = NEW.item_id AND is_suspended = 0
                    ORDER BY due_at ASC, id ASC LIMIT 1
                ),
                lapses = COALESCE((
                    SELECT MAX(lapses) FROM cards
                    WHERE item_id = NEW.item_id AND is_suspended = 0
                ), 0)
            WHERE item_id = NEW.item_id;
        END;
        """,
        """
        CREATE TRIGGER IF NOT EXISTS item_browse_cards_delete
        AFTER DELETE ON cards
        BEGIN
            UPDATE item_browse_rows
            SET card_count = (SELECT COUNT(*) FROM cards WHERE item_id = OLD.item_id),
                due_at = (
                    SELECT due_at FROM cards
                    WHERE item_id = OLD.item_id AND is_suspended = 0
                    ORDER BY due_at ASC, id ASC LIMIT 1
                ),
                phase = (
                    SELECT phase FROM cards
                    WHERE item_id = OLD.item_id AND is_suspended = 0
                    ORDER BY due_at ASC, id ASC LIMIT 1
                ),
                lapses = COALESCE((
                    SELECT MAX(lapses) FROM cards
                    WHERE item_id = OLD.item_id AND is_suspended = 0
                ), 0)
            WHERE item_id = OLD.item_id;
        END;
        """,
        """
        CREATE TRIGGER IF NOT EXISTS item_browse_item_deck_update
        AFTER UPDATE OF deck_id ON items
        BEGIN
            UPDATE item_browse_rows SET deck_id = NEW.deck_id WHERE item_id = NEW.id;
        END;
        """,
        """
        CREATE TRIGGER IF NOT EXISTS item_browse_item_type_name_update
        AFTER UPDATE OF name ON item_types
        BEGIN
            UPDATE item_browse_rows
            SET item_type_name = NEW.name
            WHERE item_type_id = NEW.id;
        END;
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

    /// Applied when upgrading from schema version 8. A nullable group preserves
    /// existing non-cloze cards while allowing one persisted card per cloze group.
    static let migrationV9Statements: [String] = [
        "ALTER TABLE cards ADD COLUMN cloze_group INTEGER;",
    ]

    /// Preserves malformed definitions before an explicit user-requested repair.
    static let migrationV10Statements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS quarantined_item_type_definitions (
            item_type_id TEXT NOT NULL,
            name TEXT NOT NULL,
            definition BLOB NOT NULL,
            archived_at REAL NOT NULL
        );
        """,
    ]

    /// Review append order is independent of wall-clock precision and UUID text.
    static let migrationV11Statements: [String] = [
        "ALTER TABLE review_logs ADD COLUMN sequence INTEGER;",
        "UPDATE review_logs SET sequence = rowid WHERE sequence IS NULL;",
        """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_review_logs_sequence
        ON review_logs(sequence);
        """,
        """
        CREATE TRIGGER IF NOT EXISTS review_logs_sequence_insert_required
        BEFORE INSERT ON review_logs
        WHEN NEW.sequence IS NULL
        BEGIN
            SELECT RAISE(ABORT, 'review log sequence is required');
        END;
        """,
        """
        CREATE TRIGGER IF NOT EXISTS review_logs_sequence_update_required
        BEFORE UPDATE OF sequence ON review_logs
        WHEN NEW.sequence IS NULL
        BEGIN
            SELECT RAISE(ABORT, 'review log sequence is required');
        END;
        """,
    ]

    /// Durable reservations prevent GC from racing an editor/import between
    /// ingesting bytes and committing the item that references them.
    static let migrationV12Statements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS media_reservations (
            id TEXT PRIMARY KEY NOT NULL,
            hash TEXT NOT NULL REFERENCES media_assets(hash) ON DELETE CASCADE,
            scope_id TEXT,
            expires_at REAL NOT NULL,
            created_asset INTEGER NOT NULL DEFAULT 0
        );
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_media_reservations_hash
        ON media_reservations(hash);
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_media_reservations_expiry
        ON media_reservations(expires_at);
        """,
    ]

    /// Gives each library a durable identity and remembers item-type decisions
    /// made while importing portable decks. The library UUID value itself is
    /// initialized by SQLiteDatabase inside the migration transaction.
    static let migrationV13Statements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS app_metadata (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS portable_item_type_mappings (
            origin_library_id TEXT NOT NULL,
            origin_type_id TEXT NOT NULL,
            schema_digest TEXT NOT NULL CHECK(length(schema_digest) = 64),
            local_type_id TEXT NOT NULL REFERENCES item_types(id) ON DELETE CASCADE,
            PRIMARY KEY (origin_library_id, origin_type_id, schema_digest)
        );
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_portable_item_type_mappings_digest
        ON portable_item_type_mappings(schema_digest);
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_portable_item_type_mappings_local_type
        ON portable_item_type_mappings(local_type_id);
        """,
    ]

    /// Lifts `phase` and `lapses` out of the encoded `memory` blob so library
    /// summaries and per-item scheduling state resolve in SQL instead of
    /// decoding every card. Values are backfilled from `memory` by
    /// SQLiteDatabase inside the migration transaction.
    static let migrationV14Statements: [String] = [
        "ALTER TABLE cards ADD COLUMN phase TEXT NOT NULL DEFAULT 'new';",
        "ALTER TABLE cards ADD COLUMN lapses INTEGER NOT NULL DEFAULT 0;",
        """
        CREATE INDEX IF NOT EXISTS idx_cards_phase ON cards(phase);
        """,
    ]

    static let migrationV16Statements: [String] = [
        """
        CREATE INDEX IF NOT EXISTS idx_items_deck_id ON items(deck_id);
        """,
    ]

    static let migrationV17Statements = browseProjectionStatements

    /// Separates ordinary reusable item types from definitions included with
    /// imported decks, and stores contextual authoring policies. Every
    /// pre-existing type remains a normal library type.
    static let migrationV18Statements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS library_item_types (
            item_type_id TEXT PRIMARY KEY NOT NULL
                REFERENCES item_types(id) ON DELETE CASCADE
        );
        """,
        """
        INSERT OR IGNORE INTO library_item_types (item_type_id)
        SELECT id FROM item_types;
        """,
        """
        CREATE TABLE IF NOT EXISTS deck_included_item_types (
            root_deck_id TEXT NOT NULL REFERENCES decks(id) ON DELETE CASCADE,
            item_type_id TEXT NOT NULL REFERENCES item_types(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
            PRIMARY KEY (root_deck_id, item_type_id),
            UNIQUE (root_deck_id, ordinal)
        );
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_deck_included_item_types_type
        ON deck_included_item_types(item_type_id);
        """,
        """
        CREATE TABLE IF NOT EXISTS deck_item_type_policy_entries (
            deck_id TEXT NOT NULL REFERENCES decks(id) ON DELETE CASCADE,
            item_type_id TEXT NOT NULL REFERENCES item_types(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
            is_default INTEGER NOT NULL CHECK(is_default IN (0, 1)),
            PRIMARY KEY (deck_id, item_type_id),
            UNIQUE (deck_id, ordinal)
        );
        """,
        """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_deck_item_type_policy_default
        ON deck_item_type_policy_entries(deck_id)
        WHERE is_default = 1;
        """,
    ]

    /// Lets daily-limit reads seek directly to one study day. The existing
    /// deck-leading index remains useful for deck-specific maintenance.
    static let migrationV19Statements: [String] = [
        """
        CREATE INDEX IF NOT EXISTS idx_new_card_introductions_day_deck_log
        ON new_card_introductions(study_day, deck_id, review_log_id);
        """,
    ]

    /// Supports bounded top-K selection when one daily limiter applies without
    /// ranking the entire due-new population.
    static let migrationV20Statements: [String] = [
        """
        CREATE INDEX IF NOT EXISTS idx_cards_active_new_due
        ON cards(due_at, id)
        WHERE is_suspended = 0 AND phase = 'new';
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_decks_with_new_card_limit
        ON decks(id)
        WHERE new_cards_per_day IS NOT NULL;
        """,
    ]

    /// Adds learner-local deck introduction limits without changing portable
    /// deck content. A nullable limit preserves the previous unlimited behavior.
    static let migrationV15Statements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS decks (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            parent_id TEXT REFERENCES decks(id)
        );
        """,
        """
        ALTER TABLE decks
        ADD COLUMN new_cards_per_day INTEGER CHECK(new_cards_per_day >= 0);
        """,
        """
        CREATE TABLE IF NOT EXISTS new_card_introductions (
            review_log_id TEXT PRIMARY KEY NOT NULL REFERENCES review_logs(id),
            deck_id TEXT NOT NULL REFERENCES decks(id) ON DELETE CASCADE,
            study_day TEXT NOT NULL
        );
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_new_card_introductions_deck_day
        ON new_card_introductions(deck_id, study_day);
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
