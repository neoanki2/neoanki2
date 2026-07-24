import Foundation
import NeoAnkiCore

public enum ScenarioRunner {
    public static func run(
        _ body: (inout ScenarioContext) async throws -> Void
    ) async throws {
        let result = try await TestDatabase.makeStore()
        var context = result.context
        try await body(&context)
    }
}
