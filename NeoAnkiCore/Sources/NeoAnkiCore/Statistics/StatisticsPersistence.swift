import Foundation

extension Schema {
    static let statisticsStatements: [String] = [
        "CREATE TABLE IF NOT EXISTS statistics_events(sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT UNIQUE NOT NULL, kind TEXT NOT NULL, occurred_at REAL NOT NULL, card_id TEXT NOT NULL, payload BLOB NOT NULL);",
        "CREATE INDEX IF NOT EXISTS statistics_events_date ON statistics_events(occurred_at, kind);",
        "CREATE INDEX IF NOT EXISTS statistics_events_card ON statistics_events(card_id, kind);",
        "CREATE TABLE IF NOT EXISTS statistics_changes(sequence INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT NOT NULL DEFAULT (lower(hex(randomblob(16)))), kind TEXT NOT NULL, occurred_at REAL NOT NULL, card_id TEXT NOT NULL, item_id TEXT, deck_id TEXT, template_id TEXT, memory BLOB, suspended INTEGER NOT NULL);",
        "CREATE TABLE IF NOT EXISTS statistics_metadata(key TEXT PRIMARY KEY, value REAL NOT NULL);",
        "INSERT OR IGNORE INTO statistics_metadata VALUES ('started', CAST(strftime('%s','now') AS REAL));",
    ]
    static var statisticsTriggerStatements: [String] {
        let now =
            "COALESCE((SELECT occurred_at FROM api_transaction_context WHERE singleton = 1), CAST(strftime('%s','now') AS REAL))"
        return [
            """
            CREATE TRIGGER IF NOT EXISTS statistics_card_insert AFTER INSERT ON cards BEGIN
              INSERT INTO statistics_changes(kind,occurred_at,card_id,item_id,deck_id,template_id,memory,suspended)
              VALUES ('created',\(now),NEW.id,NEW.item_id,NEW.deck_id,NEW.template_id,NEW.memory,NEW.is_suspended);
            END;
            """,
            """
            CREATE TRIGGER IF NOT EXISTS statistics_card_update AFTER UPDATE ON cards
            WHEN NEW.memory != OLD.memory OR NEW.is_suspended != OLD.is_suspended OR NEW.deck_id IS NOT OLD.deck_id BEGIN
              INSERT INTO statistics_changes(kind,occurred_at,card_id,item_id,deck_id,template_id,memory,suspended)
              VALUES (CASE WHEN NEW.scheduling_history_origin IS NOT OLD.scheduling_history_origin THEN 'reset' ELSE 'state' END,
                \(now),NEW.id,NEW.item_id,NEW.deck_id,NEW.template_id,NEW.memory,NEW.is_suspended);
            END;
            """,
            """
            CREATE TRIGGER IF NOT EXISTS statistics_review_revert AFTER INSERT ON review_reverts BEGIN
              INSERT OR IGNORE INTO statistics_events(id,kind,occurred_at,card_id,payload)
              SELECT 'reverted:'||NEW.review_log_id,'reverted',NEW.reverted_at,r.card_id,
                CAST(json_object('id','reverted:'||NEW.review_log_id,'kind','reverted',
                  'occurredAt',NEW.reverted_at-978307200,'cardID',r.card_id,
                  'templateID',NEW.review_log_id,'suspended',json('false')) AS BLOB)
              FROM review_logs r WHERE r.id=NEW.review_log_id;
            END;
            """,
            """
            CREATE TRIGGER IF NOT EXISTS statistics_card_delete BEFORE DELETE ON cards BEGIN
              INSERT INTO statistics_changes(kind,occurred_at,card_id,item_id,deck_id,template_id,memory,suspended)
              VALUES ('deleted',\(now),OLD.id,OLD.item_id,OLD.deck_id,OLD.template_id,OLD.memory,OLD.is_suspended);
            END;
            """,
        ]
    }
}

struct StatisticsDatabaseCache {
    var eventSequence: Int64 = 0
    var segmentSequence: Int64 = 0
    var events: [StatisticsEvent] = []
    var segments: [LearningTimeSegment] = []
}

