import Foundation
import NeoAnkiCore
import NeoAnkiVocabularyKit
import Testing
@testable import NeoAnkiFeatures

struct KnownWordGroupsTests {
    @Test func groupsSavedAndLegacyInflectionsWithAnInstalledDictionary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let entry = LexicalEntry(id: "hill", language: "uk", canonicalForm: .init(text: .init("пагорок")),
                                 forms: [.init(text: .init("пагорків")), .init(text: .init("пагорками"))])
        let source = root.appendingPathComponent("entry.jsonl")
        try JSONEncoder().encode(entry).write(to: source)
        let package = root.appendingPathComponent("words.neovocab")
        try VocabularyPackCompiler.compile(jsonlURL: source, to: package,
            descriptor: .init(id: "words", title: "Words", languages: ["uk"], capabilities: [.morphology]))

        let recorded = VocabularyStatus(term: .init(language: "uk", expression: "пагорками", lemma: "пагорок"),
                                        readingMature: true, clozeMature: true, hasCards: true)
        let headword = VocabularyStatus(term: .init(language: "uk", expression: "пагорок"), judgment: .known)
        let legacy = VocabularyStatus(term: .init(language: "uk", expression: "пагорків"), judgment: .known)
        let groups = await KnownWordsIndex().groups(for: [recorded, headword, legacy], language: "uk", packRoot: root)

        #expect(groups.map(\.term.expression) == ["пагорок"])
        let group = try #require(groups.first)
        #expect(group.matches("пагорків"))
        #expect(group.state == .known)
        #expect(group.clozeMature)
        #expect(group.entries(for: .ignored).map(\.term.expression) == ["пагорок"])
        #expect(Set(group.entries(for: .reviewHistory).map(\.term.expression)) == ["пагорок", "пагорків"])
    }

    @Test func ambiguousLegacyFormsRemainSeparate() {
        let word = VocabularyStatus(term: .init(language: "uk", expression: "мати"), judgment: .known)
        let mother = VocabularyStatus(term: .init(language: "uk", expression: "мама"), judgment: .known)
        let groups = KnownWordGroup.group([word, mother], dictionaryForms: [word.expressionKey: ["мати", "мама"]])
        #expect(Set(groups.map(\.term.expression)) == ["мати", "мама"])
    }

    @Test func aDictionaryFormDoesNotReplaceTheOriginalClozeAnswer() throws {
        let term = VocabularyTerm(language: "uk", expression: "пагорків", lemma: "пагорок")
        let draft = VocabularySetDraft(term: term, meaning: "Невелике узвишшя.", meaningLanguage: "uk",
                                       sentence: "Дорога вела до пагорків.")
        let item = try VocabularySet.makeItem(draft, id: UUID())
        #expect(VocabularySet.term(in: item) == term)
        let examples = try #require(VocabularySet.itemType.lists.first)
        let production = try #require(examples.columns.first { $0.name == "Production sentence" })
        guard case let .cloze(sentence, blanks) = examples.rows(in: item).first?.values.first(where: { $0.fieldID == production.id })?.value else {
            Issue.record("Expected a Cloze field")
            return
        }
        let span = try #require(blanks.first)
        #expect(String(sentence.dropFirst(span.start).prefix(span.length)) == "пагорків")
    }
}
