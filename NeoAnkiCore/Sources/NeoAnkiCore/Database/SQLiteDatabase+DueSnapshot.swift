import Foundation

/// An observable derived-projection readiness condition, not a database error.
struct DueProjectionNeedsRefresh: Error {}

struct CachedLibraryDueSnapshot {
    let token: DatabaseCacheToken
    let calendar: Calendar
    let snapshot: LibraryDueSnapshot

    func isValid(token current: DatabaseCacheToken, asOf now: Date, calendar currentCalendar: Calendar) -> Bool {
        token == current && calendar == currentCalendar
            && now >= snapshot.calculatedAt && now < snapshot.validUntil
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
            let dueNew = Int(try query("""
                SELECT COUNT(*) AS count FROM cards INDEXED BY idx_cards_active_new_due
                WHERE is_suspended = 0 AND phase = 'new' AND due_at <= ?;
                """, bindings: [.double(now.timeIntervalSince1970)]).first?["count"] as? Int64 ?? 0)
            let nextStudy = [nextDue, dueNew > availableNew ? rolloverAt : nil].compactMap { $0 }.min()
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
