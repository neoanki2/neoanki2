import Foundation
import NeoAnkiCore
import NeoAnkiTestSupport
import Testing

@Test func updateItemTypePersistsTemplateList() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()
        var itemType = try await ctx.store.defaultItemType()

        let reverse = try TemplateBuilder.makeRevealTemplate(
            name: "Reverse",
            promptFieldID: BuiltInItemTypes.backFieldID,
            answerFieldID: BuiltInItemTypes.frontFieldID,
            in: itemType
        )
        itemType.templates.append(reverse)

        let updated = try await ctx.store.updateItemType(itemType)
        #expect(updated.templates.count == 2)

        let reloaded = try await ctx.store.itemType(id: itemType.id)
        #expect(reloaded.templates.map(\.name).contains("Reverse"))
    }
}

@Test func addingTemplateGeneratesCardsForExistingItems() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()
        let saved = try await ctx.createBasicItem(front: "France", back: "Paris")
        #expect(saved.cardCount == 1)

        var itemType = try await ctx.store.defaultItemType()
        let reverse = try TemplateBuilder.makeRevealTemplate(
            name: "Reverse",
            promptFieldID: BuiltInItemTypes.backFieldID,
            answerFieldID: BuiltInItemTypes.frontFieldID,
            in: itemType
        )
        itemType.templates.append(reverse)
        _ = try await ctx.store.updateItemType(itemType)

        let reloaded = try await ctx.store.fetchItem(id: saved.id)
        #expect(reloaded != nil)

        let items = try await ctx.store.listItems()
        #expect(items.first?.cardCount == 2)
    }
}

@Test func editingTemplateSkillUpdatesCachedCardSkill() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()
        let saved = try await ctx.createBasicItem(front: "France", back: "Paris")

        var itemType = try await ctx.store.defaultItemType()
        guard let index = itemType.templates.firstIndex(where: { $0.name == "Card" }) else {
            Issue.record("Expected default Card template.")
            return
        }

        var template = itemType.templates[index]
        template.skill = Skill(input: .text, output: .text, operation: .recall)
        itemType.templates[index] = template
        _ = try await ctx.store.updateItemType(itemType)

        let due = try await ctx.startStudySession()
        #expect(due.first?.card.skill.operation == .recall)
        _ = saved
    }
}

@Test func updateItemTypeRejectsInvalidFieldReference() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()
        var itemType = try await ctx.store.defaultItemType()

        let bogusID = UUID()
        itemType.templates.append(
            Template(
                name: "Broken",
                prompt: Side(slots: [Slot(source: .field(bogusID))]),
                answer: Side(slots: [Slot(source: .field(BuiltInItemTypes.backFieldID))]),
                interaction: .reveal,
                skill: Skill(input: .text, output: .text, operation: .recognize)
            )
        )

        await #expect(throws: DatabaseError.invalidItemType("Template \"Broken\" references an unknown field.")) {
            try await ctx.store.updateItemType(itemType)
        }
    }
}

@Test func listItemTypesReturnsSeededBasicType() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()
        let types = try await ctx.store.listItemTypes()
        #expect(types.count == 2)
        #expect(Set(types.map(\.name)) == ["Basic", "Cloze"])
    }
}

@Test func listItemTypesReturnsMultipleTypes() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()
        _ = try await ctx.createCapitalsItemType()

        let types = try await ctx.store.listItemTypes()
        #expect(types.count == 3)
        #expect(Set(types.map(\.name)) == ["Basic", "Cloze", "Capitals"])
    }
}
