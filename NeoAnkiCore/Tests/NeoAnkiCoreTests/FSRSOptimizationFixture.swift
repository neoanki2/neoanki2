import Foundation
import Testing
@testable import NeoAnkiCore

func createOptimizationFixtureCard(in store: ItemStore, start: Date) async throws -> Card {
    let itemType = try await store.defaultItemType()
    let item = Item(itemTypeID: itemType.id, fields: [
        FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Optimizer front")),
        FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Optimizer back")),
    ])
    try await store.createItem(item, now: start)
    return try #require(try await store.fetchDueCards(asOf: start).first?.card)
}

func seedEligibleOptimizationHistory(
    in store: ItemStore, card: Card, start: Date
) async throws -> Date {
    let database = await store.database
    return try await database.seedOptimizationHistory(card: card, start: start)
}

extension SQLiteDatabase {
    fileprivate func seedOptimizationHistory(card: Card, start: Date) throws -> Date {
        // The real optimizer needs 400 graded targets. Seed the same 100
        // histories in one commit, since none of these tests exercises setup writes.
        try inTransaction {
            let initialMemory = MemoryState.new(due: start)
            let deltas = [1, 5, 40, 2]
            var latest = start
            for cardIndex in 0..<100 {
                let cardID = cardIndex == 0 ? card.id : UUID()
                if cardIndex != 0 {
                    try upsertSynchronizedCard(Card(
                        id: cardID, itemID: card.itemID, templateID: card.templateID,
                        skill: card.skill, memory: initialMemory
                    ))
                }
                var reviewedAt = start.addingTimeInterval(Double(cardIndex % 40) * 86_400)
                try insertReviewLog(ReviewLog(
                    cardID: cardID, reviewedAt: reviewedAt, rating: .good,
                    elapsedDays: 0, scheduledDays: 0, phaseBefore: .new, durationMs: 1_000
                ), memoryBefore: initialMemory)
                for (targetIndex, delta) in deltas.enumerated() {
                    reviewedAt = reviewedAt.addingTimeInterval(Double(delta) * 86_400)
                    latest = max(latest, reviewedAt)
                    try insertReviewLog(ReviewLog(
                        cardID: cardID, reviewedAt: reviewedAt,
                        rating: targetIndex.isMultiple(of: 3) ? .again : .good,
                        elapsedDays: Double(delta), scheduledDays: Double(delta),
                        phaseBefore: .review, durationMs: 1_000
                    ), memoryBefore: initialMemory)
                }
            }
            return latest
        }
    }
}
