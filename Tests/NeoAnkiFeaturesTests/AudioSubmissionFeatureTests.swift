import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import Testing

private func featureAudioFixture() async throws -> (
    root: URL,
    repository: SQLiteLibraryRepository,
    cardID: UUID,
    draftURL: URL
) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-feature-response-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let repository = try SQLiteLibraryRepository(
        databaseURL: root.appendingPathComponent("library.sqlite")
    )
    try await repository.bootstrap()
    let prompt = FieldDef(name: "Prompt", type: .text, isRequired: true)
    let template = Template(
        name: "Spoken",
        prompt: Side(slots: [Slot(source: .field(prompt.id))]),
        answer: Side(slots: []),
        interaction: .audioSubmission,
        skill: Skill(input: .text, output: .audio, operation: .explain)
    )
    let type = ItemType(name: "Spoken", fields: [prompt], templates: [template])
    _ = try await repository.createItemType(type)
    let item = Item(
        itemTypeID: type.id,
        fields: [FieldValue(fieldID: prompt.id, value: .text("Explain today"))]
    )
    _ = try await repository.createItem(item)
    let card = try #require(try await repository.dueCards(scope: .allDecks, asOf: .now).first)
    let draftURL = root.appendingPathComponent("draft.m4a")
    try Data([0x00, 0x00, 0x00, 0x18] + Array("ftypM4A ".utf8)).write(to: draftURL)
    return (root, repository, card.id, draftURL)
}

@Test @MainActor func sharedStudyFeatureCompletesAudioWithoutCountingAReview() async throws {
    let fixture = try await featureAudioFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = StudyFeatureModel(
        library: fixture.repository,
        scope: .allDecks,
        title: "All Decks"
    )
    await model.start()
    #expect(model.currentCard?.template.interaction == .audioSubmission)
    model.performPrimaryAction()
    #expect(!model.isAnswerRevealed)

    let completed = await model.completeAudioSubmission(StudyResponseDraft(
        id: UUID(),
        cardID: fixture.cardID,
        fileURL: fixture.draftURL,
        durationMilliseconds: 10_000,
        capturedAt: .now
    ))

    #expect(completed)
    #expect(model.isComplete)
    #expect(model.completion.reviews == 0)
    #expect(model.completion.uniqueCards == 1)
    #expect(model.completion.uniqueItems == 1)
    #expect(try await fixture.repository.dueCount(scope: .allDecks, asOf: .now) == 0)
}

@Test @MainActor func savedResponsesFeatureLoadsNewestAndDeletesWithoutChangingCardEligibility() async throws {
    let fixture = try await featureAudioFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try await fixture.repository.completeAudioSubmission(StudyResponseDraft(
        cardID: fixture.cardID,
        fileURL: fixture.draftURL,
        durationMilliseconds: 20_000,
        capturedAt: .now
    ))
    let model = SavedResponsesFeatureModel(library: fixture.repository)
    await model.load()
    let response = try #require(model.responses.first)
    #expect(model.loadState == .ready)
    #expect(try await model.audioData(for: response).isEmpty == false)

    await model.delete(response)
    #expect(model.responses.isEmpty)
    #expect(try await fixture.repository.dueCount(scope: .allDecks, asOf: .now) == 0)
}
