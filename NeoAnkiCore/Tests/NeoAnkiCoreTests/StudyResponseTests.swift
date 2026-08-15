import Foundation
import Testing
@testable import NeoAnkiCore

private struct AudioSubmissionFixture {
    let root: URL
    let store: ItemStore
    let item: Item
    let card: Card
    let audioURL: URL
}

private func makeAudioSubmissionFixture() async throws -> AudioSubmissionFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-audio-submission-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try ItemStore(databaseURL: root.appendingPathComponent("library.sqlite"))
    try await store.bootstrap()

    let prompt = FieldDef(name: "Prompt", type: .text, isRequired: true)
    let template = Template(
        name: "Spoken journal",
        prompt: Side(slots: [Slot(source: .field(prompt.id))]),
        answer: Side(slots: []),
        interaction: .audioSubmission,
        skill: Skill(input: .text, output: .audio, operation: .explain)
    )
    let type = ItemType(name: "Audio Submission", fields: [prompt], templates: [template])
    _ = try await store.createItemType(type)
    let item = Item(
        itemTypeID: type.id,
        fields: [FieldValue(fieldID: prompt.id, value: .text("Explain the concept"))],
        tags: ["speaking"]
    )
    _ = try await store.createItem(item)
    let card = try #require(try await store.cards().first { $0.itemID == item.id })
    let audioURL = root.appendingPathComponent("draft.m4a")
    try Data([0x00, 0x00, 0x00, 0x18] + Array("ftypM4A ".utf8)).write(to: audioURL)
    return AudioSubmissionFixture(root: root, store: store, item: item, card: card, audioURL: audioURL)
}

@Test func audioSubmissionPersistsAtomicallyWithoutReviewAndIsIdempotent() async throws {
    let fixture = try await makeAudioSubmissionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let responseID = UUID()
    let capturedAt = Date.now.addingTimeInterval(-10)
    let submittedAt = Date.now
    let draft = StudyResponseDraft(
        id: responseID,
        cardID: fixture.card.id,
        fileURL: fixture.audioURL,
        durationMilliseconds: 601_234,
        capturedAt: capturedAt
    )

    let first = try await fixture.store.completeAudioSubmission(
        draft,
        submittedAt: submittedAt
    )
    #expect(first.cardID == draft.cardID)
    #expect(first.durationMilliseconds == draft.durationMilliseconds)
    #expect(abs(first.capturedAt.timeIntervalSince(draft.capturedAt)) < 1e-6)
    let retried = try await fixture.store.completeAudioSubmission(
        draft,
        submittedAt: submittedAt.addingTimeInterval(5)
    )

    #expect(first == retried)
    #expect(first.id == responseID)
    #expect(first.cardID == fixture.card.id)
    #expect(first.itemID == fixture.item.id)
    #expect(first.durationMilliseconds == 601_234)
    #expect(try await fixture.store.card(id: fixture.card.id).isSuspended)
    #expect(try await fixture.store.activeReviewLogCount(for: fixture.card.id) == 0)
    #expect(try await fixture.store.studyResponses().map(\.id) == [responseID])
    #expect(try await fixture.store.mediaAsset(hash: first.mediaHash)?.refCount == 1)
    #expect(FileManager.default.fileExists(atPath: fixture.audioURL.path))
}

@Test func audioSubmissionEnforcesOneResponsePerCardAndRetainsFailedDraft() async throws {
    let fixture = try await makeAudioSubmissionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try await fixture.store.completeAudioSubmission(StudyResponseDraft(
        cardID: fixture.card.id,
        fileURL: fixture.audioURL,
        durationMilliseconds: 10_000,
        capturedAt: capturedAt
    ))

    await #expect(throws: DatabaseError.self) {
        try await fixture.store.completeAudioSubmission(StudyResponseDraft(
            cardID: fixture.card.id,
            fileURL: fixture.audioURL,
            durationMilliseconds: 11_000,
            capturedAt: capturedAt
        ))
    }
    #expect(FileManager.default.fileExists(atPath: fixture.audioURL.path))
    #expect(try await fixture.store.studyResponses().count == 1)
}

@Test func responseDeletionAndItemCascadeReleasePrivateMediaReferences() async throws {
    let fixture = try await makeAudioSubmissionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let response = try await fixture.store.completeAudioSubmission(StudyResponseDraft(
        cardID: fixture.card.id,
        fileURL: fixture.audioURL,
        durationMilliseconds: 15_000,
        capturedAt: .now
    ))

    #expect(try await fixture.store.isStudyResponseMediaHash(response.mediaHash))
    #expect(try await fixture.store.ordinaryMediaReferenceCount(hash: response.mediaHash) == 0)
    #expect(try await fixture.store.deleteStudyResponse(id: response.id))
    #expect(try await fixture.store.studyResponses().isEmpty)
    #expect(try await fixture.store.mediaAsset(hash: response.mediaHash) == nil)
    #expect(try await fixture.store.card(id: fixture.card.id).isSuspended)

    let secondFixture = try await makeAudioSubmissionFixture()
    defer { try? FileManager.default.removeItem(at: secondFixture.root) }
    let cascaded = try await secondFixture.store.completeAudioSubmission(StudyResponseDraft(
        cardID: secondFixture.card.id,
        fileURL: secondFixture.audioURL,
        durationMilliseconds: 20_000,
        capturedAt: .now
    ))
    #expect(try await secondFixture.store.deleteItem(id: secondFixture.item.id))
    #expect(try await secondFixture.store.studyResponses().isEmpty)
    #expect(try await secondFixture.store.mediaAsset(hash: cascaded.mediaHash) == nil)
}

@Test func audioSubmissionQueriesFilterByCardItemTagAndTime() async throws {
    let fixture = try await makeAudioSubmissionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let submittedAt = Date.now
    let response = try await fixture.store.completeAudioSubmission(
        StudyResponseDraft(
            cardID: fixture.card.id,
            fileURL: fixture.audioURL,
            durationMilliseconds: 30_000,
            capturedAt: submittedAt.addingTimeInterval(-30)
        ),
        submittedAt: submittedAt
    )

    #expect(try await fixture.store.studyResponses(matching: StudyResponseQuery(cardID: fixture.card.id)) == [response])
    #expect(try await fixture.store.studyResponses(matching: StudyResponseQuery(itemID: fixture.item.id)) == [response])
    #expect(try await fixture.store.studyResponses(matching: StudyResponseQuery(tag: "SPEAKING")) == [response])
    #expect(try await fixture.store.studyResponses(matching: StudyResponseQuery(tag: "missing")).isEmpty)
    #expect(try await fixture.store.studyResponses(matching: StudyResponseQuery(createdAfter: submittedAt.addingTimeInterval(1))).isEmpty)
}
