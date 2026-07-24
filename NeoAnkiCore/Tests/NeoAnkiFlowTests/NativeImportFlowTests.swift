import Foundation
import NeoAnkiCore
import NeoAnkiTestSupport
import Testing

@Test func nativeJSONImportCreatesItemsAndCards() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()

        let json = """
        {
          "itemType": "Basic",
          "rows": [
            { "Front": "One", "Back": "1" },
            { "Front": "Two", "Back": "2", "tags": ["sample"] }
          ]
        }
        """.data(using: .utf8)!

        let imported = try await ctx.store.importItems(
            from: json,
            adapter: JSONImportAdapter(),
            now: ctx.clock.now()
        )
        #expect(imported == 2)
        try await ctx.assertItemCount(2)

        let due = try await ctx.startStudySession()
        #expect(due.count == 2)
    }
}

@Test func nativeCSVImportCreatesItems() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()

        let csv = """
        Front,Back,tags
        Alpha,Beta,tag1
        Gamma,Delta,
        """.data(using: .utf8)!

        let imported = try await ctx.store.importItems(
            from: csv,
            adapter: CSVImportAdapter(itemTypeName: "Basic"),
            now: ctx.clock.now()
        )
        #expect(imported == 2)
        try await ctx.assertItemCount(2)
    }
}

@Test func importRejectsUnknownField() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()

        let json = """
        {
          "itemType": "Basic",
          "rows": [
            { "Front": "Q", "Back": "A", "Unknown": "x" }
          ]
        }
        """.data(using: .utf8)!

        await #expect(throws: ImportError.unknownField("Unknown")) {
            try await ctx.store.importItems(from: json, adapter: JSONImportAdapter())
        }
    }
}
