import Foundation

public extension ItemStore {
    /// Badge/widget reads must not decode every card and historical review as
    /// a full Home maturity summary does after a new review invalidates caches.
    func studyAvailability(scope: DeckScope = .allDecks, asOf now: Date = .now) async throws -> StudyAvailability {
        let resolved: CardScope
        switch scope {
        case .allDecks: resolved = .all
        case .unassigned: resolved = .unassigned
        case let .deck(id, includeDescendants):
            if includeDescendants {
                resolved = .decks(DeckTree.descendantIDs(of: id, in: try await deckTreeSummaries()))
            } else { resolved = .decks([id]) }
        }
        let totals = try await database.cardScheduleTotals(scope: resolved, asOf: now,
            studyDay: studyDayKey(asOf: now), leechThreshold: ScopeSummary.leechThreshold)
        let nextNewCardsAt = totals.hiddenNewCount > 0
            ? StudyDay.nextRollover(after: now, rolloverMinutes: try await studyDayRolloverMinutes()) : nil
        return StudyAvailability(dueNow: totals.dueNow,
            nextStudyAt: [totals.nextDueAt, nextNewCardsAt].compactMap { $0 }.min())
    }
}
