import CryptoKit
import Foundation

public extension ItemStore {
    func createVocabularySet(_ draft: VocabularySetDraft, id: UUID = UUID(), now: Date = .now) async throws -> UUID {
        let item = try VocabularySet.makeItem(draft, id: id)
        try await database.insertVocabularySet(item, now: now)
        return id
    }

    /// Statuses for terms that have a judgment or cards. `expression` filters by match key.
    func vocabularyStatuses(language: String? = nil, expression: String? = nil) async throws -> [VocabularyStatus] {
        try await database.vocabularyStatuses(language: language.map(VocabularyTerm.languageCode), expression: expression)
    }

    /// A compact, versioned view of one language for highlighting text.
    func vocabularySnapshot(language: String) async throws -> VocabularySnapshot {
        try await database.vocabularySnapshot(language: VocabularyTerm.languageCode(language))
    }

    func setVocabularyJudgment(_ judgment: VocabularyJudgment, for term: VocabularyTerm,
                               changeID: UUID = UUID(), now: Date = .now) async throws -> VocabularyJudgmentChange {
        try await database.setVocabularyJudgment(judgment, term: term.validated(), id: changeID, now: now)
    }

    /// Record many judgments in one transaction. Retrying the same `batchID` returns the first receipt.
    func setVocabularyJudgments(_ entries: [VocabularyJudgmentEntry], batchID: UUID = UUID(),
                                now: Date = .now) async throws -> VocabularyBatchReceipt {
        let validated = try entries.map { VocabularyJudgmentEntry(term: try $0.term.validated(), judgment: $0.judgment) }
        return try await database.setVocabularyJudgments(validated, batchID: batchID, now: now)
    }

    /// Restore, for every term the batch changed and nothing changed since, the judgment it replaced.
    func undoVocabularyBatch(_ batchID: UUID, undoID: UUID = UUID(), now: Date = .now) async throws -> VocabularyBatchReceipt {
        try await database.undoVocabularyBatch(batchID, undoID: undoID, now: now)
    }

    func mergeVocabularyJudgments(_ changes: [VocabularyJudgmentChange]) async throws {
        try await database.mergeVocabularyJudgments(changes.map { ($0, nil) })
    }

    /// Merge synchronized judgment records, keeping each payload byte-for-byte so data written by a
    /// newer release survives on this device until it understands it.
    func mergeVocabularyJudgmentPayloads(_ payloads: [Data]) async throws {
        let decoder = JSONDecoder()
        let changes = try payloads.map { data -> (VocabularyJudgmentChange, Data?) in
            (try decoder.decode(VocabularyJudgmentChange.self, from: data), data)
        }
        try await database.mergeVocabularyJudgments(changes)
    }

    func vocabularyNotifications() async -> AsyncStream<Void> {
        await database.vocabularyNotifications()
    }

    func vocabularyJudgments(after sequence: Int64, limit: Int) async throws -> [VocabularyJudgmentPageRow] {
        try await database.vocabularyJudgments(after: sequence, limit: limit)
    }
}

public struct VocabularyJudgmentPageRow: Sendable {
    public let sequence: Int64
    public let change: VocabularyJudgmentChange
}

/// The largest bulk judgment accepted in one transaction.
public let maximumVocabularyBatchSize = 20_000