extension SQLiteDatabase {
    func saveStatisticsEvents(_ events: [StatisticsEvent]) throws {
        // Caller transactions encompass grading and evidence; inbound pages are
        // also atomic. An independently synced undo can arrive before its review.
        try inStatisticsTransaction {
            for event in events {
                guard event.occurredAt.timeIntervalSince1970.isFinite,
                    [
                        "review", "undo", "context", "created", "state", "reset", "deleted", "baseline",
                        "legacyExcluded", "alias", "submission", "reverted", "preservedDeletion",
                    ].contains(event.kind),
                    event.log.map({ $0.cardID == event.cardID && "review:" + $0.id.uuidString == event.id })
                        ?? true,
                    event.promptMilliseconds.map({ $0 >= 0 }) ?? true,
                    event.answerMilliseconds.map({ $0 >= 0 }) ?? true
                else { throw DatabaseError.invalidItem("Invalid statistics evidence.") }
                if let row = try query(
                    "SELECT payload FROM statistics_events WHERE id = ?;", bindings: [.text(event.id)]
                ).first,
                    let data = payload(row, "payload")
                {
                    let prior = try JSONDecoder().decode(StatisticsEvent.self, from: data)
                    // Snapshots derived on an older receiving device can lack
                    // source context. The review identity/outcome is invariant.
                    guard prior.kind == event.kind, prior.cardID == event.cardID,
                        prior.log == event.log, event.kind != "alias" || prior.itemID == event.itemID
                    else { throw DatabaseError.idempotencyConflict }
                    if prior.kind == "review", prior.sessionID == nil, event.sessionID != nil {
                        var context = event
                        context.id = "context:" + (event.log?.id.uuidString ?? event.id)
                        context.kind = "context"
                        context.log = nil
                        try saveStatisticsEvents([context])
                    }
                    continue
                }
                try execute(
                    "INSERT INTO statistics_events(id,kind,occurred_at,card_id,payload) VALUES (?,?,?,?,?);",
                    bindings: [
                        .text(event.id), .text(event.kind), .double(event.occurredAt.timeIntervalSince1970),
                        .text(event.cardID.uuidString),
                        .blob(try JSONEncoder().encode(event)),
                    ])
            }
        }
    }

    // SQL transaction control stays within the database actor. Nested native
    // writes share their parent's transaction rather than committing it early.
    private func inStatisticsTransaction<T>(_ body: () throws -> T) throws -> T {
        try inTransaction(body)
    }

    func recordStatisticsReview(_ log: ReviewLog, before: MemoryState?) throws {
        let card = try fetchCard(id: log.cardID)
        let item = try card.flatMap { try fetchItem(id: $0.itemID) }
        let audit = log.schedulingAudit
        let type = try item.flatMap { try fetchItemType(id: $0.item.itemTypeID) }
        let template = type?.templates.first { $0.id == card?.templateID }
        let skill = audit?.skillAtReview ?? card?.skill
        let capture = StatisticsCapture.context
        let normalized = ReviewLog(
            id: log.id, cardID: log.cardID, reviewedAt: log.reviewedAt, rating: log.rating,
            elapsedDays: log.elapsedDays, scheduledDays: log.scheduledDays, phaseBefore: log.phaseBefore,
            durationMs: log.durationMs, schedulingAudit: audit)
        try saveStatisticsEvents([
            StatisticsEvent(
                id: "review:" + log.id.uuidString, kind: "review", occurredAt: log.reviewedAt,
                cardID: log.cardID, itemID: card?.itemID, deckID: audit?.deckIDAtReview ?? card?.deckID,
                itemTypeID: audit?.itemTypeIDAtReview ?? type?.id,
                templateID: audit?.templateIDAtReview ?? card?.templateID,
                skill: skill.map {
                    "\($0.input.rawValue) → \($0.output.rawValue) · \($0.operation.rawValue)"
                }, interaction: template?.interaction.rawValue,
                log: normalized, memoryBefore: before, memoryAfter: audit?.memoryAfter,
                sourceLibraryID: try getOrCreateLibraryID(), sessionID: capture?.sessionID,
                deviceID: capture?.deviceID,
                promptMilliseconds: capture?.promptMilliseconds,
                answerMilliseconds: capture?.answerMilliseconds, checkedCorrect: capture?.checkedCorrect)
        ])
    }

