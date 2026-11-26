import Foundation
@testable import NeoAnkiVocabularyKit
import Testing

@Test func matchKeysAgreeWithTheSharedVectors() throws {
    struct Vectors: Decodable { struct Vector: Decodable { let language, input, key: String }; let vectors: [Vector] }
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("NeoAnkiCore/Tests/Fixtures/vocabulary-match-keys.json")
    let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url)).vectors
    #expect(!vectors.isEmpty)
    for vector in vectors {
        #expect(VocabularyMatchKey.make(vector.input, language: vector.language) == vector.key, "\(vector.input)")
    }
}

@Test func inflectedAndUnstressedWordsResolveToTheirDictionaryForms() async throws {
    let workspace = try KnownWordsWorkspace()
    defer { workspace.cleanup() }
    func entry(_ id: String, _ canonical: String, forms: [String], frequency: Double? = nil, language: String = "uk") -> LexicalEntry {
        LexicalEntry(id: id, language: language, canonicalForm: LexicalForm(text: LocalizedText(canonical)),
                     forms: forms.map { LexicalForm(text: LocalizedText($0)) }, frequency: frequency)
    }
    let entries = [
        entry("book", "кни́жка", forms: ["кни́жки", "кни́жку", "кни́жкою"], frequency: 50),
        entry("meat", "м’ясо", forms: ["м’яса"], frequency: 80),
        entry("mother", "ма́ти", forms: ["ма́тері"], frequency: 90),
        entry("have", "ма́ти", forms: ["ма́ю"], frequency: 95),
        entry("city", "Ки́їв", forms: ["Ки́єва"]),
        entry("english", "book", forms: ["books"], frequency: 99, language: "en"),
    ]
    let jsonl = try workspace.writeJSONL(entries)
    let packURL = workspace.root.appendingPathComponent("Forms.neovocab")
    try VocabularyPackCompiler.compile(jsonlURL: jsonl, to: packURL,
        descriptor: .init(id: "forms", title: "Forms", languages: ["uk", "en"], capabilities: [.lexicon]))
    let pack = try await VocabularyPack.open(at: packURL)

    let resolved = try await pack.resolveDictionaryForms(
        of: ["книжку", "Книжкою", "м'яса", "мати", "києва", "books", "невідоме"], language: "uk-UA")
    #expect(resolved["книжку"] == ["кни́жка"])
    #expect(resolved["Книжкою"] == ["кни́жка"])
    #expect(resolved["м'яса"] == ["м’ясо"])
    #expect(resolved["мати"] == ["ма́ти"])
    #expect(resolved["києва"] == ["Ки́їв"])
    #expect(resolved["books"] == nil)
    #expect(resolved["невідоме"] == nil)
    #expect(try await pack.resolveDictionaryForms(of: ["books"], language: "en")["books"] == ["book"])
    await #expect(throws: VocabularyPackError.self) {
        _ = try await pack.resolveDictionaryForms(of: (0...VocabularyPack.maximumResolvedWords).map(String.init), language: "uk")
    }

    let band = try await pack.frequencyBand(language: "uk", offset: 0, limit: 10)
    #expect(band.total == 4)
    #expect(band.words == ["ма́ти", "ма́ти", "м’ясо", "кни́жка"])
    let sample = try await pack.frequencyBand(language: "uk", offset: 0, limit: 10, sample: 2)
    #expect(sample.words.count == 2 && sample.total == 4)
}

private struct KnownWordsWorkspace {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-known-words-\(UUID().uuidString)", isDirectory: true)

    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false) }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func writeJSONL(_ entries: [LexicalEntry]) throws -> URL {
        let url = root.appendingPathComponent("entries.jsonl")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for entry in entries { data.append(try encoder.encode(entry)); data.append(0x0A) }
        try data.write(to: url)
        return url
    }
}
