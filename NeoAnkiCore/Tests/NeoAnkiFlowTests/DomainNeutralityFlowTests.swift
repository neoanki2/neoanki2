import Foundation
import NeoAnkiCore
import NeoAnkiTestSupport
import Testing

@Test func novelSpatialSequenceSchemaCompletesFullLifecycle() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()

        let layout = FieldDef(name: "Spatial Layout", type: .text, isRequired: true)
        let sequence = FieldDef(name: "Movement Sequence", type: .text, isRequired: true)
        let arrangeAndReproduce = Template(
            name: "Arrange and Reproduce",
            prompt: Side(slots: [
                Slot(source: .literal("Reconstruct this route:")),
                Slot(source: .field(layout.id)),
            ]),
            answer: Side(slots: [Slot(source: .field(sequence.id))]),
            interaction: .arrange,
            skill: Skill(input: .spatial, output: .sequence, operation: .reproduce)
        )
        let routeType = ItemType(
            name: "Route Choreography",
            fields: [layout, sequence],
            templates: [arrangeAndReproduce]
        )
        _ = try await ctx.store.createItemType(routeType)

        let route = Item(
            itemTypeID: routeType.id,
            fields: [
                FieldValue(fieldID: layout.id, value: .text("northwest → center → southeast")),
                FieldValue(fieldID: sequence.id, value: .text("step, turn, place")),
            ]
        )
        let saved = try await ctx.store.createItem(route, now: ctx.clock.now())
        #expect(saved.cardCount == 1)

        let due = try await ctx.startStudySession()
        let routeCard = try #require(due.first { $0.item.id == route.id })
        #expect(routeCard.template.interaction == .arrange)
        #expect(routeCard.card.skill.input == .spatial)
        #expect(routeCard.card.skill.output == .sequence)
        #expect(routeCard.card.skill.operation == .reproduce)

        let memory = try await ctx.grade(.good, on: routeCard.card.id)
        #expect(memory.reps == 1)
        #expect(try await ctx.store.reviewLogCount(for: routeCard.card.id) == 1)

        #expect(try await ctx.store.deleteItem(id: route.id))
        #expect(try await ctx.store.deleteItemType(id: routeType.id))
        #expect(try await ctx.store.fetchItem(id: route.id) == nil)
        #expect(try await ctx.store.listItemTypes().contains { $0.id == routeType.id } == false)
    }
}

@Test func sqlLikeItemTypeNamesAndTagsRoundTripAsData() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()

        let hostileName = "Route'); DROP TABLE item_types; --"
        let hostileTags = [
            "tag'); DELETE FROM items; --",
            "\" OR 1 = 1; --",
        ]
        let cue = FieldDef(name: "Cue", type: .text, isRequired: true)
        let response = FieldDef(name: "Response", type: .text, isRequired: true)
        let template = Template(
            name: "Card",
            prompt: Side(slots: [Slot(source: .field(cue.id))]),
            answer: Side(slots: [Slot(source: .field(response.id))]),
            interaction: .reveal,
            skill: Skill(input: .text, output: .text, operation: .recall)
        )
        let hostileType = ItemType(
            name: hostileName,
            fields: [cue, response],
            templates: [template]
        )
        _ = try await ctx.store.createItemType(hostileType)

        let item = Item(
            itemTypeID: hostileType.id,
            fields: [
                FieldValue(fieldID: cue.id, value: .text("safe cue")),
                FieldValue(fieldID: response.id, value: .text("safe response")),
            ],
            tags: hostileTags
        )
        _ = try await ctx.store.createItem(item, now: ctx.clock.now())

        let fetchedType = try await ctx.store.itemType(id: hostileType.id)
        let fetchedItem = try #require(try await ctx.store.fetchItem(id: item.id))
        #expect(fetchedType.name == hostileName)
        #expect(fetchedItem.item.tags == hostileTags)
        #expect(try await ctx.store.listItemTypes().contains { $0.id == BuiltInItemTypes.basicID })
        #expect(try await ctx.store.listItems().count == 1)
    }
}
