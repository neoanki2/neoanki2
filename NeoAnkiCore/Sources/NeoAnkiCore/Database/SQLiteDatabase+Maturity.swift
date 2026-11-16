import Foundation

extension SQLiteDatabase {
    func maturityStatuses(ids: Set<UUID>) throws -> [UUID: CardMaturityStatus] {
        try inReadTransaction {
            try refreshMaturityProjection()
            let missing = ids.filter { maturityProjection.entries[$0] == nil }
            if !missing.isEmpty {
                for entry in try readMaturityEntries(ids: Set(missing)) { maturityProjection.put(entry) }
            }
            return ids.reduce(into: [:]) { result, id in
                result[id] = maturityProjection.entries[id]?.detail.status
            }
        }
    }

    func maturityDetails(itemID: UUID) throws -> [CardMaturityDetail] {
        try inReadTransaction {
            let ids = Set(try query("SELECT id FROM cards WHERE item_id = ?;", bindings: [.text(itemID.uuidString)])
                .compactMap { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) })
            // Calls the same scoped evaluator/predicate as the card endpoint.
            try refreshMaturityProjection()
            let missing = ids.filter { maturityProjection.entries[$0] == nil }
            if !missing.isEmpty {
                for entry in try readMaturityEntries(ids: Set(missing)) { maturityProjection.put(entry) }
            }
            return ids.compactMap { maturityProjection.entries[$0]?.detail }
                .sorted { $0.id.uuidString < $1.id.uuidString }
        }
    }

    func maturityTotals() throws -> MaturityTotals {
        try inReadTransaction {
            try refreshMaturityProjection()
            if !maturityProjection.isComplete {
                var next = MaturityProjection(token: maturityProjection.token, cursor: maturityProjection.cursor, isComplete: true)
                let evidence = try readMaturityEvidence(ids: nil)
                try forEachRow(Self.maturityCardSQL + " ORDER BY id;") { row in
                    let card = try decodeCard(from: row)
                    maturityStatistics.decodedCards += 1
                    next.put(.init(card: card, evidence: evidence[card.id] ?? CardMaturityEvidence()))
                }
                maturityStatistics.aggregateRebuilds += 1
                maturityProjection = next
            }
            return MaturityTotals(directCounts: maturityProjection.directCounts)
        }
    }

    private static let maturityCardSQL = """
        SELECT id, item_id, template_id, skill, memory, is_suspended, deck_id, cloze_group, occlusion_group,
               memory_model_version, memory_parameter_set_id, scheduling_history_origin FROM cards
        """

    /// Review history is validated and folded while streaming. Scoped and full
    /// reads deliberately share reset-origin, revert and append-sequence rules.
    private func readMaturityEvidence(ids: Set<UUID>?) throws -> [UUID: CardMaturityEvidence] {
        let ordered = ids?.sorted { $0.uuidString < $1.uuidString }
        let filter = ordered.map { " AND review_logs.card_id IN (\(Array(repeating: "?", count: $0.count).joined(separator: ",")))" } ?? ""
        let sql = """
            SELECT review_logs.id, review_logs.card_id, review_logs.log, review_logs.sequence
            FROM review_logs
            JOIN cards ON cards.id = review_logs.card_id
            LEFT JOIN scheduler_card_history ON scheduler_card_history.card_id = cards.id
            LEFT JOIN review_reverts ON review_reverts.review_log_id = review_logs.id
            WHERE review_reverts.id IS NULL
              AND (COALESCE(scheduler_card_history.history_origin, cards.scheduling_history_origin) IS NULL
                   OR review_logs.reviewed_at >= COALESCE(scheduler_card_history.history_origin, cards.scheduling_history_origin))
            \(filter)
            ORDER BY review_logs.reviewed_at, review_logs.sequence;
            """
        var evidence: [UUID: CardMaturityEvidence] = [:]
        try forEachRow(sql, bindings: ordered?.map { .text($0.uuidString) } ?? []) { row in
            let id = (row["id"] as? String).flatMap(UUID.init(uuidString:))
            guard let bytes = payload(row, "log"), let sequence = row["sequence"] as? Int64,
                  let log = try? JSONDecoder().decode(ReviewLog.self, from: bytes),
                  log.id == id, log.cardID == (row["card_id"] as? String).flatMap(UUID.init(uuidString:)) else {
                throw MaturityReadError.invalidReview(id)
            }
            maturityStatistics.decodedReviews += 1
            evidence[log.cardID, default: CardMaturityEvidence()].observe(log.withSequence(sequence))
        }
        return evidence
    }

    private func readMaturityEntries(ids: Set<UUID>) throws -> [MaturityProjection.Entry] {
        // Bound variable bindings without imposing a new public selection limit.
        let ordered = ids.sorted { $0.uuidString < $1.uuidString }
        var entries: [MaturityProjection.Entry] = []
        for start in stride(from: 0, to: ordered.count, by: 500) {
            let batch = Array(ordered[start..<min(start + 500, ordered.count)])
            let evidence = try readMaturityEvidence(ids: Set(batch))
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            try forEachRow(Self.maturityCardSQL + " WHERE id IN (\(placeholders));", bindings: batch.map { .text($0.uuidString) }) { row in
                let card = try decodeCard(from: row)
                maturityStatistics.decodedCards += 1
                entries.append(.init(card: card, evidence: evidence[card.id] ?? CardMaturityEvidence()))
            }
        }
        return entries
    }

    private func refreshMaturityProjection() throws {
        let token = try cacheToken()
        let cursor = try currentChangeCursor()
        guard maturityProjection.token != token else { return }
        let previousCursor = maturityProjection.cursor
        guard let oldToken = maturityProjection.token, oldToken.dataVersion == token.dataVersion,
              previousCursor <= cursor,
              let oldest = try oldestChangeCursor(), oldest <= previousCursor + 1,
              cursor > previousCursor else {
            maturityProjection = MaturityProjection(token: token, cursor: cursor)
            return
        }
        var affected: Set<UUID> = []
        var changedItems: Set<UUID> = []
        var pageCursor = previousCursor
        while pageCursor < cursor {
            let page = try fetchLibraryChanges(after: pageCursor, limit: 1_000)
            guard let last = page.last else {
                maturityProjection = MaturityProjection(token: token, cursor: cursor); return
            }
            for change in page where change.cursor <= cursor {
                switch change.resourceKind {
                case .card:
                    guard let id = UUID(uuidString: change.resourceID) else { throw DatabaseError.decodingFailed }
                    affected.insert(id)
                case .item:
                    if let id = UUID(uuidString: change.resourceID) { changedItems.insert(id) }
                case .review, .reviewRevert:
                    let sql = change.resourceKind == .review
                        ? "SELECT card_id FROM review_logs WHERE id = ?;"
                        : "SELECT review_logs.card_id FROM review_reverts JOIN review_logs ON review_logs.id = review_reverts.review_log_id WHERE review_reverts.id = ?;"
                    guard let text = try query(sql, bindings: [.text(change.resourceID)]).first?["card_id"] as? String,
                          let id = UUID(uuidString: text) else {
                        maturityProjection = MaturityProjection(token: token, cursor: cursor); return
                    }
                    affected.insert(id)
                case .deck, .media, .studyResponse, .itemTypeMembership, .portableTypeMapping, .schedulingSettings:
                    // Membership, names, settings and media do not alter the
                    // persisted memory/evidence that defines maturity. Any
                    // resulting card mutation has its own journal record.
                    break
                case .library, .itemType, nil:
                    maturityProjection = MaturityProjection(token: token, cursor: cursor); return
                }
            }
            pageCursor = last.cursor
        }
        for itemID in changedItems {
            for entry in maturityProjection.entries.values where entry.itemID == itemID { affected.insert(entry.detail.id) }
            for row in try query("SELECT id FROM cards WHERE item_id = ?;", bindings: [.text(itemID.uuidString)]) {
                if let text = row["id"] as? String, let id = UUID(uuidString: text) { affected.insert(id) }
            }
        }
        // Validate all replacement evidence before changing cached values. A
        // failed read leaves the preceding complete projection intact.
        let updated = try readMaturityEntries(ids: affected)
        for id in affected { maturityProjection.remove(id) }
        for entry in updated { maturityProjection.put(entry) }
        maturityProjection.token = token
        maturityProjection.cursor = cursor
    }
}
