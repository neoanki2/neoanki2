import Foundation
import NeoAnkiCore
import NeoAnkiTestSupport
import Testing

@Test func revertReviewRestoresPriorMemoryState() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()
        _ = try await ctx.createBasicItem(front: "Q", back: "A")

        let due = try await ctx.startStudySession()
        #expect(due.count == 1)

        let card = due[0].card
        let before = card.memory

        _ = try await ctx.grade(.good, on: card.id)
        try await ctx.assertDueCount(0)

        try await ctx.store.revertReview(cardID: card.id, restoring: before)

        try await ctx.assertDueCount(1)
        let restored = try await ctx.startStudySession()
        #expect(restored[0].card.memory == before)
        #expect(try await ctx.store.reviewLogCount(for: card.id) == 0)
    }
}
