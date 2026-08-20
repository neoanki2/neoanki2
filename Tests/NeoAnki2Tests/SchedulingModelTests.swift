import Foundation
import Testing
@testable import NeoAnki2
@testable import NeoAnkiCore

@MainActor
@Test func schedulingModelStaysSilentWhenHistoryIsTooShort() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-scheduling-model-\(UUID().uuidString)")
        .appendingPathComponent("test.sqlite")
    let store = try ItemStore(databaseURL: url)
    try await store.bootstrap()
    let model = SchedulingModel(store: store)
    let before = await store.schedulingParameters()

    await model.optimizeIfNeeded()

    // Automatic fitting is maintenance, not an answer to a request: a young
    // library must produce no interruption and no parameter change.
    #expect(model.isOptimizing == false)
    #expect(await store.schedulingParameters() == before)
    #expect(try await store.lastOptimizationAttempt() == nil)
}

@MainActor
@Test func schedulingModelDoesNotOptimizeAnIneligibleSingleCardHistory() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-scheduling-auto-\(UUID().uuidString)")
        .appendingPathComponent("test.sqlite")
    let store = try ItemStore(databaseURL: url)
    try await store.bootstrap()
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    try await seedReviewHistory(in: store, reviewCount: 130, from: start)

    let model = SchedulingModel(store: store)
    let before = await store.schedulingParameters()
    let healthBefore = try await store.schedulingHealthSnapshot()
    let parameterSetsBefore = try await store.fsrsParameterSets()
    await model.optimizeIfNeeded()

    // Review volume alone cannot bypass the conservative personalization
    // gates. This fixture has only one card and fewer than 400 eligible
    // elapsed-review targets, so it must neither create mutable parameters nor an
    // immutable optimization run.
    #expect(await store.schedulingParameters() == before)
    #expect(try await store.schedulingHealthSnapshot().activeParameterSet?.id
        == healthBefore.activeParameterSet?.id)
    #expect(try await store.fsrsParameterSets() == parameterSetsBefore)
    #expect(try await store.fsrsOptimizationRuns().isEmpty)
    #expect(try await store.lastOptimizationAttempt() == nil)

    // A second session end with no new eligible data remains a no-op.
    await model.optimizeIfNeeded()
    #expect(await store.schedulingParameters() == before)
    #expect(try await store.fsrsOptimizationRuns().isEmpty)
    #expect(try await store.lastOptimizationAttempt() == nil)
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

private func seedReviewHistory(
    in store: ItemStore,
    reviewCount: Int,
    from start: Date
) async throws {
    _ = try await store.createItem(
        Item(
            itemTypeID: BuiltInItemTypes.basicID,
            fields: [
                FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Front")),
                FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Back")),
            ]
        ),
        now: start
    )
    let card = try #require(await store.fetchDueCards(asOf: start).first).card
    for index in 0..<reviewCount {
        let rating: ReviewRating = index == 0 || index % 5 != 0 ? .good : .again
        _ = try await store.submitReview(
            cardID: card.id,
            rating: rating,
            now: start.addingTimeInterval(Double(index * 12) * 86_400),
            durationMs: 1_000
        )
    }
}
