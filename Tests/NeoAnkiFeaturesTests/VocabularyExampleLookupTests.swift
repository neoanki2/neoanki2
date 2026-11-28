import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import NeoAnkiVocabularyKit
import Testing

@Test func localVocabularyExampleKeepsTheCitationAndInflectedCloze() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let example = UsageExample(text: .init("Події тяглися чередою.", language: "uk"),
                               target: .init(exactText: "чередою"),
                               provenance: .init(sourceID: "sum11", sourceName: "СУМ-11", attribution: "(Автор, 19)"))
    let entry = LexicalEntry(id: "череда", language: "uk", canonicalForm: .init(text: .init("череда")),
        forms: [.init(text: .init("ЧЕРЕДА́"), kind: "stressed"), .init(text: .init("чередою"), kind: "inflected")],
        senses: [
            .init(id: "series", definitions: [.init(text: .init("Ряд подій.", language: "uk"))], examples: [example]),
            .init(id: "plant", definitions: [.init(text: .init("Лікарська рослина.", language: "uk"))]),
        ])
    let jsonl = root.appendingPathComponent("entries.jsonl")
    try (JSONEncoder().encode(entry) + Data([0x0a])).write(to: jsonl)
    let packURL = root.appendingPathComponent("test.neovocab")
    try VocabularyPackCompiler.compile(jsonlURL: jsonl, to: packURL,
        descriptor: .init(id: "example-test", title: "Examples", languages: ["uk"], capabilities: [.lexicon]))
    let installed = root.appendingPathComponent("installed")
    try await InstalledVocabularyPackStore(rootURL: installed).install(from: packURL)

    let choices = try await VocabularyExampleLookup().meanings(for: "чередою", language: "uk", meaningLanguage: "uk", root: installed)
    #expect(choices.count == 2)
    let meaning = try #require(choices.first { $0.text == "Ряд подій." })
    #expect(meaning.headword == "ЧЕРЕДА́")
    #expect(choices.first { $0.text == "Лікарська рослина." }?.examples.isEmpty == true)
    let candidate = try #require(meaning.examples.first)
    let form = try #require(candidate.form)
    let draft = VocabularySetDraft(term: .init(language: "uk", expression: form, sense: meaning.text, lemma: meaning.lemma),
        meaning: meaning.text, meaningLanguage: meaning.language, sentence: candidate.sentence, source: candidate.citation)
    let store = try ItemStore(databaseURL: root.appendingPathComponent("library.sqlite"), starterItemTypes: [])
    try await store.bootstrap()
    let id = try await store.createVocabularySet(draft, id: UUID())
    let saved = try #require(try await store.fetchItem(id: id))
    let cards = CardGenerator.cards(for: saved.item, type: saved.itemType)
    #expect(Set(cards.map(\.templateID)) == [VocabularySet.readingID, VocabularySet.productionID])
    #expect(VocabularySet.term(in: saved.item)?.lemma == "череда")
    #expect(saved.itemType.lists.flatMap { $0.rows(in: saved.item) }.flatMap(\.values)
        .contains { $0.value == .text("СУМ-11 · (Автор, 19)") })
    let cloze = try #require(cards.first { $0.templateID == VocabularySet.productionID })
    let template = try #require(saved.itemType.templates.first { $0.id == cloze.templateID })
    #expect(VocabularySet.productionAnswer(for: .init(card: cloze, item: saved.item, itemType: saved.itemType, template: template)) == "чередою")
}
