import Foundation
import NeoAnkiCore
import NeoAnkiDeckBuilderKit
import PoemDeckBuilder
import Testing

@testable import NeoAnki2

@Test @MainActor func productionStyleRegistryExposesPoemBuilder() {
    let registry = DeckBuilderRegistry([
        PoemDeckBuilderFeature.makeFeature(),
    ])

    #expect(registry.features.map(\.id) == ["poem"])
    #expect(registry.feature(id: "poem")?.descriptor.title == "Poem Deck")
    #expect(registry.feature(id: "missing") == nil)
}

@Test @MainActor func generatedPoemImportsThroughAppTransferAndRefreshesModels() async throws {
    let generated = try PoemDeckGenerator.generate(
        input: PoemDeckInput(
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
    let transfer = PortableDeckTransferModel(store: store)
    let decksModel = DecksModel(store: store)
    let itemsModel = ItemsModel(store: store, mediaStore: await store.media)

    let result = try #require(await transfer.importDeck(from: generated.bundleURL))
    await decksModel.load()
    await itemsModel.load()

    #expect(result.itemCount == 2)
    #expect(transfer.notice?.title == "Deck Imported")
    #expect(decksModel.deckTree.count == 1)
    #expect(decksModel.deckTree.first?.summary.name == "Author")
    #expect(decksModel.deckTree.first?.children.first?.summary.name == "Title")
    #expect(itemsModel.items.count == 2)
    #expect(itemsModel.dueCount == 2)
}

@Test func generatedBundleCleanupRemovesOnlyItsOwnedWorkspace() throws {
    let generated = try PoemDeckGenerator.generate(
        input: PoemDeckInput(author: "Author", title: "Title", text: "one\ntwo")
    )
    let workspace = generated.bundleURL.deletingLastPathComponent()
    #expect(FileManager.default.fileExists(atPath: generated.bundleURL.path))

    generated.cleanup()

    #expect(!FileManager.default.fileExists(atPath: workspace.path))
}
