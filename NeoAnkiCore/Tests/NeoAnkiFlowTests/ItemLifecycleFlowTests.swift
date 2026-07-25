import Foundation
import NeoAnkiCore
import NeoAnkiTestSupport
import Testing

@Test func itemLifecycleMoveDeckAndDelete() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()

        let deckA = Deck(name: "Deck A")
        let deckB = Deck(name: "Deck B")
        _ = try await ctx.store.createDeck(deckA)
        _ = try await ctx.store.createDeck(deckB)

        let saved = try await ctx.createBasicItem(front: "Q", back: "A")
        _ = try await ctx.store.updateItemDeck(itemID: saved.id, deckID: deckA.id)

        let inDeckA = try await ctx.store.listItems(scope: .deck(deckA.id))
        #expect(inDeckA.count == 1)

        _ = try await ctx.store.updateItemDeck(itemID: saved.id, deckID: deckB.id)
        #expect(try await ctx.store.listItems(scope: .deck(deckA.id)).isEmpty)
        #expect(try await ctx.store.listItems(scope: .deck(deckB.id)).count == 1)

        let fetched = try await ctx.store.fetchItem(id: saved.id)
        #expect(fetched?.item.deckID == deckB.id)

        let deleted = try await ctx.store.deleteItem(id: saved.id)
        #expect(deleted == true)
        try await ctx.assertItemCount(0)
    }
}

@Test func itemLifecycleCardsRemainDueAfterDeckMove() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()

        let deck = Deck(name: "Study Deck")
        _ = try await ctx.store.createDeck(deck)

        let saved = try await ctx.createBasicItem(front: "Q", back: "A")
        _ = try await ctx.store.updateItemDeck(itemID: saved.id, deckID: deck.id)

        try await ctx.assertDueCount(1)

        let scopedDue = try await ctx.store.fetchDueCards(
            scope: .deck(deck.id),
            asOf: ctx.clock.now()
        )
        #expect(scopedDue.count == 1)
    }
}