    /// A resumable page yields the database actor between batches. Migration
    /// preserves optional legacy evidence without loading content per review.
    func backfillStatisticsPage() throws -> Bool {
        if !(try query("SELECT value FROM statistics_metadata WHERE key='backfilled';")).isEmpty {
            return false
        }
        return try inStatisticsTransaction {
            if (try query("SELECT value FROM statistics_metadata WHERE key='backfill_cursor';")).isEmpty {
                try execute(
                    """
                    INSERT OR IGNORE INTO statistics_events(id,kind,occurred_at,card_id,payload)
                    SELECT 'legacy:'||r.id,'legacyExcluded',r.reviewed_at,r.card_id,
                      CAST(json_object('id','legacy:'||r.id,'kind','legacyExcluded',
                        'occurredAt',r.reviewed_at-978307200,'cardID',r.card_id,
                        'templateID',r.id,'suspended',json('false')) AS BLOB)
                    FROM review_logs r JOIN review_reverts v ON v.review_log_id=r.id
                    WHERE NOT EXISTS(SELECT 1 FROM statistics_events e WHERE e.id='review:'||r.id);
                    """)
                try execute("INSERT INTO statistics_metadata VALUES ('backfill_cursor',0);")
            }
            let cursor =
                (try query("SELECT value FROM statistics_metadata WHERE key='backfill_cursor';").first?[
                    "value"] as? Double) ?? 0
            let rows = try query(
                "SELECT sequence FROM review_logs WHERE sequence > ? ORDER BY sequence LIMIT 1000;",
                bindings: [.int(Int64(cursor))])
            guard let last = rows.last?["sequence"] as? Int64 else {
                try execute(
                    "INSERT INTO statistics_changes(kind,occurred_at,card_id,item_id,deck_id,template_id,memory,suspended) SELECT 'baseline',(SELECT value FROM statistics_metadata WHERE key='started'),id,item_id,deck_id,template_id,memory,is_suspended FROM cards;"
                )
                try execute("INSERT INTO statistics_metadata VALUES ('backfilled',1);")
                return false
            }
            let libraryID = try getOrCreateLibraryID().uuidString
            try execute(
                """
                INSERT OR IGNORE INTO statistics_events(id,kind,occurred_at,card_id,payload)
                SELECT 'review:'||r.id,'review',r.reviewed_at,r.card_id,
                  CAST(json_object('id','review:'||r.id,'kind','review',
                    'occurredAt',r.reviewed_at-978307200,'cardID',r.card_id,
                    'itemID',c.item_id,'deckID',COALESCE(json_extract(CAST(r.scheduling_audit AS TEXT),'$.deckIDAtReview'),c.deck_id),
                    'itemTypeID',COALESCE(json_extract(CAST(r.scheduling_audit AS TEXT),'$.itemTypeIDAtReview'),i.item_type_id),
                    'templateID',COALESCE(json_extract(CAST(r.scheduling_audit AS TEXT),'$.templateIDAtReview'),c.template_id),
                    'log',json_remove(CAST(r.log AS TEXT),'$.sequence'),
                    'memoryBefore',json(CAST(r.memory_before AS TEXT)),
                    'memoryAfter',json(CAST(r.memory_after AS TEXT)),
                    'skill',COALESCE(json_extract(CAST(r.scheduling_audit AS TEXT),'$.skillAtReview.input'),json_extract(CAST(c.skill AS TEXT),'$.input'))||' → '||
                        COALESCE(json_extract(CAST(r.scheduling_audit AS TEXT),'$.skillAtReview.output'),json_extract(CAST(c.skill AS TEXT),'$.output'))||' · '||
                        COALESCE(json_extract(CAST(r.scheduling_audit AS TEXT),'$.skillAtReview.operation'),json_extract(CAST(c.skill AS TEXT),'$.operation')),
                    'interaction',(SELECT json_extract(value,'$.interaction') FROM json_each(CAST(t.definition AS TEXT),'$.templates') WHERE json_extract(value,'$.id')=c.template_id LIMIT 1),
                    'sourceLibraryID',?,'suspended',json('false')) AS BLOB)
                FROM review_logs r LEFT JOIN cards c ON c.id=r.card_id
                LEFT JOIN items i ON i.id=c.item_id LEFT JOIN item_types t ON t.id=i.item_type_id
                WHERE r.sequence > ? AND r.sequence <= ?;
                """, bindings: [.text(libraryID), .int(Int64(cursor)), .int(last)])
            try execute(
                "UPDATE statistics_metadata SET value=? WHERE key='backfill_cursor';",
                bindings: [.double(Double(last))])
            return true
        }
    }

