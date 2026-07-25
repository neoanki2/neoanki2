import Foundation
import Testing
@testable import NeoAnki2
@testable import NeoAnkiCore

@MainActor
@Test func schedulingModelExplainsMinimumDataRequirement() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-scheduling-model-\(UUID().uuidString)")
        .appendingPathComponent("test.sqlite")
    let store = try ItemStore(databaseURL: url)
    try await store.bootstrap()
    let model = SchedulingModel(store: store)

    await model.optimize()

    #expect(model.isOptimizing == false)
    guard case let .failure(message) = model.notice else {
        Issue.record("Expected a clear optimization failure notice.")
        return
    }
    #expect(message.contains("At least 100"))
    #expect(message.contains("0 are available"))
}
