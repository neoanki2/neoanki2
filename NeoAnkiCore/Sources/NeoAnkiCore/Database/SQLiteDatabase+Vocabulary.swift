import Foundation

public extension ItemStore {
    func createVocabularySet(_ draft: VocabularySetDraft, id: UUID = UUID(), now: Date = .now) async throws -> UUID {
        let item = try VocabularySet.makeItem(draft, id: id)
        try await database.insertVocabularySet(item, now: now)
        return id
    }

    func vocabularyStatuses(language: String? = nil) async throws -> [VocabularyStatus] {
        try await database.vocabularyStatuses(language: language.map(VocabularyTerm.languageCode))
    }

    func setVocabularyJudgment(_ judgment: VocabularyJudgment, for term: VocabularyTerm,
                               changeID: UUID = UUID(), now: Date = .now) async throws -> VocabularyJudgmentChange {
        try await database.setVocabularyJudgment(judgment, term: term.validated(), id: changeID, now: now)
    }

    func mergeVocabularyJudgments(_ changes: [VocabularyJudgmentChange]) async throws {
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

    func vocabularyStatuses(language: String?) throws -> [VocabularyStatus] {
        try inReadTransaction {
            var results: [String: VocabularyStatus] = [:]
            let filter = language == nil ? "" : "AND change.language = ?"
            let changes = try query("""
                SELECT change.payload FROM vocabulary_judgments AS change
                WHERE change.id = (
                    SELECT latest.id FROM vocabulary_judgments AS latest WHERE latest.term_id = change.term_id
                    ORDER BY latest.changed_at DESC, latest.id DESC LIMIT 1
                ) \(filter);
                """, bindings: language.map { [.text($0)] } ?? [])
            for row in changes {
                let change = try decodeVocabularyJudgment(row)
                results[change.term.id] = VocabularyStatus(term: change.term, judgment: change.judgment)
            }
            if let type = try fetchValidatedItemType(id: VocabularySet.typeID) {
                let ids = try query("SELECT id FROM items WHERE item_type_id = ?;",
                                    bindings: [.text(type.id.uuidString)])
                for row in ids {
                    guard let id = (row["id"] as? String).flatMap(UUID.init(uuidString:)),
                          let item = try fetchItem(id: id)?.item, let term = VocabularySet.term(in: item),
                          language == nil || term.language == language else { continue }
                    var result = results[term.id] ?? .init(term: term, judgment: nil)
                    for card in try fetchCards(for: id) where !card.isSuspended {
                        guard let fingerprint = VocabularySet.prompt(for: card, item: item, type: type) else { continue }
                        result.hasCards = true
                        guard card.memory.phase == .review,
                              card.memory.stability >= CardMaturityStatus.maintainingStabilityDays else { continue }
                        let logs = try fetchActiveReviewLogs(cardID: card.id)
                        let current = logs.reversed().prefix { $0.vocabularyPrompt == fingerprint }
                        let mature = CardMaturityStatus.evaluate(card: card, reviews: Array(current)) == .maintaining
                        if card.templateID == VocabularySet.readingID { result.readingMature = result.readingMature || mature }
                        if card.templateID == VocabularySet.productionID { result.clozeMature = result.clozeMature || mature }
                    }
                    results[term.id] = result
                }
            }
            return results.values.filter { $0.hasCards || $0.judgment == .known || $0.judgment == .unfamiliar }
                .sorted { $0.id < $1.id }
        }
    }

    func setVocabularyJudgment(_ judgment: VocabularyJudgment, term: VocabularyTerm,
                               id: UUID, now: Date) throws -> VocabularyJudgmentChange {
        let result = try inTransaction {
            if let row = try query("SELECT payload FROM vocabulary_judgments WHERE id = ?;",
                                   bindings: [.text(id.uuidString)]).first {
                let existing = try decodeVocabularyJudgment(row)
                guard existing.term.id == term.id, existing.judgment == judgment else { throw VocabularySetError.idConflict }
                return existing
            }
            let latest = try query("""
                SELECT changed_at FROM vocabulary_judgments WHERE term_id = ?
                ORDER BY changed_at DESC, id DESC LIMIT 1;
                """, bindings: [.text(term.id)]).first?["changed_at"] as? Double
            let changedAt = Date(timeIntervalSince1970: max(now.timeIntervalSince1970, (latest ?? 0) + 0.001))
            let change = VocabularyJudgmentChange(id: id, term: term, judgment: judgment, changedAt: changedAt)
            try insertVocabularyJudgment(change, outbound: true)
            return change
        }
        publishVocabularyChange()
        return result
    }

    func mergeVocabularyJudgments(_ changes: [VocabularyJudgmentChange]) throws {
        try inTransaction {
            for change in changes {
                guard try change.term.validated() == change.term, change.changedAt.timeIntervalSince1970.isFinite
                else { throw VocabularySetError.invalidTerm }
                try insertVocabularyJudgment(change, outbound: false)
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

    private func insertVocabularyJudgment(_ change: VocabularyJudgmentChange, outbound: Bool) throws {
        try execute("""
            INSERT INTO vocabulary_judgments (id, term_id, language, changed_at, outbound, payload)
            VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO NOTHING;
            """, bindings: [.text(change.id.uuidString), .text(change.term.id), .text(change.term.language),
                            .double(change.changedAt.timeIntervalSince1970), .int(outbound ? 1 : 0),
                            .blob(try JSONEncoder().encode(change))])
    }

    private func decodeVocabularyJudgment(_ row: [String: Any?]) throws -> VocabularyJudgmentChange {
        guard let bytes = payload(row, "payload") else { throw VocabularySetError.invalidTerm }
        return try JSONDecoder().decode(VocabularyJudgmentChange.self, from: bytes)
    }
}
