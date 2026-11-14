import Foundation
import NeoAnkiCore
import NeoAnkiTestSupport
import Testing

@Test func deletingTemplateRemovesOnlyItsCardsAndPreservesSurvivorHistory() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()
        let saved = try await ctx.createBasicItem(front: "France", back: "Paris")
        var itemType = try await ctx.store.defaultItemType()
        let forwardID = try #require(itemType.templates.first?.id)
        let reverse = try TemplateBuilder.makeRevealTemplate(
            name: "Reverse",
            promptFieldID: BuiltInItemTypes.backFieldID,
            answerFieldID: BuiltInItemTypes.frontFieldID,
            in: itemType
        )
        itemType.templates.append(reverse)
        _ = try await ctx.store.updateItemType(itemType, now: ctx.clock.now())

        let initialDue = try await ctx.startStudySession()
        #expect(initialDue.count == 1)
        let generated = try await ctx.store.cards()
        #expect(generated.count == 2)
        let forward = try #require(generated.first { $0.templateID == forwardID })
        let submission = try await ctx.store.submitReviewWithReceipt(
            cardID: forward.id,
            rating: .good,
            now: ctx.clock.now()
        )

        itemType.templates.removeAll { $0.id == reverse.id }
        _ = try await ctx.store.updateItemType(itemType, now: ctx.clock.now())

        let items = try await ctx.store.listItems()
        #expect(items.first { $0.id == saved.id }?.cardCount == 1)
        try await ctx.assertDueCount(0)

        try await ctx.store.revertReview(reviewLogID: submission.reviewLogID, now: ctx.clock.now())
        let restoredDue = try await ctx.startStudySession()
        #expect(restoredDue.map(\.card.id) == [forward.id])
        #expect(restoredDue.first?.card.templateID == forwardID)
    }
}
