import Foundation
import NeoAnkiCore
import NeoAnkiTestSupport
import Testing

@Test func deckOrganizationAssignsItemsWithoutBlockingGlobalStudy() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()

        let deck = Deck(name: "Geography")
        _ = try await ctx.store.createDeck(deck)

        let itemType = try await ctx.store.defaultItemType()
        let item = Item(
            itemTypeID: itemType.id,
            fields: [
                FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("France")),
                FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Paris")),
            ],
            deckID: deck.id
        )
        _ = try await ctx.store.createItem(item, now: ctx.clock.now())

        let storedDeck = try await ctx.store.deck(id: deck.id)
        #expect(storedDeck.name == "Geography")

        let due = try await ctx.startStudySession()
        #expect(due.count == 1)
        #expect(due.first?.card.deckID == deck.id)
    }
}
