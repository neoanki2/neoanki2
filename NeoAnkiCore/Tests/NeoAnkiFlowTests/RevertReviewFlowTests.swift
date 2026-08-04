import Foundation
import NeoAnkiCore
import NeoAnkiTestSupport
import Testing

@Test func revertReviewPreservesHistoryAndRestoresRecordedMemory() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()
        _ = try await ctx.createBasicItem(front: "Q", back: "A")

        let due = try await ctx.startStudySession()
        #expect(due.count == 1)

        let card = due[0].card
        let before = card.memory

        let submission = try await ctx.store.submitReviewWithReceipt(
            cardID: card.id,
            rating: .good,
            now: ctx.clock.now()
        )
        try await ctx.assertDueCount(0)

        try await ctx.store.revertReview(
            reviewLogID: submission.reviewLogID,
            now: ctx.clock.now()
        )

        try await ctx.assertDueCount(1)
        let restored = try await ctx.startStudySession()
        #expect(restored[0].card.memory == before)
        #expect(try await ctx.store.rawReviewLogCount(for: card.id) == 1)
        #expect(try await ctx.store.activeReviewLogCount(for: card.id) == 0)
        #expect(try await ctx.store.reviewLogCount(for: card.id) == 0)
    }
}

@Test func revertReviewTargetsExactLogWhenTimestampsCollide() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()
        _ = try await ctx.createBasicItem(front: "Q", back: "A")
        let card = try #require(try await ctx.startStudySession().first?.card)
        let timestamp = ctx.clock.now()

        let first = try await ctx.store.submitReviewWithReceipt(
            cardID: card.id,
            rating: .hard,
            now: timestamp
        )
        let second = try await ctx.store.submitReviewWithReceipt(
            cardID: card.id,
            rating: .easy,
            now: timestamp
        )

        await #expect(throws: DatabaseError.reviewLogNotFound(first.reviewLogID)) {
            try await ctx.store.revertReview(reviewLogID: first.reviewLogID, now: timestamp)
        }
        try await ctx.store.revertReview(reviewLogID: second.reviewLogID, now: timestamp)

        let restored = try #require(
            try await ctx.store.fetchDueCards(asOf: first.memory.due).first?.card
        )
        #expect(restored.memory == first.memory)
        #expect(try await ctx.store.rawReviewLogCount(for: card.id) == 2)
        #expect(try await ctx.store.activeReviewLogCount(for: card.id) == 1)

        await #expect(throws: DatabaseError.reviewLogNotFound(second.reviewLogID)) {
            try await ctx.store.revertReview(reviewLogID: second.reviewLogID, now: timestamp)
        }
    }
}

@Test func deletingCardDoesNotDeleteReviewHistory() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()
        let item = try await ctx.createBasicItem(front: "Q", back: "A")
        let card = try #require(try await ctx.startStudySession().first?.card)
        _ = try await ctx.store.submitReviewWithReceipt(
            cardID: card.id,
            rating: .good,
            now: ctx.clock.now()
        )

        _ = try await ctx.store.deleteItem(id: item.id)

        #expect(try await ctx.store.rawReviewLogCount(for: card.id) == 1)
        #expect(try await ctx.store.activeReviewLogCount(for: card.id) == 0)
    }
}
