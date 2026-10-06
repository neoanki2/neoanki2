import Foundation
import NeoAnkiCore
import NeoAnkiVocabularyKit
import Testing
@testable import NeoAnki2

@Test @MainActor func genericDictionaryTextAndStressOnlySaveThroughOrdinaryMacEditor() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictionary-authoring-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ItemStore(databaseURL: root.appendingPathComponent("library.sqlite"))
    try await store.bootstrap()
    let source = FieldDef(name: "Question", type: .text)
    let destination = FieldDef(name: "Answer", type: .richText)
    let type = ItemType(name: "My custom fields", fields: [source, destination], templates: [
        Template(name: "Recall", prompt: Side(slots: [Slot(source: .field(source.id))]),
                 answer: Side(slots: [Slot(source: .field(destination.id))]), interaction: .reveal,
                 skill: Skill(input: .text, output: .text, operation: .recognize))
    ])
    _ = try await store.createItemType(type)
    let deck = try await store.createDeck(Deck(name: "Chosen deck"))
    let entry = LexicalEntry(id: "word", language: "uk", canonicalForm: .init(text: .init("абажур")),
        pronunciations: [.init(scheme: "any-annotation", representations: [.text(.init("абажу\u{301}р"))])],
        senses: [.init(id: "meaning", definitions: [.init(text: .init("Дашок для захисту очей від світла."))])])
    let model = ItemsModel(store: store, mediaStore: nil)
    await model.load()
    model.addItemTypeID = type.id
    #expect(await model.addItem(fieldSpans: [source.id: [Span("абажур")], destination.id: [Span(DictionaryEntryText.render(entry))]], deckID: deck.id))
    let itemID = try #require(model.items.first?.id)
    let stored = try #require(try await store.fetchItem(id: itemID)?.item)
    #expect(stored.deckID == deck.id)
    #expect(stored.value(for: destination.id) == .rich([Span(DictionaryEntryText.render(entry))]))
    #expect(try await store.fetchDueCards(asOf: .now).count == 1)
    #expect(try await store.listDecks().count == 1)
    #expect(await model.updateItem(id: itemID, fieldSpans: [source.id: [Span("абажур")], destination.id: [Span("абажу\u{301}р")]]))
    #expect(try await store.fetchItem(id: itemID)?.item.value(for: destination.id) == .rich([Span("абажу\u{301}р")]))
    #expect(try await store.fetchDueCards(asOf: .now).count == 1)
}
