import Foundation
import NeoAnkiCore
import Observation
import Testing
@testable import NeoAnki2

@MainActor
private func makeStudyModel(
    scheduler: (any Scheduler)? = nil
) async throws -> (StudyModel, ItemStore) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-study-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let databaseURL = url.appendingPathComponent("test.sqlite")
    let store = try ItemStore(databaseURL: databaseURL, scheduler: scheduler)
    try await store.bootstrap()
    return (StudyModel(store: store), store)
}

private final class StudyObservationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated = false
    func invalidate() { lock.lock(); defer { lock.unlock() }; invalidated = true }
    var didInvalidate: Bool { lock.lock(); defer { lock.unlock() }; return invalidated }
}

@Test @MainActor func macStudyFacadeObservesSharedStateWithoutMirroringIt() async throws {
    let (model, store) = try await makeStudyModel()
    _ = try await store.createItem(Item(itemTypeID: BuiltInItemTypes.basicID, fields: [
        .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Question")),
        .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
    ]))
    await model.startSession()
    let probe = StudyObservationProbe()
    withObservationTracking {
        _ = model.isAnswerRevealed
    } onChange: { probe.invalidate() }
    model.revealAnswer()
    #expect(probe.didInvalidate)
    #expect(model.isAnswerRevealed)
    await model.grade(.easy)
    #expect(model.completionSummary == "Completed 1 review and 0 submissions across 1 card")
    #expect(model.isFinished)
    await model.undoLastGrade()
    #expect(!model.isFinished)
    #expect(model.cardsReviewed == 0)
}

@Test @MainActor func studyModelRemainingLabelUpdates() async throws {
    let (model, store) = try await makeStudyModel()
    let itemType = try await store.defaultItemType()
    for i in 1...2 {
        _ = try await store.createItem(
            Item(
                itemTypeID: itemType.id,
                fields: [
                    FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Q\(i)")),
                    FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("A\(i)")),
                ]
            )
        )
    }

    await model.startSession()
    #expect(model.remainingLabel == "2 cards remaining")
    #expect(model.headerLabel == "All Decks · 2 cards remaining")

    model.revealAnswer()
    await model.grade(.good)
    #expect(model.remainingLabel == "1 card remaining")
}

@Test @MainActor func itemsModelLoadsDueCount() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-app-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let databaseURL = url.appendingPathComponent("test.sqlite")
    let store = try ItemStore(databaseURL: databaseURL)
    try await store.bootstrap()
    let mediaStore = await store.media
    let model = ItemsModel(store: store, mediaStore: mediaStore)
    let itemType = try await store.defaultItemType()
    let item = Item(
        itemTypeID: itemType.id,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Q")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("A")),
        ]
    )
    _ = try await store.createItem(item)

    await model.load()

    #expect(model.dueCount == 1)
}
