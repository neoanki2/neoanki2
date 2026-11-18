import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import SQLite3
import Testing

@Suite @MainActor struct ItemEditingStudyFlowTests {
    @Test(arguments: [Interaction.reveal, .type, .choose, .arrange], [false, true])
    func contentEditRefreshesTheCurrentInteractionAndPreservesReviewState(interaction: Interaction, revealed: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("edit-study-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
        let library = LibraryFeatureModel(library: repository)
        await library.bootstrap(startSync: false)
        var type = BuiltInItemTypes.basic
        type.templates[0].interaction = interaction
        _ = try await repository.updateItemType(type, asOf: .now)
        let item = Item(itemTypeID: type.id, fields: [
            .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Old prompt")),
            .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Alpha Beta")),
        ])
        _ = try await repository.createItem(item, asOf: .now)
        let session = StudyFeatureModel(library: repository, scope: .allDecks, title: "Editing")
        await session.start()
        let current = try #require(session.currentCard)
        session.updateTypedAnswer("Unsubmitted answer")
        if revealed { session.revealAnswer() }
        let beforeCards = try await repository.cards()
        let beforeCompletion = session.completion
        var edited = item
        edited.fields[0].value = .text("New prompt")
        edited.fields[1].value = .text("Gamma Delta")
        try await library.updateItem(edited)
        await session.reloadCurrentItem()
        #expect(session.currentCard?.id == current.id)
        #expect(session.currentCard?.item == edited)
        #expect(session.isAnswerRevealed == revealed)
        #expect(session.completion == beforeCompletion)
        #expect(try await repository.cards() == beforeCards)
        #expect(session.remainingCount == 1)
        #expect(session.error == nil)
        if revealed { #expect(session.typedAnswer == "Unsubmitted answer") }
        else {
            #expect(session.typedAnswer.isEmpty)
            if interaction == .choose {
                #expect(session.choiceOptions.contains("Gamma Delta"))
                #expect(!session.choiceOptions.contains("Alpha Beta"))
            }
            if interaction == .arrange {
                #expect(Set(session.arrangedItems) == ["Gamma", "Delta"])
            }
        }
        await session.reloadCurrentItem()
        #expect(session.currentCard?.item == edited)
        #expect(session.remainingCount == 1, "Repeated refreshes must not duplicate cards")
    }

    @Test func failedSaveCannotLeakDraftContentIntoTheStudyQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("failed-edit-study-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
        let library = LibraryFeatureModel(library: repository)
        await library.bootstrap(startSync: false)
        let item = Item(itemTypeID: BuiltInItemTypes.basicID, fields: [
            .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Saved prompt")),
            .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Saved answer")),
        ])
        _ = try await repository.createItem(item, asOf: .now)
        let session = StudyFeatureModel(library: repository, scope: .allDecks, title: "Failure")
        await session.start()
        let original = try #require(session.currentCard)
        var draft = item
        draft.fields[0].value = .text("Unsaved prompt")
        draft.fields[1].value = .number(12)
        await #expect(throws: (any Error).self) { try await library.updateItem(draft) }
        await session.reloadCurrentItem()
        #expect(session.currentCard?.item == original.item)
        #expect(session.currentCard?.card == original.card)
        #expect(session.remainingCount == 1)
    }

    @Test func reloadReadFailureReportsAnErrorWithoutDiscardingTheCurrentCard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("edit-reload-error-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("library.sqlite")
        let repository = try SQLiteLibraryRepository(databaseURL: path)
        try await repository.bootstrap()
        _ = try await repository.createItem(.init(itemTypeID: BuiltInItemTypes.basicID, fields: [
            .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Question")),
            .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
        ]), asOf: .now)
        let session = StudyFeatureModel(library: repository, scope: .allDecks, title: "Read failure")
        await session.start()
        let current = try #require(session.currentCard)
        var db: OpaquePointer?
        #expect(sqlite3_open(path.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "ALTER TABLE items RENAME TO unavailable_items;", nil, nil, nil) == SQLITE_OK)
        await session.reloadCurrentItem()
        #expect(session.error != nil)
        #expect(session.currentCard?.id == current.id)
        #expect(session.currentCard?.item == current.item)
        #expect(session.remainingCount == 1)
        #expect(!session.isFinished)
    }
}
