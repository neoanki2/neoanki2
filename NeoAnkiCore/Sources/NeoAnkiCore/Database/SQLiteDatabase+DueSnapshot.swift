import Foundation

/// An observable derived-projection readiness condition, not a database error.
struct DueProjectionNeedsRefresh: Error {}

struct CachedLibraryDueSnapshot {
    let token: DatabaseCacheToken
    let calendar: Calendar
    let snapshot: LibraryDueSnapshot

    func isValid(token current: DatabaseCacheToken, asOf now: Date, calendar currentCalendar: Calendar) -> Bool {
        // Compare in the same epoch/precision used by SQLite's due_at filter.
        // Converting a persisted Unix deadline back to Date can round it one
        // reference-epoch ULP above the original scheduling instant.
        let instant = now.timeIntervalSince1970
        return token == current && calendar == currentCalendar
            && instant >= snapshot.calculatedAt.timeIntervalSince1970
            && instant < snapshot.validUntil.timeIntervalSince1970
    }
}

extension SQLiteDatabase {
    func dueSnapshot(activeScope: DeckScope?, asOf now: Date) throws -> LibraryDueSnapshot {
        try Task.checkCancellation()
        let token = try cacheToken()
        let calendar = Calendar.current
        if let cached = dueSnapshotCache, cached.isValid(token: token, asOf: now, calendar: calendar),
           cached.snapshot.activeScope == activeScope {
            return cached.snapshot
        }

        // All planning, policy reads, and counts use one committed SQLite view.
        // The connection's data_version also invalidates hits after OTHER
        // connections write, including changes without a UI notification.
        let snapshot = try inReadTransaction {
            let rollover = Int(try metadataValue(forKey: ItemStore.studyDayRolloverMetadataKeyForSync) ?? "")
                ?? StudyDay.defaultRolloverMinutes
            let day = StudyDay.key(for: now, rolloverMinutes: rollover)
            let deckRecords = try fetchAllDecks()
            let parents = Dictionary(uniqueKeysWithValues: deckRecords.map { ($0.id, $0.parentID) })
            let studyScope: CardScope = deckRecords.contains { !$0.includeInAllDecksStudy } ? .allDecksStudy : .all
            let eligible = try eligibleDueCardsCTE(scope: .all, asOf: now, studyDay: day, countsOnly: true)
            let rows = try query(eligible.sql + " SELECT deck_id, COUNT(*) AS count, SUM(phase = 'new') AS available_new FROM eligible_due GROUP BY deck_id;",
                                 bindings: eligible.bindings)
            var total = 0
            var availableNew = 0
            var counts = Dictionary(uniqueKeysWithValues: deckRecords.map { ($0.id, 0) })
            for row in rows {
                let count = Int(row["count"] as? Int64 ?? 0)
                total += count
                availableNew += Int(row["available_new"] as? Int64 ?? 0)
                var deckID = (row["deck_id"] as? String).flatMap(UUID.init(uuidString:))
                var visited: Set<UUID> = []
                while let id = deckID, visited.insert(id).inserted {
                    counts[id, default: 0] += count
                    deckID = parents[id] ?? nil
                }
            }
            if studyScope == .allDecksStudy {
                let study = try eligibleDueCardsCTE(scope: studyScope, asOf: now, studyDay: day, countsOnly: true)
                let row = try query(study.sql + " SELECT COUNT(*) AS count, SUM(phase = 'new') AS available_new FROM eligible_due;",
                                    bindings: study.bindings).first
                total = Int(row?["count"] as? Int64 ?? 0)
                availableNew = Int(row?["available_new"] as? Int64 ?? 0)
            }
            func scopedCount(_ scope: CardScope) throws -> Int {
                let eligible = try eligibleDueCardsCTE(scope: scope, asOf: now, studyDay: day, countsOnly: true)
                return Int(try query(eligible.sql + " SELECT COUNT(*) AS count FROM eligible_due;",
                                     bindings: eligible.bindings).first?["count"] as? Int64 ?? 0)
            }
            let unassigned = try scopedCount(.unassigned)
            let selected: Int?
            switch activeScope {
            case nil: selected = nil
            case .allDecks: selected = total
            case .unassigned: selected = unassigned
            case let .deck(id, descendants):
                var ids: Set<UUID> = [id]
                if descendants {
                    let children = Dictionary(grouping: deckRecords, by: \.parentID)
                    var frontier = [id]
                    while let parent = frontier.popLast() {
                        for child in children[parent] ?? [] where ids.insert(child.id).inserted { frontier.append(child.id) }
                    }
                }
                selected = try scopedCount(.decks(ids))
            }
            let rolloverAt = StudyDay.nextRollover(after: now, rolloverMinutes: rollover)
            let nextDue = try nextUnsuspendedCardDue(after: now)
            let nextStudyDue = studyScope == .all ? nextDue : try nextUnsuspendedCardDue(after: now, scope: studyScope)
            let studyFilter = scopeClause(studyScope, column: "deck_id")
            let dueNew = Int(try query("""
                SELECT COUNT(*) AS count FROM cards INDEXED BY idx_cards_active_new_due
                WHERE is_suspended = 0 AND phase = 'new' AND due_at <= ? AND \(studyFilter.sql);
                """, bindings: [.double(now.timeIntervalSince1970)] + studyFilter.bindings).first?["count"] as? Int64 ?? 0)
            let nextStudy = [nextStudyDue, dueNew > availableNew ? rolloverAt : nil].compactMap { $0 }.min()
            return try LibraryDueSnapshot(total: total, unassigned: unassigned, decks: counts,
                activeScope: activeScope, activeScopeCount: selected, sourceRevision: currentChangeCursor(),
                calculatedAt: now, validUntil: nextDue.map { min($0, rolloverAt) } ?? rolloverAt,
                nextStudyAt: nextStudy)
        }
        try Task.checkCancellation()
        dueSnapshotReadCount += 1
        let after = try cacheToken()
        // Never cache a read across an external commit. The snapshot remains a
        // valid point-in-time result; the next request must observe that commit.
        if token.dataVersion == after.dataVersion {
            dueSnapshotCache = CachedLibraryDueSnapshot(token: after, calendar: calendar, snapshot: snapshot)
        }
        return snapshot
    }
}