extension SQLiteDatabase {
    func vocabularyNotifications() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            vocabularyObservers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeVocabularyObserver(id) }
            }
        }
    }

    private func removeVocabularyObserver(_ id: UUID) { vocabularyObservers.removeValue(forKey: id) }

    private func publishVocabularyChange() {
        for observer in vocabularyObservers.values { observer.yield() }
    }

    func insertVocabularySet(_ item: Item, now: Date) throws {
        let type = VocabularySet.itemType
        try inTransaction(recordNativeCommand: true, affectedCount: 1) {
            if let existing = try fetchItem(id: item.id) {
                guard existing.item == item else { throw VocabularySetError.idConflict }
                return
            }
            if let deckID = item.deckID, try fetchDeck(id: deckID) == nil {
                throw DatabaseError.deckNotFound(deckID)
            }
            if let existing = try fetchItemType(id: type.id) {
                guard existing == type else { throw VocabularySetError.changedPreset }
            } else {
                try ItemTypeValidation.validate(type)
                try createScopedType(type, deckID: nil, shared: false)
            }
            let cards = CardGenerator.cards(for: item, type: type, now: now, deterministicIDs: true)
            try insertItemWithCards(item, cards: cards, createdAt: now, updatedAt: now)
            for card in cards { _ = try ensureSchedulerCardHistory(cardID: card.id, now: now) }
        }
    }

    func vocabularyReview(_ log: ReviewLog) throws -> ReviewLog {
        guard let card = try fetchCard(id: log.cardID),
              card.templateID == VocabularySet.readingID || card.templateID == VocabularySet.productionID,
              let item = try fetchItem(id: card.itemID)?.item,
              let type = try fetchValidatedItemType(id: item.itemTypeID),
              let fingerprint = VocabularySet.prompt(for: card, item: item, type: type) else { return log }
        return log.withVocabularyPrompt(fingerprint)
    }

    // MARK: - Statuses

    func vocabularyStatuses(language: String?, expression: String? = nil) throws -> [VocabularyStatus] {
        try allVocabularyStatuses().filter { status in
            guard language == nil || status.term.language == language else { return false }
            guard let expression else { return true }
            return status.term.matchKey == VocabularyTerm.matchKey(expression, language: status.term.language)
        }
    }

    func vocabularySnapshot(language: String) throws -> VocabularySnapshot {
        VocabularySnapshot(language: language, statuses: try allVocabularyStatuses())
    }

    /// Every status, computed in a few bounded queries and reused until the database changes.
    private func allVocabularyStatuses() throws -> [VocabularyStatus] {
        let token = try cacheToken()
        if let cached = vocabularyStatusCache, cached.token == token { return cached.statuses }
        // Take the token inside the read snapshot so a concurrent writer cannot pair stale rows with it.
        let (computedToken, statuses) = try inReadTransaction { (try cacheToken(), try computeVocabularyStatuses()) }
        vocabularyStatusCache = (computedToken, statuses)
        return statuses
    }

    private func computeVocabularyStatuses() throws -> [VocabularyStatus] {
        var results: [String: VocabularyStatus] = [:]
        for change in try latestVocabularyJudgments() {
            results[change.term.id] = VocabularyStatus(term: change.term, judgment: change.judgment,
                                                       origin: change.origin, judgedAt: change.changedAt)
        }
        for evidence in try vocabularySetEvidence() {
            var result = results[evidence.term.id] ?? .init(term: evidence.term)
            if result.term.lemma == nil, evidence.term.lemma != nil {
                result = VocabularyStatus(term: evidence.term, judgment: result.judgment, origin: result.origin,
                                          judgedAt: result.judgedAt)
            }
            result.hasCards = result.hasCards || evidence.hasCards
            result.readingMature = result.readingMature || evidence.readingMature
            result.clozeMature = result.clozeMature || evidence.clozeMature
            results[evidence.term.id] = result
        }
        let visible = results.values.filter {
            $0.hasCards || $0.readingMature || $0.clozeMature || $0.explicitJudgment != nil
        }
        return VocabularyStatus.combiningExpressions(visible).sorted { $0.id < $1.id }
    }

    private func latestVocabularyJudgments() throws -> [VocabularyJudgmentChange] {
        try query("""
            SELECT change.payload FROM vocabulary_judgments AS change
            WHERE change.id = (
                SELECT latest.id FROM vocabulary_judgments AS latest WHERE latest.term_id = change.term_id
                ORDER BY latest.changed_at DESC, latest.id DESC LIMIT 1
            );
            """).map(decodeVocabularyJudgment)
    }

    private struct VocabularyEvidence {
        let term: VocabularyTerm
        var hasCards = false
        var readingMature = false
        var clozeMature = false
    }

    /// Review evidence from Vocabulary Set cards, for every set or only `only`. Suspended cards keep
    /// the evidence they earned but no longer count as being studied.
    private func vocabularySetEvidence(only: Item? = nil) throws -> [VocabularyEvidence] {
        guard let type = try fetchValidatedItemType(id: VocabularySet.typeID) else { return [] }
        let items: [Item]
        let cardRows: [[String: Any?]]
        let columns = """
            cards.id, cards.item_id, cards.template_id, cards.skill, cards.memory, cards.is_suspended,
            cards.deck_id, cards.cloze_group, cards.occlusion_group, cards.memory_model_version,
            cards.memory_parameter_set_id, cards.scheduling_history_origin
            """
        if let only {
            items = [only]
            cardRows = try query("SELECT \(columns) FROM cards WHERE cards.item_id = ?;",
                                 bindings: [.text(only.id.uuidString)])
        } else {
            let ids = Set(try query("SELECT id FROM items WHERE item_type_id = ?;", bindings: [.text(type.id.uuidString)])
                .compactMap { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) })
            guard !ids.isEmpty else { return [] }
            items = try fetchItems(ids: ids).map(\.item)
            cardRows = try query("""
                SELECT \(columns) FROM cards JOIN items ON items.id = cards.item_id WHERE items.item_type_id = ?;
                """, bindings: [.text(type.id.uuidString)])
        }
        let cardsByItem = Dictionary(grouping: try cardRows.map(decodeCard(from:)), by: \.itemID)

        struct Candidate { let card: Card; let fingerprint: String; let evidence: Int }
        var evidence: [VocabularyEvidence] = []
        var candidates: [Candidate] = []
        for item in items {
            guard let term = VocabularySet.term(in: item) else { continue }
            var row = VocabularyEvidence(term: term)
            for card in cardsByItem[item.id] ?? [] {
                guard let fingerprint = VocabularySet.prompt(for: card, item: item, type: type) else { continue }
                if !card.isSuspended { row.hasCards = true }
                guard card.memory.phase == .review, card.memory.stability.isFinite,
                      card.memory.stability >= CardMaturityStatus.maintainingStabilityDays else { continue }
                candidates.append(.init(card: card, fingerprint: fingerprint, evidence: evidence.count))
            }
            evidence.append(row)
        }
        let logs = try activeReviewLogs(cardIDs: candidates.map(\.card.id))
        for candidate in candidates {
            var card = candidate.card
            card.isSuspended = false
            let current = (logs[card.id] ?? []).reversed().prefix { $0.vocabularyPrompt == candidate.fingerprint }
            guard CardMaturityStatus.evaluate(card: card, reviews: Array(current)) == .maintaining else { continue }
            if card.templateID == VocabularySet.readingID { evidence[candidate.evidence].readingMature = true }
            if card.templateID == VocabularySet.productionID { evidence[candidate.evidence].clozeMature = true }
        }
        return evidence
    }

    /// Active review logs for several cards, ordered oldest first, with the same rules as
    /// `fetchActiveReviewLogs(cardID:)`.
    private func activeReviewLogs(cardIDs: [UUID]) throws -> [UUID: [ReviewLog]] {
        var result: [UUID: [ReviewLog]] = [:]
        let decoder = JSONDecoder()
        for start in stride(from: 0, to: cardIDs.count, by: 500) {
            let chunk = cardIDs[start..<min(start + 500, cardIDs.count)]
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let rows = try query("""
                SELECT review_logs.card_id, review_logs.log, review_logs.sequence
                FROM review_logs
                JOIN cards ON cards.id = review_logs.card_id
                LEFT JOIN review_reverts ON review_reverts.review_log_id = review_logs.id
                WHERE review_reverts.id IS NULL AND review_logs.card_id IN (\(placeholders))
                  AND (cards.scheduling_history_origin IS NULL
                       OR review_logs.reviewed_at >= cards.scheduling_history_origin)
                ORDER BY review_logs.reviewed_at ASC, review_logs.sequence ASC;
                """, bindings: chunk.map { .text($0.uuidString) })
            for row in rows {
                guard let cardID = (row["card_id"] as? String).flatMap(UUID.init(uuidString:)),
                      let data = payload(row, "log"), let sequence = row["sequence"] as? Int64,
                      let log = try? decoder.decode(ReviewLog.self, from: data) else { continue }
                result[cardID, default: []].append(log.withSequence(sequence))
            }
        }
        return result
    }

    // MARK: - Judgments

    func setVocabularyJudgment(_ judgment: VocabularyJudgment, term: VocabularyTerm,
                               id: UUID, now: Date) throws -> VocabularyJudgmentChange {
        guard VocabularyJudgment.recordable.contains(judgment) else { throw VocabularySetError.invalidJudgment }
        let result = try inTransaction {
            if let row = try query("SELECT payload FROM vocabulary_judgments WHERE id = ?;",
                                   bindings: [.text(id.uuidString)]).first {
                let existing = try decodeVocabularyJudgment(row)
                guard existing.term.id == term.id, existing.judgment == judgment else { throw VocabularySetError.idConflict }
                return existing
            }
            let change = VocabularyJudgmentChange(id: id, term: term, judgment: judgment,
                                                  changedAt: try nextJudgmentTime(for: term, now: now))
            try insertVocabularyJudgment(change, outbound: true)
            return change
        }
        publishVocabularyChange()
        return result
    }

    private func nextJudgmentTime(for term: VocabularyTerm, now: Date) throws -> Date {
        let latest = try query("""
            SELECT changed_at FROM vocabulary_judgments WHERE term_id = ?
            ORDER BY changed_at DESC, id DESC LIMIT 1;
            """, bindings: [.text(term.id)]).first?["changed_at"] as? Double
        return Date(timeIntervalSince1970: max(now.timeIntervalSince1970, (latest ?? 0) + 0.001))
    }

    /// Change IDs derive from the batch and term, so a retried batch cannot record twice.
    private func batchChangeID(_ batchID: UUID, _ term: VocabularyTerm) -> UUID {
        let seed = Data("vocabulary-batch\u{1F}\(batchID.uuidString)\u{1F}\(term.id)".utf8)
        var bytes = Array(SHA256.hash(data: seed).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private func batchChanges(_ batchID: UUID) throws -> [VocabularyJudgmentChange] {
        try query("""
            SELECT payload FROM vocabulary_judgments
            WHERE json_extract(CAST(payload AS TEXT), '$.batchID') = ? ORDER BY sequence;
            """, bindings: [.text(batchID.uuidString)]).map(decodeVocabularyJudgment)
    }

    func setVocabularyJudgments(_ entries: [VocabularyJudgmentEntry], batchID: UUID,
                                now: Date) throws -> VocabularyBatchReceipt {
        guard entries.count <= maximumVocabularyBatchSize else { throw VocabularySetError.batchTooLarge }
        guard entries.allSatisfy({ VocabularyJudgment.recordable.contains($0.judgment) }) else {
            throw VocabularySetError.invalidJudgment
        }
        let receipt = try inTransaction { () -> VocabularyBatchReceipt in
            let existing = try batchChanges(batchID)
            if !existing.isEmpty {
                return .init(batchID: batchID, recorded: existing.count, unchanged: 0, changes: existing)
            }
            let latest = Dictionary(try latestVocabularyJudgments().map { ($0.term.id, $0.judgment) },
                                    uniquingKeysWith: { first, _ in first })
            var seen: Set<String> = []
            var changes: [VocabularyJudgmentChange] = []
            var unchanged = 0
            for entry in entries {
                guard seen.insert(entry.term.id).inserted else { unchanged += 1; continue }
                let current = latest[entry.term.id]
                let same = current == entry.judgment || (entry.judgment == .reviewHistory && !(current?.isExplicit ?? false))
                if same { unchanged += 1; continue }
                let change = VocabularyJudgmentChange(id: batchChangeID(batchID, entry.term), term: entry.term,
                                                      judgment: entry.judgment,
                                                      changedAt: try nextJudgmentTime(for: entry.term, now: now),
                                                      batchID: batchID)
                try insertVocabularyJudgment(change, outbound: true)
                changes.append(change)
            }
            return .init(batchID: batchID, recorded: changes.count, unchanged: unchanged, changes: changes)
        }
        if receipt.recorded > 0 { publishVocabularyChange() }
        return receipt
    }

    func undoVocabularyBatch(_ batchID: UUID, undoID: UUID, now: Date) throws -> VocabularyBatchReceipt {
        let receipt = try inTransaction { () -> VocabularyBatchReceipt in
            let existing = try batchChanges(undoID)
            if !existing.isEmpty { return .init(batchID: undoID, recorded: existing.count, unchanged: 0, changes: existing) }
            let original = try batchChanges(batchID)
            guard !original.isEmpty else { throw VocabularySetError.batchNotFound }
            var changes: [VocabularyJudgmentChange] = []
            var unchanged = 0
            for change in original {
                let history = try query("""
                    SELECT payload FROM vocabulary_judgments WHERE term_id = ?
                    ORDER BY changed_at DESC, id DESC;
                    """, bindings: [.text(change.term.id)]).map(decodeVocabularyJudgment)
                // A later change by the learner wins over undoing an earlier bulk action.
                guard history.first?.id == change.id else { unchanged += 1; continue }
                let previous = history.dropFirst().first
                let judgment = previous?.judgment ?? .reviewHistory
                let restore = VocabularyJudgmentChange(
                    id: batchChangeID(undoID, change.term), term: change.term,
                    judgment: VocabularyJudgment.recordable.contains(judgment) ? judgment : .reviewHistory,
                    changedAt: try nextJudgmentTime(for: change.term, now: now), batchID: undoID,
                    origin: previous?.origin)
                try insertVocabularyJudgment(restore, outbound: true)
                changes.append(restore)
            }
            return .init(batchID: undoID, recorded: changes.count, unchanged: unchanged, changes: changes)
        }
        if receipt.recorded > 0 { publishVocabularyChange() }
        return receipt
    }

    func mergeVocabularyJudgments(_ changes: [(change: VocabularyJudgmentChange, payload: Data?)]) throws {
        try inTransaction {
            for (change, payload) in changes {
                guard try change.term.validated() == change.term, change.changedAt.timeIntervalSince1970.isFinite
                else { throw VocabularySetError.invalidTerm }
                try insertVocabularyJudgment(change, outbound: false, payload: payload)
            }
        }
        if !changes.isEmpty { publishVocabularyChange() }
    }

    func vocabularyJudgments(after sequence: Int64, limit: Int) throws -> [VocabularyJudgmentPageRow] {
        try query("""
            SELECT sequence, payload FROM vocabulary_judgments WHERE outbound = 1 AND sequence > ?
            ORDER BY sequence LIMIT ?;
            """, bindings: [.int(sequence), .int(Int64(limit))]).map { row in
            guard let sequence = row["sequence"] as? Int64 else { throw VocabularySetError.invalidTerm }
            return .init(sequence: sequence, change: try decodeVocabularyJudgment(row))
        }
    }

    /// Before deleting a Vocabulary Set, keep what its reviews showed. Without this, deleting a deck
    /// would silently forget words the learner demonstrably knows. Only this item's own evidence is
    /// read, so deleting a large deck stays linear.
    func archiveVocabularyEvidence(beforeDeleting item: Item, now: Date) throws {
        guard item.itemTypeID == VocabularySet.typeID,
              let evidence = try vocabularySetEvidence(only: item).first, evidence.readingMature else { return }
        let term = evidence.term
        if let latest = try query("""
            SELECT payload FROM vocabulary_judgments WHERE term_id = ? ORDER BY changed_at DESC, id DESC LIMIT 1;
            """, bindings: [.text(term.id)]).first, try decodeVocabularyJudgment(latest).judgment != .reviewHistory { return }
        let change = VocabularyJudgmentChange(id: UUID(), term: term, judgment: .known,
                                              changedAt: try nextJudgmentTime(for: term, now: now),
                                              origin: .archivedReviews)
        try insertVocabularyJudgment(change, outbound: true)
        publishVocabularyChange()
    }

    private func insertVocabularyJudgment(_ change: VocabularyJudgmentChange, outbound: Bool, payload: Data? = nil) throws {
        try execute("""
            INSERT INTO vocabulary_judgments (id, term_id, language, changed_at, outbound, payload)
            VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO NOTHING;
            """, bindings: [.text(change.id.uuidString), .text(change.term.id), .text(change.term.language),
                            .double(change.changedAt.timeIntervalSince1970), .int(outbound ? 1 : 0),
                            .blob(try payload ?? JSONEncoder().encode(change))])
    }

    private func decodeVocabularyJudgment(_ row: [String: Any?]) throws -> VocabularyJudgmentChange {
        guard let bytes = payload(row, "payload") else { throw VocabularySetError.invalidTerm }
        return try JSONDecoder().decode(VocabularyJudgmentChange.self, from: bytes)
    }
}
