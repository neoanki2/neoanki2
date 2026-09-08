import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import Testing

private func repairFeatureFixture() async throws -> (
    root: URL,
    repository: SQLiteLibraryRepository,
    cardID: UUID
) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-feature-repair-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let repository = try SQLiteLibraryRepository(
        databaseURL: root.appendingPathComponent("library.sqlite")
    )
    try await repository.bootstrap()
    _ = try await repository.createItem(Item(
        itemTypeID: BuiltInItemTypes.basicID,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Question")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
        ]
    ))
    let card = try #require(
        try await repository.dueCards(scope: .allDecks, asOf: .now).first
    )
    return (root, repository, card.id)
}

@Test @MainActor func sharedStudyFeatureRepeatsEveryAgainInCurrentSession() async throws {
    let fixture = try await repairFeatureFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = StudyFeatureModel(
        library: fixture.repository,
        scope: .allDecks,
        title: "All Decks"
    )

    await model.start()
    #expect(model.currentCard?.id == fixture.cardID)

    model.revealAnswer()
    await model.grade(.again)
    #expect(model.currentCard?.id == fixture.cardID)
    #expect(model.remainingCount == 1)
    #expect(!model.isComplete)

    model.revealAnswer()
    await model.grade(.again)
    #expect(model.currentCard?.id == fixture.cardID)
    #expect(model.remainingCount == 1)
    #expect(!model.isComplete)
    #expect(try await fixture.repository.card(id: fixture.cardID).memory.due <= Date.now)

    model.revealAnswer()
    await model.grade(.good)
    #expect(model.isComplete)
    #expect(model.remainingCount == 0)
    #expect(model.completion.reviews == 3)
}

@Test @MainActor func sharedStudyFeatureUndoRemovesAppendedRepairCopy() async throws {
    let fixture = try await repairFeatureFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = StudyFeatureModel(
        library: fixture.repository,
        scope: .allDecks,
        title: "All Decks"
    )

    await model.start()
    model.revealAnswer()
    await model.grade(.again)
    model.revealAnswer()
    await model.grade(.again)
    #expect(model.queue.count == 3)

    await model.undoLastGrade()
    #expect(model.currentCard?.id == fixture.cardID)
    #expect(model.queue.count == 2)
    #expect(model.remainingCount == 1)
}
