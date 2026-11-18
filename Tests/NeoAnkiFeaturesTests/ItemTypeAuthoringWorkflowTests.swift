import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import Testing

@Suite @MainActor struct ItemTypeAuthoringWorkflowTests {
    private func repository() async throws -> (SQLiteLibraryRepository, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("authoring-workflows-\(UUID())")
        let repository = try SQLiteLibraryRepository(databaseURL: directory.appendingPathComponent("library.sqlite"))
        try await repository.bootstrap()
        return (repository, directory)
    }

    @Test func removingDefaultUsesCurrentPolicyAndPreservesLaterAttachments() async throws {
        let (repository, directory) = try await repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let deck = try await repository.createDeck(Deck(name: "Deck"))
        let original = try await repository.createItemType(BuiltInItemTypes.basic.duplicated(name: "First"), deckID: deck.id, availableEverywhere: false)
        let factory = LibraryFeatureFactory(library: repository)
        let settings = factory.makeDeckItemTypes(deckID: deck.id)
        await settings.reload()
        await settings.setDefault(original.id)
        #expect(settings.choices?.defaultItemTypeID == original.id)
        let later = try await repository.createItemType(BuiltInItemTypes.basic.duplicated(name: "Attached later"), deckID: deck.id, availableEverywhere: false)
        // The loaded screen has not seen the new attachment. Its operation must
        // resolve current policy rather than submit its old item-type array.
        #expect(settings.choices?.itemTypes.map(\.id) == [original.id])
        await settings.remove(original.id)
        #expect(settings.error == nil)
        let choices = try await repository.authoringItemTypes(for: deck.id)
        #expect(choices.itemTypes.map(\.id) == [later.id])
        #expect(choices.defaultItemTypeID == nil)
    }

    @Test func inheritedTypesCanBeLocalizedAndRestoredWithoutCopyingSchemas() async throws {
        let (repository, directory) = try await repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = try await repository.createDeck(Deck(name: "Parent"))
        let child = try await repository.createDeck(Deck(name: "Child", parentID: parent.id))
        let type = try await repository.createItemType(BuiltInItemTypes.basic.duplicated(name: "Parent type"), deckID: parent.id, availableEverywhere: false)
        let settings = LibraryFeatureFactory(library: repository).makeDeckItemTypes(deckID: child.id)
        await settings.reload()
        #expect(settings.inherits && settings.sourceDeckName == "Parent")
        await settings.setInheritance(false)
        #expect(settings.error == nil && !settings.inherits)
        #expect(settings.choices?.itemTypes.map(\.id) == [type.id])
        await settings.setInheritance(true)
        #expect(settings.error == nil && settings.inherits)
        #expect(settings.choices?.sourceDeckID == parent.id)
        #expect(settings.choices?.itemTypes.map(\.id) == [type.id])
    }

    @Test func chooserCreatesIndependentDeckTypeAndKeepsFailureOnTheFeature() async throws {
        let (repository, directory) = try await repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let deck = try await repository.createDeck(Deck(name: "Deck"))
        let chooser = LibraryFeatureFactory(library: repository).makeTypeChooser(deckID: deck.id)
        await chooser.load()
        let selected = try #require(await chooser.choose(BuiltInItemTypes.basic, independentCopy: true))
        #expect(selected.id != BuiltInItemTypes.basic.id)
        #expect(try await repository.authoringItemTypes(for: deck.id).itemTypes.map(\.id) == [selected.id])
        chooser.name = "  A new type  "
        let created = try #require(await chooser.create())
        #expect(created.name == "A new type")
        #expect(chooser.isWorking == false && chooser.error == nil)
        let unavailable = LibraryFeatureFactory(library: repository).makeTypeChooser(deckID: UUID())
        #expect(await unavailable.choose(selected) == nil)
        #expect(unavailable.error != nil && !unavailable.isWorking)
    }
}

private actor SelectionCompletionGate {
    private var entered: Bool?
    private var observers: [CheckedContinuation<Bool, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        publish(true)
        await withCheckedContinuation { continuation = $0 }
    }
    func finished() { if entered == nil { publish(false) } }
    func waitForEntryOrCompletion() async -> Bool {
        if let entered { return entered }
        return await withCheckedContinuation { observers.append($0) }
    }
    func release() { continuation?.resume(); continuation = nil }
    private func publish(_ value: Bool) {
        entered = value
        let pending = observers; observers = []
        for observer in pending { observer.resume(returning: value) }
    }
}

extension ItemTypeAuthoringWorkflowTests {
    @Test func chooserRemainsBusyThroughPostcommitSelectionAndRejectsAnotherCreation() async throws {
        let (repository, directory) = try await repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let deck = try await repository.createDeck(Deck(name: "Deck"))
        let chooser = LibraryFeatureFactory(library: repository).makeTypeChooser(deckID: deck.id)
        chooser.name = "Only one"
        let gate = SelectionCompletionGate()
        let first = Task { @MainActor in
            let result = await chooser.create(onSelected: { _ in await gate.hold() })
            await gate.finished()
            return result
        }
        let entered = await gate.waitForEntryOrCompletion()
        #expect(entered)
        if entered {
            #expect(chooser.isWorking)
            #expect(await chooser.create() == nil)
        }
        await gate.release()
        let created = await first.value
        #expect(created != nil && !chooser.isWorking)
        #expect(try await repository.authoringItemTypes(for: deck.id).itemTypes.count == 1)
    }
}
