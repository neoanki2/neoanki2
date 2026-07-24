import Foundation
import NeoAnkiCore
import NeoAnkiTestSupport
import Testing

@Test func createItemFlowGeneratesCardsFromBasicType() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()
        let saved = try await ctx.createBasicItem(front: "Question", back: "Answer")
        #expect(saved.cardCount == 1)

        let due = try await ctx.startStudySession()
        #expect(due.count == 1)
        #expect(due.first?.template.interaction == .reveal)
    }
}

@Test func createItemFlowRejectsMissingRequiredField() async throws {
    let result = try await TestDatabase.makeStore()
    var ctx = result.context
    try await ctx.onboard()
    let itemType = try await ctx.store.defaultItemType()
    let item = Item(itemTypeID: itemType.id, fields: [
        FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Only front")),
    ])

    await #expect(throws: DatabaseError.requiredFieldEmpty("Back")) {
        try await ctx.store.createItem(item, now: ctx.clock.now())
    }
}
