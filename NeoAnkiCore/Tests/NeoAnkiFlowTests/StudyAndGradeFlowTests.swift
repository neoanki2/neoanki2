import Foundation
import NeoAnkiCore
import NeoAnkiTestSupport
import Testing

@Test func studyAndGradeFlowAdvancesDueDate() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()
        _ = try await ctx.createBasicItem(front: "Q", back: "A")

        let due = try await ctx.startStudySession()
        #expect(due.count == 1)

        let cardID = due[0].card.id
        let memory = try await ctx.grade(.good, on: cardID)
        #expect(memory.reps == 1)
        #expect(memory.phase == .review)

        try await ctx.assertDueCount(0)

        let logCount = try await ctx.store.reviewLogCount(for: cardID)
        #expect(logCount == 1)
    }
}

@Test func studyAndGradeFlowAgainSchedulesRelearning() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()
        _ = try await ctx.createBasicItem(front: "Q", back: "A")

        let due = try await ctx.startStudySession()
        let cardID = due[0].card.id
        let memory = try await ctx.grade(.again, on: cardID)

        #expect(memory.phase == .relearning)
        try await ctx.assertDueCount(0)

        ctx.clock.advanceDays(1)
        try await ctx.assertDueCount(1)
    }
}

@Test func studyAndGradeFlowSupportsAllRatings() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()

        for rating in ReviewRating.allCases {
            _ = try await ctx.createBasicItem(front: "Q-\(rating.rawValue)", back: "A")
        }

        let due = try await ctx.startStudySession()
        #expect(due.count == ReviewRating.allCases.count)

        for entry in due {
            _ = try await ctx.grade(.good, on: entry.card.id)
        }

        try await ctx.assertDueCount(0)
    }
}
