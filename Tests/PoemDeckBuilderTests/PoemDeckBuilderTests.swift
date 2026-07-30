import Foundation
import NeoAnkiCore
import NeoAnkiDeckBuilderKit
import PoemDeckBuilder
import Testing

@Test func poemBuilderNormalizesLineEndingsAndIgnoresBlankLines() {
    let lines = PoemDeckGenerator.usableLines(in: "first\r\n\r\nsecond\rthird\n   \nfourth")

    #expect(lines == ["first", "second", "third", "fourth"])
}

@Test func poemBuilderRequiresMetadataAndTwoLines() throws {
    let destinationDeckID = UUID()
    #expect(throws: PoemDeckBuilderError.missingAuthor) {
        try PoemDeckGenerator.generate(input: .init(title: "Title", text: "one\ntwo"))
    }
    #expect(throws: PoemDeckBuilderError.missingTitle) {
        try PoemDeckGenerator.generate(input: .init(author: "Author", text: "one\ntwo"))
    }
    #expect(throws: PoemDeckBuilderError.missingDestinationDeck) {
        try PoemDeckGenerator.generate(
            input: .init(author: "Author", title: "Title", text: "one\ntwo")
        )
    }
    #expect(throws: PoemDeckBuilderError.tooFewLines) {
        try PoemDeckGenerator.generate(
            input: .init(
                destinationDeckID: destinationDeckID,
                author: "Author",
                title: "Title",
                text: "one"
            )
        )
    }
}

@Test func poemBuilderWritesValidatedRollingContextDeck() throws {
    let generated = try PoemDeckGenerator.generate(
        input: PoemDeckInput(
            destinationDeckID: UUID(),
            author: "Ліна",
            title: "спини мене отямся і отям",
            text: "line one\nline \"two\"\nline three\nline four"
        )
    )
    defer { generated.cleanup() }

    #expect(AuthoredDeck.validate(at: generated.bundleURL).isEmpty)
    let manifest = try String(
        contentsOf: generated.bundleURL.appendingPathComponent("deck.jsonl"),
        encoding: .utf8
    )
    #expect(!manifest.contains(#""name":"Ліна""#))
    #expect(manifest.contains(#""name":"спини мене отямся і отям""#))

    let records = try jsonLines(
        at: generated.bundleURL.appendingPathComponent("items/poem.jsonl")
    )
    #expect(records.count == 3)
    #expect(records.allSatisfy { ($0["tags"] as? [String]) == ["author:Ліна"] })
    #expect(textField("front", in: records[0]) == "line one")
    #expect(textField("back", in: records[0]) == #"line "two""#)
    #expect(textField("front", in: records[1]) == "line one\nline \"two\"")
    #expect(textField("back", in: records[1]) == "line three")
    #expect(textField("front", in: records[2]) == "line \"two\"\nline three")
    #expect(textField("back", in: records[2]) == "line four")
}

@Test func poemBuilderCleansWorkspaceWhenAuthoredValidationFails() throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("poem-builder-validation-\(UUID().uuidString)", isDirectory: true)
    let provider = FixedWorkspaceProvider(rootURL: rootURL)
    let limits = AuthoredDeckLimits(maximumLineBytes: 16)

    #expect(throws: PoemDeckBuilderError.self) {
        try PoemDeckGenerator.generate(
            input: PoemDeckInput(
                destinationDeckID: UUID(),
                author: "Author",
                title: "Title",
                text: "one\ntwo"
            ),
            workspaceProvider: provider,
            limits: limits
        )
    }
    #expect(!FileManager.default.fileExists(atPath: rootURL.path))
}

@Test func poemBuilderImportsPoemRootWithAuthorMetadataAndIncludedSchema() async throws {
    let destinationDeckID = UUID()
    let generated = try PoemDeckGenerator.generate(
        input: PoemDeckInput(
            destinationDeckID: destinationDeckID,
            author: "Ліна",
            title: "спини мене отямся і отям",
            text: """
            спини мене отямся і отям
            така любов буває раз в ніколи
            вона ж промчить над зламаним життям
            за нею ж будуть бігти видноколи
            """
        )
    )
    defer { generated.cleanup() }

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("poem-builder-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ItemStore(databaseURL: directory.appendingPathComponent("library.sqlite"))
    try await store.bootstrap()

    let result = try await AuthoredDeck.importDeck(from: generated.bundleURL, into: store)
    let decks = try await store.listDecks()
    let items = try await store.listItems()
    let due = try await store.fetchDueCards(asOf: .now)

    #expect(result.itemCount == 3)
    #expect(result.createdItemTypeCount == 1)
    #expect(result.reusedItemTypeCount == 0)
    #expect(generated.destinationDeckID == destinationDeckID)
    #expect(decks.count == 1)
    let poem = try #require(decks.first)
    #expect(poem.name == "спини мене отямся і отям")
    #expect(poem.parentID == nil)
    #expect(items.count == 3)
    #expect(items.allSatisfy { $0.itemTypeName == "Poem Line" && $0.cardCount == 1 })
    #expect(items.map(\.subtitle) == [
        "така любов буває раз в ніколи",
        "вона ж промчить над зламаним життям",
        "за нею ж будуть бігти видноколи",
    ])
    #expect(items.contains {
        $0.title == "така любов буває раз в ніколи\nвона ж промчить над зламаним життям"
            && $0.subtitle == "за нею ж будуть бігти видноколи"
    })
    let loaded = try #require(await store.fetchItem(id: items[0].id))
    #expect(loaded.item.tags == ["author:Ліна"])
    #expect(due.count == 3)
    #expect(due.map { ItemDisplay.subtitle(for: $0.item, in: $0.itemType) } == [
        "така любов буває раз в ніколи",
        "вона ж промчить над зламаним життям",
        "за нею ж будуть бігти видноколи",
    ])
    let catalog = try await store.loadItemTypeCatalog()
    #expect(!catalog.itemTypes.contains { $0.name == "Poem Line" })
    #expect(catalog.includedWithDecks.first?.itemTypes.map(\.name) == ["Poem Line"])
}

private func jsonLines(at url: URL) throws -> [[String: Any]] {
    try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n")
        .map { line in
            let data = try #require(String(line).data(using: .utf8))
            return try #require(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
        }
}

private func textField(_ name: String, in record: [String: Any]) -> String? {
    let fields = record["fields"] as? [String: Any]
    let value = fields?[name] as? [String: Any]
    return value?["text"] as? String
}

private struct FixedWorkspaceProvider: DeckBuildWorkspaceProviding {
    let rootURL: URL

    func makeWorkspace() throws -> GeneratedDeckBundle {
        let bundleURL = rootURL.appendingPathComponent("Generated.neoanki", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        return GeneratedDeckBundle(bundleURL: bundleURL) {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }
}
