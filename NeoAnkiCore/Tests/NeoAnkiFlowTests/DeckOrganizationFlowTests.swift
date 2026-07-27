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

        let globalDue = try await ctx.startStudySession()
        #expect(globalDue.count == 1)
        #expect(globalDue.first?.card.deckID == deck.id)

        let scopedDue = try await ctx.store.fetchDueCards(
            scope: .deck(deck.id, includeDescendants: true),
            asOf: ctx.clock.now()
        )
        #expect(scopedDue.count == 1)
    }
}

@Test func deckScopedStudyExcludesOtherDecks() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()

        let geography = Deck(name: "Geography")
        let history = Deck(name: "History")
        _ = try await ctx.store.createDeck(geography)
        _ = try await ctx.store.createDeck(history)

        let itemType = try await ctx.store.defaultItemType()
        _ = try await ctx.store.createItem(
            Item(
                itemTypeID: itemType.id,
                fields: [
                    FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("France")),
                    FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Paris")),
                ],
                deckID: geography.id
            ),
            now: ctx.clock.now()
        )
        _ = try await ctx.store.createItem(
            Item(
                itemTypeID: itemType.id,
                fields: [
                    FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Rome")),
                    FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Italy")),
                ],
                deckID: history.id
            ),
            now: ctx.clock.now()
        )

        let geographyDue = try await ctx.store.fetchDueCards(
            scope: .deck(geography.id, includeDescendants: false),
            asOf: ctx.clock.now()
        )
        #expect(geographyDue.count == 1)
        #expect(geographyDue.first?.item.fields.first?.value == .text("France"))
    }
}

@Test func parentDeckScopeIncludesChildItemsOnlyWhenRequested() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()

        let parent = Deck(name: "Languages")
        let child = Deck(name: "French", parentID: parent.id)
        _ = try await ctx.store.createDeck(parent)
        _ = try await ctx.store.createDeck(child)
        let itemType = try await ctx.store.defaultItemType()
        _ = try await ctx.store.createItem(
            Item(
                itemTypeID: itemType.id,
                fields: [
                    FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("bonjour")),
                    FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("hello")),
                ],
                deckID: child.id
            ),
            now: ctx.clock.now()
        )

        let includingChildren = DeckScope.deck(parent.id, includeDescendants: true)
        let parentOnly = DeckScope.deck(parent.id, includeDescendants: false)
        #expect(try await ctx.store.listItems(scope: includingChildren).count == 1)
        #expect(try await ctx.store.listItems(scope: parentOnly).isEmpty)
        #expect(
            try await ctx.store.fetchDueCards(scope: includingChildren, asOf: ctx.clock.now()).count == 1
        )
        #expect(
            try await ctx.store.fetchDueCards(scope: parentOnly, asOf: ctx.clock.now()).isEmpty
        )

        let summaries = try await ctx.store.deckSummaries(asOf: ctx.clock.now())
        #expect(summaries.first { $0.id == parent.id }?.dueCount == 1)
        #expect(summaries.first { $0.id == child.id }?.dueCount == 1)
    }
}
