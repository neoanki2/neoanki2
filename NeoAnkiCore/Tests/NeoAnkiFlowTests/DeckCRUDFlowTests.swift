import Foundation
import NeoAnkiCore
import NeoAnkiTestSupport
import Testing

@Test func deckCRUDCreateRenameReparentDelete() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()

        let parent = Deck(name: "Languages")
        _ = try await ctx.store.createDeck(parent)

        let child = Deck(name: "French", parentID: parent.id)
        let createdChild = try await ctx.store.createDeck(child)
        #expect(createdChild.parentID == parent.id)

        var renamed = createdChild
        renamed.name = "Français"
        _ = try await ctx.store.updateDeck(renamed)

        let loaded = try await ctx.store.deck(id: createdChild.id)
        #expect(loaded.name == "Français")

        let sibling = Deck(name: "Spanish", parentID: parent.id)
        _ = try await ctx.store.createDeck(sibling)

        var reparented = renamed
        reparented.parentID = sibling.id
        _ = try await ctx.store.updateDeck(reparented)

        let itemType = try await ctx.store.defaultItemType()
        _ = try await ctx.store.createItem(
            Item(
                itemTypeID: itemType.id,
                fields: [
                    FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Bonjour")),
                    FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Hello")),
                ],
                deckID: createdChild.id
            ),
            now: ctx.clock.now()
        )

        let deleted = try await ctx.store.deleteDeck(id: createdChild.id)
        #expect(deleted == true)

        let items = try await ctx.store.listItems()
        #expect(items.isEmpty)
        #expect(try await ctx.store.listDecks().count == 2)
    }
}

@Test func deckCRUDRejectsReparentCycle() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()

        let parent = Deck(name: "Parent")
        let child = Deck(name: "Child", parentID: parent.id)
        _ = try await ctx.store.createDeck(parent)
        _ = try await ctx.store.createDeck(child)

        var cycleAttempt = parent
        cycleAttempt.parentID = child.id

        await #expect(throws: DatabaseError.self) {
            try await ctx.store.updateDeck(cycleAttempt)
        }
    }
}

@Test func deckCRUDDeleteRootRemovesItems() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()

        let deck = Deck(name: "Temporary")
        _ = try await ctx.store.createDeck(deck)

        let itemType = try await ctx.store.defaultItemType()
        _ = try await ctx.store.createItem(
            Item(
                itemTypeID: itemType.id,
                fields: [
                    FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Q")),
                    FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("A")),
                ],
                deckID: deck.id
            ),
            now: ctx.clock.now()
        )

        _ = try await ctx.store.deleteDeck(id: deck.id)

        #expect(try await ctx.store.listItems(scope: .unassigned).isEmpty)
        #expect(try await ctx.store.listItems(scope: .allDecks).isEmpty)
    }
}