    func prepareStatisticsEvidence() throws {
        while try backfillStatisticsPage() {}
        try inStatisticsTransaction {
            for row in try query("SELECT * FROM statistics_changes ORDER BY sequence;") {
                guard let eventID = row["event_id"] as? String, let kind = row["kind"] as? String,
                    let date = row["occurred_at"] as? Double, let text = row["card_id"] as? String,
                    let cardID = UUID(uuidString: text)
                else { throw DatabaseError.decodingFailed }
                func uuid(_ key: String) -> UUID? { (row[key] as? String).flatMap(UUID.init(uuidString:)) }
                let event = StatisticsEvent(
                    id: "state:" + eventID, kind: kind, occurredAt: Date(timeIntervalSince1970: date),
                    cardID: cardID,
                    itemID: uuid("item_id"), deckID: uuid("deck_id"), templateID: uuid("template_id"),
                    memoryAfter: try payload(row, "memory").map {
                        try JSONDecoder().decode(MemoryState.self, from: $0)
                    }, suspended: (row["suspended"] as? Int64) == 1)
                try saveStatisticsEvents([event])
            }
            try execute("DELETE FROM statistics_changes;")
        }
    }

    func statisticsEvents(after cursor: Int64, limit: Int) throws -> [StatisticsStoredEvent] {
        guard cursor >= 0, (1...1000).contains(limit) else {
            throw DatabaseError.queryFailed("Invalid statistics cursor.")
        }
        try prepareStatisticsEvidence()
        return try query(
            "SELECT sequence,payload FROM statistics_events WHERE sequence > ? ORDER BY sequence LIMIT ?;",
            bindings: [.int(cursor), .int(Int64(limit))]
        ).map {
            guard let seq = $0["sequence"] as? Int64, let data = payload($0, "payload") else {
                throw DatabaseError.decodingFailed
            }
            return StatisticsStoredEvent(
                sequence: seq, event: try JSONDecoder().decode(StatisticsEvent.self, from: data))
        }
    }

    func statisticsRevision() throws -> String {
        let tables = ["statistics_events", "statistics_changes", "learning_time_segments"]
        let values = try tables.map { table in
            (try query("SELECT COALESCE(MAX(sequence),0) AS value FROM \(table);").first?["value"] as? Int64)
                ?? 0
        }
        return "\(try currentChangeCursor()):\(values)"
    }

