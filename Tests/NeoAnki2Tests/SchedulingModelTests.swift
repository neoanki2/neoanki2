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
@Test func schedulingModelTunesParametersWhenHistoryWarrantsIt() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-scheduling-auto-\(UUID().uuidString)")
        .appendingPathComponent("test.sqlite")
    let store = try ItemStore(databaseURL: url)
    try await store.bootstrap()
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    try await seedReviewHistory(in: store, reviewCount: 130, from: start)

    let model = SchedulingModel(store: store)
    let before = await store.schedulingParameters()
    await model.optimizeIfNeeded()

    #expect(await store.schedulingParameters() != before)
    let attempt = try #require(await store.lastOptimizationAttempt())
    #expect(attempt.reviewLogCount == 130)

    // A second session end that added nothing must not refit.
    let tuned = await store.schedulingParameters()
    await model.optimizeIfNeeded()
    #expect(await store.schedulingParameters() == tuned)
    #expect(try await store.lastOptimizationAttempt() == attempt)
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
