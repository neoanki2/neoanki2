import Foundation

public enum MaturityReadError: Error, LocalizedError, Sendable {
    case invalidReview(UUID?)

    public var errorDescription: String? {
        "Review history could not be read. Your library has been preserved."
    }
}

struct MaturityReadStatistics: Sendable {
    var decodedCards = 0
    var decodedReviews = 0
    var aggregateRebuilds = 0
}

struct MaturityTotals: Sendable {
    let directCounts: [UUID?: MaturitySummary]

    func summary(scope: CardScope) -> MaturitySummary {
        switch scope {
        case .all, .allDecksStudy: directCounts.values.reduce(.empty) { $0.adding($1) }
        case .unassigned: directCounts[nil] ?? .empty
        case let .decks(ids): ids.reduce(.empty) { $0.adding(directCounts[$1] ?? .empty) }
        }
    }
}

/// Compact contributions, not hydrated cards, histories, or per-item arrays.
struct MaturityProjection {
    struct Entry {
        let itemID: UUID
        let deckID: UUID?
        let detail: CardMaturityDetail

        init(card: Card, evidence: CardMaturityEvidence) {
            itemID = card.itemID
            deckID = card.deckID
            detail = CardMaturityDetail(id: card.id, templateID: card.templateID,
                clozeGroup: card.clozeGroup, occlusionGroup: card.occlusionGroup,
                status: CardMaturityStatus.evaluate(card: card, evidence: evidence))
        }
    }
    var token: DatabaseCacheToken?
    var cursor: Int64 = 0
    var isComplete = false
    var entries: [UUID: Entry] = [:]
    var directCounts: [UUID?: MaturitySummary] = [:]

    mutating func remove(_ id: UUID) {
        guard let old = entries.removeValue(forKey: id) else { return }
        let count = directCounts[old.deckID] ?? .empty
        let contribution = MaturitySummary.one(old.detail.status)
        directCounts[old.deckID] = MaturitySummary(
            activeCardCount: count.activeCardCount - contribution.activeCardCount,
            maintainingCardCount: count.maintainingCardCount - contribution.maintainingCardCount,
            notStartedCardCount: count.notStartedCardCount - contribution.notStartedCardCount)
    }

    mutating func put(_ entry: Entry) {
        remove(entry.detail.id)
        entries[entry.detail.id] = entry
        directCounts[entry.deckID] = (directCounts[entry.deckID] ?? .empty).adding(.one(entry.detail.status))
    }
}

public extension ItemStore {
    // Diagnostics remain module-internal; API representations are unchanged.
    internal func maturityReadStatistics() async -> MaturityReadStatistics {
        await database.maturityStatistics
    }
}
