import Foundation
import NeoAnkiCore
import NeoAnkiTestSupport
import Testing

@Test func templateAuthoringGeneratesTwoCardsWithoutMap() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()
        let (type, country, capital, map) = try await ctx.createCapitalsItemType()
        let saved = try await ctx.createCapitalsItem(
            country: "France",
            capital: "Paris",
            includeMap: false,
            type: type,
            countryField: country,
            capitalField: capital,
            mapField: map
        )

        #expect(saved.cardCount == 2)
    }
}

@Test func templateAuthoringGeneratesThreeCardsWithMap() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()
        let (type, country, capital, map) = try await ctx.createCapitalsItemType()
        let saved = try await ctx.createCapitalsItem(
            country: "France",
            capital: "Paris",
            includeMap: true,
            type: type,
            countryField: country,
            capitalField: capital,
            mapField: map
        )

        #expect(saved.cardCount == 3)
    }
}

@Test func templateAuthoringPreservesSkillsAndInteractions() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()
        let (type, country, capital, map) = try await ctx.createCapitalsItemType()
        _ = try await ctx.createCapitalsItem(
            country: "France",
            capital: "Paris",
            includeMap: true,
            type: type,
            countryField: country,
            capitalField: capital,
            mapField: map
        )

        let due = try await ctx.startStudySession()
        let operations = Set(due.map(\.card.skill.operation))
        #expect(operations.contains(.recognize))
        #expect(operations.contains(.recall))
        #expect(operations.contains(.locate))
    }
}
