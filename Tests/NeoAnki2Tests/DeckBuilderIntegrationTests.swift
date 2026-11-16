import Foundation
import NeoAnkiCore
import NeoAnkiDeckBuilderKit
import PoemDeckBuilder
import ProseDeckBuilder
import Testing

@testable import NeoAnki2

@Test @MainActor func productionStyleRegistryHasPoemAndProseBuilders() {
    let registry = DeckBuilderRegistry.production

    #expect(registry.features.map(\.id) == ["poem", "prose"])
    #expect(registry.feature(id: "poem")?.descriptor.title == "Poem Deck")
    #expect(registry.feature(id: "prose")?.descriptor.title == "Prose Deck")
    #expect(registry.feature(id: "vocabulary") == nil)
    #expect(registry.feature(id: "missing") == nil)
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
    poem.parentID = generated.destinationDeckID
    try await store.updateDeck(poem)
    await decksModel.load()
    await itemsModel.load()

    #expect(result.itemCount == 3)
    #expect(transfer.notice?.title == "Deck Imported")
    #expect(decksModel.deckTree.count == 1)
    #expect(decksModel.deckTree.first?.summary.name == "Poetry")
    #expect(decksModel.deckTree.first?.children.first?.summary.name == "Title")
    #expect(itemsModel.items.count == 3)
    #expect(itemsModel.dueCount == 3)
    let importedItems = try await store.listItems(
        scope: .deck(poem.id, includeDescendants: false)
    )
    #expect(importedItems.count == 3)
    for summary in importedItems {
        let loaded = try #require(await store.fetchItem(id: summary.id))
        let attribution = try #require(loaded.itemType.field(named: "Attribution"))
        #expect(loaded.item.value(for: attribution.id) == .text("Title · Author"))
        let template = try #require(loaded.itemType.templates.first)
        let resolved = SideContent.resolvedComponents(for: template, from: loaded.item)
        #expect(resolved.first?.region == .label)
        #expect(resolved.first?.purpose == .supporting)
        #expect(resolved.first?.value == .text("Title · Author"))
        #expect(resolved.first?.presentation.reveal == .always)
    }
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
