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
    // Plain-language guidance names the required and available counts without
    // leaking raw error/technical wording.
    #expect(message.contains("100"))
    #expect(message.contains("0"))
    #expect(message.contains("Keep studying"))
    #expect(!message.contains("FSRS"))
}

@MainActor
@Test func schedulingModelLoadsAndSavesRollover() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-scheduling-settings-\(UUID().uuidString)")
        .appendingPathComponent("test.sqlite")
    let store = try ItemStore(databaseURL: url)
    try await store.bootstrap()
    let model = SchedulingModel(store: store)

    await model.loadSettings()
    #expect(model.rolloverMinutes == 240)

    #expect(await model.saveRolloverMinutes(120))
    #expect(model.rolloverMinutes == 120)
    #expect(try await store.studyDayRolloverMinutes() == 120)
}