    func statisticsSource() throws -> StatisticsSource {
        try prepareStatisticsEvidence()
        while true {
            let page = try statisticsEvents(after: statisticsCache.eventSequence, limit: 1000)
            guard let last = page.last else { break }
            statisticsCache.events.append(contentsOf: page.map(\.event))
            statisticsCache.eventSequence = last.sequence
        }
        while true {
            let page = try learningTimeSegments(after: statisticsCache.segmentSequence, limit: 1000)
            guard let last = page.last else { break }
            statisticsCache.segments.append(contentsOf: page.map(\.segment))
            statisticsCache.segmentSequence = last.sequence
        }
        let decks = try fetchAllDecks()
        let items = try query("SELECT id,deck_id,item_type_id FROM items;")
        var itemDecks: [UUID: UUID] = [:]
        var types: [UUID: UUID] = [:]
        var live: Set<UUID> = []
        for row in items {
            guard let id = (row["id"] as? String).flatMap(UUID.init(uuidString:)),
                let type = (row["item_type_id"] as? String).flatMap(UUID.init(uuidString:))
            else { continue }
            live.insert(id)
            types[id] = type
            itemDecks[id] = (row["deck_id"] as? String).flatMap(UUID.init(uuidString:))
        }
        let itemTypes = try fetchAllItemTypes()
        let templates = itemTypes.flatMap(\.templates)
        let templateLookup = Dictionary(
            templates.map { ($0.id, $0.interaction.rawValue) }, uniquingKeysWith: { a, _ in a })
        let preset = try fetchSchedulerPreset(id: SchedulerPersistenceConstants.sharedPresetID)
        let parameterSets = Dictionary(uniqueKeysWithValues: try fetchFSRSParameterSets().map { ($0.id, $0) })
        let assignments = try fetchSchedulerCardHistories()
        let cohorts = Dictionary(uniqueKeysWithValues: try fetchSchedulerCohorts().map { ($0.id, $0) })
        let global = cohorts[SchedulerPersistenceConstants.globalCohortID]?.activeParameterSetID
        let allCards = try fetchAllCards()
        let maturity = try maturityStatuses(ids: Set(allCards.map(\.id)))
        let relations = try studyRelations(itemIDs: Set(allCards.map(\.itemID)))
        let cards = allCards.compactMap { card -> StatisticsCard? in
            guard let type = types[card.itemID] else { return nil }
            let weights =
                card.memoryParameterSetID.flatMap { parameterSets[$0]?.weights } ?? preset?
                .activeParameterSetID.flatMap { parameterSets[$0]?.weights }
                ?? FSRSScheduler.Parameters.defaultWeights
            let activeID =
                assignments[card.id].flatMap { cohorts[$0.cohortID]?.activeParameterSetID } ?? global
                ?? preset?.activeParameterSetID
            let futureWeights =
                activeID.flatMap { parameterSets[$0]?.weights } ?? FSRSScheduler.Parameters.defaultWeights
            return StatisticsCard(
                card: card, itemTypeID: type, interaction: templateLookup[card.templateID] ?? "Unknown",
                maintaining: maturity[card.id] == .maintaining,
                parameters: .init(
                    weights: weights, requestRetention: preset?.desiredRetention ?? 0.9,
                    maximumInterval: preset?.maximumIntervalDays ?? 36500),
                newCardsPerDay: decks.first { $0.id == card.deckID }?.newCardsPerDay,
                forecastParameters: .init(
                    weights: futureWeights, requestRetention: preset?.desiredRetention ?? 0.9,
                    maximumInterval: preset?.maximumIntervalDays ?? 36500),
                orderedWork: relations[card.itemID]?.work != nil)
        }
        let deleted = Set(
            try query(
                "SELECT resource_id FROM resource_revisions WHERE resource_type='item' AND is_deleted=1;"
            ).compactMap { ($0["resource_id"] as? String).flatMap(UUID.init(uuidString:)) })
        let introductions = try query(
            "SELECT DISTINCT review_logs.card_id, new_card_introductions.deck_id, new_card_introductions.study_day FROM new_card_introductions JOIN review_logs ON review_logs.id=new_card_introductions.review_log_id;"
        ).compactMap { row -> StatisticsIntroduction? in
            guard let card = (row["card_id"] as? String).flatMap(UUID.init(uuidString:)),
                let day = row["study_day"] as? String
            else { return nil }
            return .init(
                cardID: card, deckID: (row["deck_id"] as? String).flatMap(UUID.init(uuidString:)),
                studyDay: day)
        }
        return StatisticsSource(
            introductions: introductions, events: statisticsCache.events, segments: statisticsCache.segments,
            cards: cards, decks: decks, itemDecks: itemDecks,
            liveItems: live, deletedItems: deleted, aliases: try learningTimeItemAliases(),
            trackingStartedAt: (try query("SELECT value FROM statistics_metadata WHERE key='started';")
                .first?["value"] as? Double).map(Date.init(timeIntervalSince1970:)),
            rollover: Int(try metadataValue(forKey: "study_day_rollover_minutes") ?? "")
                ?? StudyDay.defaultRolloverMinutes,
            itemTypeNames: Dictionary(uniqueKeysWithValues: itemTypes.map { ($0.id, $0.name) }),
            templateNames: Dictionary(templates.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }))
    }
}

extension ItemStore {
    public func statisticsRevision() async throws -> String { try await database.statisticsRevision() }
    public func statisticsSource() async throws -> StatisticsSource {
        while try await database.backfillStatisticsPage() {
            try Task.checkCancellation()
            await Task.yield()
        }
        var source = try await database.statisticsSource()
        let stale = source.cards.filter {
            $0.card.memory.reps > 0 && $0.parameters.weights != $0.forecastParameters?.weights
        }
        if !stale.isEmpty {
            let logs = Dictionary(grouping: try await database.fetchActiveReviewLogs(), by: \.cardID)
            source.cards = source.cards.map { entry in
                var result = entry
                if entry.card.memory.reps > 0, let parameters = entry.forecastParameters,
                    entry.parameters.weights != parameters.weights
                {
                    var memory =
                        replayMemory(
                            card: entry.card, logs: logs[entry.card.id, default: []], parameters: parameters)
                        ?? .new(due: entry.card.memory.due)
                    memory.due = entry.card.memory.due
                    result.forecastMemory = memory
                }
                return result
            }
        }
        return source
    }
    public func statisticsEvents(after cursor: Int64, limit: Int = 500) async throws
        -> [StatisticsStoredEvent]
    {
        while try await database.backfillStatisticsPage() {
            try Task.checkCancellation()
            await Task.yield()
        }
        return try await database.statisticsEvents(after: cursor, limit: limit)
    }
    public func recordStatisticsEvents(_ events: [StatisticsEvent]) async throws {
        try await database.saveStatisticsEvents(events)
    }
}
