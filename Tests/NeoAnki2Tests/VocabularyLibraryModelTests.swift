import Foundation
import NeoAnkiVocabularyKit
import Testing

@testable import NeoAnki2

@Test @MainActor func vocabularyPackImportCopiesValidatesPersistsAndRejectsDuplicateID() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-vocabulary-library-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }

    let source = root.appendingPathComponent("Source.neovocab", isDirectory: true)
    let entries = root.appendingPathComponent("entries.jsonl")
    let entry = LexicalEntry(
        id: "uk:слово:1",
        language: "uk",
        canonicalForm: .init(text: .init("слово", language: "uk")),
        senses: [.init(id: "sense", definitions: [.init(text: .init("Одиниця мови.", language: "uk"))])]
    )
    try (try JSONEncoder().encode(entry) + Data([0x0A])).write(to: entries)
    _ = try VocabularyPackCompiler.compile(
        jsonlURL: entries,
        to: source,
        descriptor: .init(
            id: "fixture.uk",
            title: "Ukrainian Fixture",
            languages: ["uk"],
            capabilities: [.lexicon]
        )
    )

    let installedRoot = root.appendingPathComponent("Installed", isDirectory: true)
    let model = VocabularyLibraryModel(rootURL: installedRoot)
    #expect(await model.importPack(from: source))
    #expect(model.installedPacks.count == 1)
    #expect(model.installedPacks.first?.id == "fixture.uk")
    #expect(model.installedPacks.first?.packageURL != source)
    #expect(FileManager.default.fileExists(atPath: source.path))

    let reloaded = VocabularyLibraryModel(rootURL: installedRoot)
    await reloaded.load()
    #expect(reloaded.installedPacks.map(\.title) == ["Ukrainian Fixture"])
    #expect(!(await reloaded.importPack(from: source)))
    #expect(reloaded.notice?.message.contains("already installed") == true)
    #expect(reloaded.installedPacks.count == 1)
}
