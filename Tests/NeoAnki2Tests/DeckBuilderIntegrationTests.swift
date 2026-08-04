import Foundation
import NeoAnkiCore
import NeoAnkiDeckBuilderKit
import PoemDeckBuilder
import Testing
import VocabularyDeckBuilder

@testable import NeoAnki2

@Test @MainActor func productionStyleRegistryKeepsIncrementalVocabularyOutOfDeckBuilders() {
    let registry = DeckBuilderRegistry([
        PoemDeckBuilderFeature.makeFeature(),
    ])

    #expect(registry.features.map(\.id) == ["poem"])
    #expect(registry.feature(id: "poem")?.descriptor.title == "Poem Deck")
    #expect(registry.feature(id: "vocabulary") == nil)
    #expect(registry.feature(id: "missing") == nil)
}

@Test @MainActor func generatedVocabularyItemsAppendToSelectedDeckWithoutCreatingADeck() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-vocabulary-append-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ItemStore(databaseURL: directory.appendingPathComponent("library.sqlite"))
    try await store.bootstrap()
    let destination = try await store.createDeck(Deck(name: "Ukrainian"))
    let generated = try VocabularyDeckGenerator.generate(
        input: VocabularyDeckInput(
            destinationDeckID: destination.id,
            deckName: destination.name,
            language: "uk",
            form: "слово",
            senses: [.init(id: "sense", definition: "Одиниця мови.")],
            paradigms: [.formToMeaning, .meaningToForm]
        )
    )
    defer { generated.cleanup() }

    let result = try await AuthoredDeck.importItems(
        from: generated.bundleURL,
        into: store,
        deckID: destination.id
    )

    #expect(result.itemCount == 1)
    #expect(try await store.listDecks().map(\.name) == ["Ukrainian"])
    let items = try await store.listItems(scope: .deck(destination.id, includeDescendants: false))
    #expect(items.count == 1)
    #expect(items.first?.deckID == destination.id)
    #expect(items.first?.cardCount == 2)
}

@Test @MainActor func generatedPoemImportsThroughAppTransferAndRefreshesModels() async throws {
    let destination = Deck(name: "Poetry")
    let generated = try PoemDeckGenerator.generate(
        input: PoemDeckInput(
            destinationDeckID: destination.id,
            author: "Author",
            title: "Title",
            text: "one\ntwo\nthree"
        )
    )
    defer { generated.cleanup() }

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-builder-app-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ItemStore(databaseURL: directory.appendingPathComponent("library.sqlite"))
    try await store.bootstrap()
    try await store.createDeck(destination)
    let transfer = PortableDeckTransferModel(store: store)
    let decksModel = DecksModel(store: store)
    let itemsModel = ItemsModel(store: store, mediaStore: await store.media)

    let result = try #require(await transfer.importDeck(from: generated.bundleURL))
    var poem = try await store.deck(id: try #require(result.deckIDs.first))
    poem.parentID = try #require(generated.destinationDeckID)
    try await store.updateDeck(poem)
    await decksModel.load()
    await itemsModel.load()

    #expect(result.itemCount == 2)
    #expect(transfer.notice?.title == "Deck Imported")
    #expect(decksModel.deckTree.count == 1)
    #expect(decksModel.deckTree.first?.summary.name == "Poetry")
    #expect(decksModel.deckTree.first?.children.first?.summary.name == "Title")
    #expect(itemsModel.items.count == 2)
    #expect(itemsModel.dueCount == 2)
}

@Test func generatedBundleCleanupRemovesOnlyItsOwnedWorkspace() throws {
    let generated = try PoemDeckGenerator.generate(
        input: PoemDeckInput(
            destinationDeckID: UUID(),
            author: "Author",
            title: "Title",
            text: "one\ntwo"
        )
    )
    let workspace = generated.bundleURL.deletingLastPathComponent()
    #expect(FileManager.default.fileExists(atPath: generated.bundleURL.path))

    generated.cleanup()

    #expect(!FileManager.default.fileExists(atPath: workspace.path))
}
