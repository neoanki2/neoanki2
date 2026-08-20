import Foundation
import NeoAnkiApplication
import Testing
@testable import NeoAnki2

@Test("UI test control accepts newly seeded scenario names")
func uiTestControlAcceptsNewScenarioNames() throws {
    let data = Data(#"""
    {
        "sessionID":"session",
        "sequence":1,
        "action":"reset",
        "databaseDirectory":"/tmp/neoanki-ui-test",
        "scenario":"item-type-risky-edit",
        "initialRoute":"library",
        "path":null,
        "enabled":null,
        "environment":{}
    }
    """#.utf8)

    let command = try JSONDecoder().decode(UITestCommand.self, from: data)
    #expect(command.scenario == "item-type-risky-edit")
}

@Test("Unknown UI test scenarios fail before acknowledgement")
func unknownUITestScenarioFails() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-unknown-ui-scenario-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try SQLiteLibraryRepository(
        databaseURL: directory.appendingPathComponent("test.sqlite")
    )

    await #expect(throws: UITestScenarioSeederError.unknownScenario("misspelled-scenario")) {
        try await UITestScenarioSeeder.seed(
            scenario: "misspelled-scenario",
            environment: [:],
            store: store
        )
    }
}
