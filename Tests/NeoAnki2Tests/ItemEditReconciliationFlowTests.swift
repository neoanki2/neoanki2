import Foundation
import NeoAnkiCore
import Testing

@testable import NeoAnki2

@Test @MainActor func itemsModelClozeEditReconcilesCardsAndPreservesSurvivorHistory() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-item-edit-flow-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try ItemStore(databaseURL: root.appendingPathComponent("test.sqlite"))
    try await store.bootstrap()
    let model = ItemsModel(store: store, mediaStore: await store.media)
    await model.load()
    model.addItemTypeID = BuiltInItemTypes.clozeID

    let originalText = "alpha beta"
    #expect(await model.addItem(
        fieldSpans: [:],
        fieldText: [BuiltInItemTypes.clozeTextFieldID: originalText],
        fieldClozeBlanks: [
            BuiltInItemTypes.clozeTextFieldID: [
                ClozeSpan(group: 1, start: 0, length: 5),
                ClozeSpan(group: 2, start: 6, length: 4),
            ],
        ]
    ))
    let itemID = try #require(model.items.first?.id)
    let initialDue = try await store.fetchDueCards()
    let groupOne = try #require(initialDue.first { $0.card.clozeGroup == 1 })
    let submission = try await store.submitReviewWithReceipt(
        cardID: groupOne.card.id,
        rating: .good
    )

    #expect(await model.updateItem(
        id: itemID,
        fieldSpans: [:],
        fieldText: [BuiltInItemTypes.clozeTextFieldID: "alpha gamma"],
        fieldClozeBlanks: [
            BuiltInItemTypes.clozeTextFieldID: [
                ClozeSpan(group: 1, start: 0, length: 5),
                ClozeSpan(group: 3, start: 6, length: 5),
            ],
        ]
    ))
    #expect(model.items.first?.cardCount == 2)
    #expect(model.dueCount == 1)
    let afterEdit = try await store.fetchDueCards()
    #expect(afterEdit.map(\.card.clozeGroup) == [3])

    try await store.revertReview(reviewLogID: submission.reviewLogID)
    let restored = try await store.fetchDueCards()
    #expect(Set(restored.compactMap(\.card.clozeGroup)) == [1, 3])
    #expect(restored.first { $0.card.clozeGroup == 1 }?.card.id == groupOne.card.id)
}
