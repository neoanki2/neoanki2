import Foundation
import NeoAnkiVocabularyCLI
import NeoAnkiVocabularyKit
import Testing

@Test func cliCompilesValidatesAndSearchesALocalPack() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-vocab-cli-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let input = root.appendingPathComponent("entries.jsonl")
    let destination = root.appendingPathComponent("Fixture.neovocab")
    let entry = LexicalEntry(
        id: "entry-1",
        language: "en",
        canonicalForm: .init(id: "lemma", text: .init("local", language: "en")),
        senses: [.init(id: "sense", definitions: [.init(text: .init("Available without a network.", language: "en"))])]
    )
    try (try JSONEncoder().encode(entry) + Data([0x0A])).write(to: input)
    var output: [String] = []
    var errors: [String] = []
    let cli = VocabularyCLI()

    let compileCode = await cli.run(
        arguments: [
            "compile", "--input", input.path, "--output", destination.path,
            "--id", "fixture", "--title", "Fixture", "--language", "en",
            "--capability", "lexicon",
        ],
        output: { output.append($0) },
        errorOutput: { errors.append($0) }
    )
    #expect(compileCode == 0)
    #expect(errors.isEmpty)
    #expect(output.contains { $0.contains("Compiled 1 entries") })

    output.removeAll()
    let validateCode = await cli.run(
        arguments: ["validate", "--pack", destination.path],
        output: { output.append($0) },
        errorOutput: { errors.append($0) }
    )
    #expect(validateCode == 0)
    #expect(output.contains("Entries: 1"))

    output.removeAll()
    let searchCode = await cli.run(
        arguments: ["search", "--pack", destination.path, "--query", "loc", "--language", "en"],
        output: { output.append($0) },
        errorOutput: { errors.append($0) }
    )
    #expect(searchCode == 0)
    #expect(output.first == "Matches: 1")
    #expect(output.contains { $0.contains("\tlocal\t") })
}

@Test func cliRejectsRemoteLocationsBeforeVocabularyIO() async {
    var errors: [String] = []
    let code = await VocabularyCLI().run(
        arguments: ["validate", "--pack", "https://example.invalid/Pack.neovocab"],
        output: { _ in },
        errorOutput: { errors.append($0) }
    )

    #expect(code == 1)
    #expect(errors.contains { $0.contains("local filesystem path") })
}

@Test func cliHelpStatesItsOfflineBoundary() async {
    var output: [String] = []
    let code = await VocabularyCLI().run(
        arguments: ["--help"],
        output: { output.append($0) },
        errorOutput: { _ in }
    )

    #expect(code == 0)
    #expect(output.joined().contains("never downloads data"))
}
