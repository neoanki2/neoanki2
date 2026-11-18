import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import Testing

private enum StaleEditorRead: Error { case failed }
private actor HeldStudyItemSnapshot: LibraryStudyItemSnapshotReading {
    let library: SQLiteLibraryRepository
    let fails: Bool
    private var held: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    init(library: SQLiteLibraryRepository, fails: Bool = false) { self.library = library; self.fails = fails }
    func studyItemSnapshot(id: UUID) async throws -> ItemCardSnapshot? {
        let result = try await library.studyItemSnapshot(id: id)
        await withCheckedContinuation { held = $0; observer?.resume(); observer = nil }
        if fails { throw StaleEditorRead.failed }
        return result
    }
    func waitUntilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { held?.resume(); held = nil }
}

/// Exercise the same save + study reload used by the native card editor.
/// No views, device state, or production library are involved.
@Suite @MainActor struct CardEditingRegressionTests {
    private func fixture() async throws -> (LibraryFeatureModel, StudyFeatureModel, SQLiteLibraryRepository, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("card-edit-regression-\(UUID())")
        let repository = try SQLiteLibraryRepository(databaseURL: directory.appendingPathComponent("library.sqlite"))
        let library = LibraryFeatureModel(library: repository)
        await library.bootstrap(startSync: false)
        let now = Date.now
        let learnedAt = now.addingTimeInterval(-100 * 86_400)
        let item = Item(itemTypeID: BuiltInItemTypes.clozeID, fields: [
            .init(fieldID: BuiltInItemTypes.clozeTextFieldID,
                  value: .cloze("Alpha Beta", blanks: [
                    .init(group: 1, start: 0, length: 5),
                    .init(group: 2, start: 6, length: 4),
                  ])),
        ])
        _ = try await repository.createItem(item, asOf: learnedAt)
        for card in try await repository.cards() {
            _ = try await repository.submitReview(cardID: card.id, rating: .good,
                                                 asOf: learnedAt, durationMilliseconds: 0)
        }
        let session = StudyFeatureModel(library: repository, scope: .allDecks, title: "Edit regression", clock: { now })
        await session.start()
        #expect(session.queue.count == 2, "Fixture must load both due cloze cards before editing")
        return (library, session, repository, directory)
    }

    private func removing(group: Int, from item: Item) throws -> Item {
        var edited = item
        let index = try #require(edited.fields.firstIndex { $0.fieldID == BuiltInItemTypes.clozeTextFieldID })
        guard case let .cloze(text, blanks) = edited.fields[index].value else {
            throw DatabaseError.invalidItem("Expected cloze fixture")
        }
        edited.fields[index].value = .cloze(text, blanks: blanks.filter { $0.group != group })
        return edited
    }

