import Foundation
import NeoAnkiCore
import NeoAnkiTestSupport
import Testing

@Test func multiCardStudyMixedRatingsCompletesSession() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()

        _ = try await ctx.createBasicItem(front: "One", back: "1")
        _ = try await ctx.createBasicItem(front: "Two", back: "2")
        _ = try await ctx.createBasicItem(front: "Three", back: "3")

        var due = try await ctx.startStudySession()
        #expect(due.count == 3)

        let ratings: [ReviewRating] = [.again, .hard, .good]
        for (index, entry) in due.enumerated() {
            _ = try await ctx.grade(ratings[index], on: entry.card.id)
        }

        try await ctx.assertDueCount(0)

        due = try await ctx.startStudySession()
        #expect(due.isEmpty)
    }
}

@Test func multiCardStudyAgainCardReturnsToQueueLater() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()
        _ = try await ctx.createBasicItem(front: "Q", back: "A")

        let due = try await ctx.startStudySession()
        let cardID = due[0].card.id
        _ = try await ctx.grade(.again, on: cardID)

        try await ctx.assertDueCount(0)

        ctx.clock.advanceDays(1)
        try await ctx.assertDueCount(1)
    }
}

@Test func multiCardStudyEasySchedulesLongerInterval() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()
        _ = try await ctx.createBasicItem(front: "Q", back: "A")

        let due = try await ctx.startStudySession()
        let memory = try await ctx.grade(.easy, on: due[0].card.id)

        #expect(memory.reps == 1)
        #expect(memory.phase == .review)
        try await ctx.assertDueCount(0)
    }
}