    @Test func editingCurrentBlankOutOfAnItemRemovesItsRetiredCardFromTheOpenSession() async throws {
        let (library, session, repository, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = try #require(session.currentCard)
        let removedGroup = try #require(current.card.clozeGroup)
        let edited = try removing(group: removedGroup, from: current.item)

        try await library.updateItem(edited)
        let persisted = try await repository.cards()
        #expect(persisted.count == 1)
        #expect(!persisted.contains { $0.id == current.id }, "Persistence must retire the removed blank's card")
        await session.reloadCurrentItem()

        let liveIDs = Set(persisted.map(\.id))
        #expect(session.queue.allSatisfy { liveIDs.contains($0.id) }, "The session must not display a card already retired by the edit")
        #expect(session.currentCard?.id != current.id, "The visible card must advance when its blank was removed")
        #expect(session.remainingCount == 1)
        #expect(session.error == nil)
    }

    @Test func editingAnotherBlankOutOfAnItemRemovesTheRetiredUpcomingCard() async throws {
        let (library, session, repository, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = try #require(session.currentCard)
        let next = try #require(session.queue.last)
        #expect(next.id != current.id)
        let removedGroup = try #require(next.card.clozeGroup)

        try await library.updateItem(removing(group: removedGroup, from: current.item))
        let persisted = try await repository.cards()
        #expect(persisted.count == 1 && persisted[0].id == current.id)
        await session.reloadCurrentItem()

        #expect(session.currentCard?.id == current.id)
        #expect(!session.queue.contains { $0.id == next.id }, "An edit must remove retired upcoming siblings from the session")
        #expect(session.remainingCount == 1)
    }

    @Test func deletingTheEditedItemFinishesWithoutReviewingAGhostCard() async throws {
        let (_, session, repository, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = try #require(session.currentCard)
        _ = try await repository.deleteItem(id: current.item.id, asOf: .now)
        await session.reloadCurrentItem()
        #expect(session.queue.isEmpty)
        #expect(session.currentCard == nil && session.remainingCount == 0)
        #expect(session.isComplete)
        #expect(session.completion.reviews == 0)
        #expect(session.error == nil)
    }

    @Test func newlyGeneratedSiblingsWaitForTheNextSessionEligibilityPolicy() async throws {
        let (library, session, repository, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalIDs = session.queue.map(\.id)
        var edited = try #require(session.currentCard?.item)
        edited.fields[0].value = .cloze("Alpha Beta Gamma", blanks: [
            .init(group: 1, start: 0, length: 5), .init(group: 2, start: 6, length: 4), .init(group: 3, start: 11, length: 5),
        ])
        try await library.updateItem(edited)
        await session.reloadCurrentItem()
        #expect(try await repository.cards().count == 3)
        #expect(session.queue.map(\.id) == originalIDs)
        #expect(session.queue.allSatisfy { $0.item == edited })
    }

    @Test func retiringAReviewedGroupRemovesItsDeferredRepairAndUndoButKeepsHistory() async throws {
        let (library, session, _, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reviewed = try #require(session.currentCard)
        await session.grade(.again)
        #expect(session.canUndo)
        #expect(session.remainingCount == 2)
        let current = try #require(session.currentCard)
        try await library.updateItem(removing(group: try #require(reviewed.card.clozeGroup), from: current.item))
        await session.reloadCurrentItem()
        #expect(session.currentCard?.id == current.id)
        #expect(session.index == 1, "The reviewed prefix stays stable for history and undo indexing")
        #expect(session.queue.prefix(session.index).map(\.id) == [reviewed.id])
        #expect(session.remainingCount == 1, "A retired repair must never be materialized later")
        #expect(!session.canUndo)
        #expect(session.completion.reviews == 1 && session.completion.uniqueCards == 1)
    }

    @Test func aDelayedEditorSnapshotCannotOverwriteARestartedSession() async throws {
        let (_, _, repository, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let held = HeldStudyItemSnapshot(library: repository)
        let session = StudyFeatureModel(library: repository, scope: .allDecks, title: "Delayed edit", itemSnapshotReader: held)
        await session.start()
        var edited = try #require(session.currentCard?.item)
        let reload = Task { await session.reloadCurrentItem() }
        await held.waitUntilHeld()
        edited.fields[0].value = .cloze("Gamma Delta", blanks: [
            .init(group: 1, start: 0, length: 5), .init(group: 2, start: 6, length: 5),
        ])
        _ = try await repository.updateItem(edited, asOf: .now)
        await session.start()
        await held.release()
        await reload.value
        #expect(session.queue.allSatisfy { $0.item == edited })
        #expect(session.error == nil)
    }

    @Test func aDelayedReadFailureDoesNotLeakIntoANewAttemptWithTheSameCardID() async throws {
        let (_, _, repository, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let held = HeldStudyItemSnapshot(library: repository, fails: true)
        let session = StudyFeatureModel(library: repository, scope: .allDecks, title: "Delayed failure", itemSnapshotReader: held)
        await session.start()
        let original = try #require(session.currentCard?.id)
        let reload = Task { await session.reloadCurrentItem() }
        await held.waitUntilHeld()
        await session.skipCurrentCard()
        await session.skipCurrentCard()
        #expect(session.currentCard?.id == original)
        await held.release()
        await reload.value
        #expect(session.error == nil, "A previous attempt's delayed error must not affect the current attempt")
    }
}
