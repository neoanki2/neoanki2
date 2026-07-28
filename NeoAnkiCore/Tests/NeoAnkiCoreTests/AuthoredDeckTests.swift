import Foundation
import Testing
@testable import NeoAnkiCore

private func authoredTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("authored-deck-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func authoredBundle(
    in directory: URL,
    manifestRecords: [String],
    itemRecords: [String]
) throws -> URL {
    let bundle = directory.appendingPathComponent("Test.neoanki", isDirectory: true)
    let items = bundle.appendingPathComponent("items", isDirectory: true)
    try FileManager.default.createDirectory(at: items, withIntermediateDirectories: true)
    try (manifestRecords.joined(separator: "\n") + "\n").write(
        to: bundle.appendingPathComponent("deck.jsonl"),
        atomically: true,
        encoding: .utf8
    )
    try (itemRecords.joined(separator: "\n") + "\n").write(
        to: items.appendingPathComponent("items.jsonl"),
        atomically: true,
        encoding: .utf8
    )
    return bundle
}

private let authoredManifest =
    #"{"kind":"neoanki","version":2,"root":"root","parts":["items/items.jsonl"]}"#
private let authoredDeck =
    #"{"kind":"deck","id":"root","name":"Authored"}"#
private let authoredType =
    #"{"kind":"type","id":"Study","name":"Authored Study","fields":[{"id":"front","name":"Front","type":"text","required":true},{"id":"back","name":"Back","type":"richText","required":true},{"id":"cloze","name":"Cloze","type":"cloze"},{"id":"image","name":"Image","type":"image"}],"templates":[{"name":"Forward","prompt":[{"field":"front"}],"answer":[{"field":"back"}],"interaction":"reveal","skill":{"input":"text","output":"text","operation":"recall"}}]}"#

@Test func documentedAuthoredDeckExampleRemainsValid() {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let example = repositoryRoot
        .appendingPathComponent("docs/examples/Biology.neoanki", isDirectory: true)

    #expect(AuthoredDeck.validate(at: example).isEmpty)
}

@Test func authoredDeckJSONSchemasRemainValidJSON() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let schemaDirectory = repositoryRoot.appendingPathComponent("docs/schemas", isDirectory: true)
    for name in [
        "authored-manifest.schema.json",
        "authored-deck.schema.json",
        "authored-type.schema.json",
        "authored-item.schema.json",
    ] {
        let data = try Data(contentsOf: schemaDirectory.appendingPathComponent(name))
        let object = try JSONSerialization.jsonObject(with: data)
        #expect(object is [String: Any])
    }
}

@Test func authoredManifestSchemaRejectsTraversalParts() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(
        "docs/schemas/authored-manifest.schema.json"
    ))
    let schema = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let properties = try #require(schema["properties"] as? [String: Any])
    let parts = try #require(properties["parts"] as? [String: Any])
    let items = try #require(parts["items"] as? [String: Any])
    let pattern = try #require(items["pattern"] as? String)
    let expression = try NSRegularExpression(pattern: pattern)
    func matches(_ value: String) -> Bool {
        expression.firstMatch(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        ) != nil
    }

    #expect(matches("items/chapter/part-001.jsonl"))
    #expect(!matches("items/../escape.jsonl"))
    #expect(!matches("items/chapter/../../escape.jsonl"))
    #expect(!matches("items/./part.jsonl"))
    #expect(!matches("items/chapter/./part.jsonl"))
    #expect(!matches("items//part.jsonl"))
}

@Test func authoredDeckImportsFullTextContentAndFreshCards() async throws {
    let directory = try authoredTestDirectory()
    let bundle = try authoredBundle(
        in: directory,
        manifestRecords: [authoredManifest, authoredType, authoredDeck],
        itemRecords: [
            #"{"kind":"item","deck":"root","type":"Study","fields":{"front":{"text":"Question","lang":"en"},"back":{"rich":[{"text":"Bold","styles":["bold","superscript"],"color":"purple","size":"large","link":"https://neoanki.app"},{"text":" answer","styles":["subscript"],"color":"green","size":"small"}]},"cloze":{"cloze":"A {{c1::mitochondrion::organelle}} makes energy."}},"tags":["biology"]}"#,
        ]
    )
    #expect(AuthoredDeck.validate(at: bundle).isEmpty)

    let store = try ItemStore(databaseURL: directory.appendingPathComponent("library.sqlite"))
    try await store.bootstrap()
    let result = try await AuthoredDeck.importDeck(from: bundle, into: store)

    #expect(result.itemCount == 1)
    #expect(result.deckIDs.count == 1)
    let items = try await store.listItems()
    #expect(items.count == 1)
    #expect(items[0].title == "Question")
    #expect(items[0].cardCount == 1)
    let loaded = try #require(await store.fetchItem(id: items[0].id))
    #expect(loaded.item.tags == ["biology"])
    #expect(loaded.item.fields[1].value == .rich([
        Span(
            "Bold",
            styles: [.bold, .superscript],
            textColor: .purple,
            textSize: .large,
            link: "https://neoanki.app"
        ),
        Span(" answer", styles: [.subscriptText], textColor: .green, textSize: .small),
    ]))
    guard case let .cloze(text, blanks) = loaded.item.fields[2].value else {
        Issue.record("Expected compiled cloze content")
        return
    }
    #expect(text == "A mitochondrion makes energy.")
    #expect(blanks == [.init(group: 1, start: 2, length: 13, hint: "organelle")])
}

@Test func authoredDeckNormalizesConflictingLegacyRichTextStyles() async throws {
    let directory = try authoredTestDirectory()
    let bundle = try authoredBundle(
        in: directory,
        manifestRecords: [authoredManifest, authoredType, authoredDeck],
        itemRecords: [
            #"{"kind":"item","deck":"root","type":"Study","fields":{"front":{"text":"Question"},"back":{"rich":[{"text":"Legacy","styles":["highlight","code","superscript","subscript"]}]}}}"#,
        ]
    )

    #expect(AuthoredDeck.validate(at: bundle).isEmpty)

    let store = try ItemStore(databaseURL: directory.appendingPathComponent("library.sqlite"))
    try await store.bootstrap()
    _ = try await AuthoredDeck.importDeck(from: bundle, into: store)

    let summary = try #require(try await store.listItems().first)
    let loaded = try #require(await store.fetchItem(id: summary.id))
    #expect(loaded.item.fields[1].value == .rich([
        Span("Legacy", styles: [.highlight, .superscript]),
    ]))
}

@Test func authoredLinkSchemaRequiresSupportedSchemeAndHTTPHost() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let schemaURL = repositoryRoot
        .appendingPathComponent("docs/schemas/authored-item.schema.json")
    let data = try Data(contentsOf: schemaURL)
    let schema = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let definitions = try #require(schema["$defs"] as? [String: Any])
    let span = try #require(definitions["span"] as? [String: Any])
    let properties = try #require(span["properties"] as? [String: Any])
    let link = try #require(properties["link"] as? [String: Any])
    let pattern = try #require(link["pattern"] as? String)
    let expression = try NSRegularExpression(pattern: pattern)

    func matches(_ value: String) -> Bool {
        expression.firstMatch(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        ) != nil
    }

    #expect(matches("https://neoanki.app/docs"))
    #expect(matches("http://localhost:8080"))
    #expect(matches("mailto:study@example.com"))
    #expect(!matches("https:///missing-host"))
    #expect(!matches("https://example.com/a path"))
    #expect(!matches("javascript:alert(1)"))
}

@Test func authoredDeckVersionOneRemainsReadable() throws {
    let directory = try authoredTestDirectory()
    let legacyManifest =
        #"{"kind":"neoanki","version":1,"root":"root","parts":["items/items.jsonl"]}"#
    let bundle = try authoredBundle(
        in: directory,
        manifestRecords: [legacyManifest, authoredType, authoredDeck],
        itemRecords: [
            #"{"kind":"item","deck":"root","type":"Study","fields":{"front":{"text":"Question"},"back":{"rich":[{"text":"Legacy","styles":["bold"]}]}}}"#,
        ]
    )

    #expect(AuthoredDeck.validate(at: bundle).isEmpty)
}

@Test func authoredDeckVersionOneRejectsVersionTwoRichFormatting() throws {
    let directory = try authoredTestDirectory()
    let legacyManifest =
        #"{"kind":"neoanki","version":1,"root":"root","parts":["items/items.jsonl"]}"#
    let bundle = try authoredBundle(
        in: directory,
        manifestRecords: [legacyManifest, authoredType, authoredDeck],
        itemRecords: [
            #"{"kind":"item","deck":"root","type":"Study","fields":{"front":{"text":"Question"},"back":{"rich":[{"text":"New","color":"purple"}]}}}"#,
        ]
    )

    #expect(AuthoredDeck.validate(at: bundle).contains { $0.code == "AD020" })
}

@Test func authoredDeckAcceptsCompleteTemplateAndFieldVocabulary() throws {
    let directory = try authoredTestDirectory()
    let type =
        #"{"kind":"type","id":"Multimedia","name":"Multimedia","fields":[{"id":"cue","name":"Cue","type":"text","required":true},{"id":"score","name":"Score","type":"number"},{"id":"audio","name":"Audio","type":"audio"},{"id":"image","name":"Image","type":"image"},{"id":"gif","name":"GIF","type":"gif"},{"id":"video","name":"Video","type":"video"}],"templates":[{"name":"Media recall","prompt":[{"literal":"Listen: ","reveal":"blurred"},{"field":"audio","media":"autoplay"}],"answer":[{"field":"cue"},{"field":"image"}],"interaction":"record","skill":{"input":"audio","output":"freeResponse","operation":"reproduce"},"generateWhen":{"all":[{"fieldNotEmpty":"cue"},{"any":[{"fieldNotEmpty":"audio"},{"fieldNotEmpty":"video"}]}]}}]}"#
    let bundle = try authoredBundle(
        in: directory,
        manifestRecords: [authoredManifest, type, authoredDeck],
        itemRecords: [
            #"{"kind":"item","deck":"root","type":"Multimedia","fields":{"cue":{"text":"Cue"},"score":{"number":2.5},"audio":null,"image":null,"gif":null,"video":null}}"#,
        ]
    )

    #expect(AuthoredDeck.validate(at: bundle).isEmpty)
}

@Test func authoredDeckRepeatedImportReusesSchema() async throws {
    let directory = try authoredTestDirectory()
    let bundle = try authoredBundle(
        in: directory,
        manifestRecords: [authoredManifest, authoredType, authoredDeck],
        itemRecords: [
            #"{"kind":"item","deck":"root","type":"Study","fields":{"front":{"text":"Q"},"back":{"rich":[{"text":"A"}]}}}"#,
        ]
    )
    let store = try ItemStore(databaseURL: directory.appendingPathComponent("library.sqlite"))
    try await store.bootstrap()
    let initialTypeCount = try await store.listItemTypes().count

    let first = try await AuthoredDeck.importDeck(from: bundle, into: store)
    let second = try await AuthoredDeck.importDeck(from: bundle, into: store)

    #expect(first.createdItemTypeCount == 1)
    #expect(second.createdItemTypeCount == 0)
    #expect(second.reusedItemTypeCount == 1)
    #expect(try await store.listItemTypes().count == initialTypeCount + 1)
    #expect(try await store.listItems().count == 2)
}

@Test func authoredDeckReportsIndependentMalformedLines() throws {
    let directory = try authoredTestDirectory()
    let bundle = try authoredBundle(
        in: directory,
        manifestRecords: [
            authoredManifest,
            "{broken",
            #"{"kind":"deck","id":"root","name":"Root","surprise":true}"#,
        ],
        itemRecords: ["not-json"]
    )

    let diagnostics = AuthoredDeck.validate(at: bundle)

    #expect(diagnostics.count == 3)
    #expect(Set(diagnostics.map(\.code)).isSuperset(of: ["AD016", "AD020"]))
    #expect(diagnostics.contains(where: { $0.file == "items/items.jsonl" }))
}

@Test func authoredDeckRejectsDuplicateJSONMembersAtAnyDepth() throws {
    let directory = try authoredTestDirectory()
    let bundle = try authoredBundle(
        in: directory,
        manifestRecords: [
            authoredManifest,
            authoredType,
            #"{"kind":"deck","id":"root","name":"One","name":"Two"}"#,
        ],
        itemRecords: [
            #"{"kind":"item","deck":"root","type":"Study","fields":{"front":{"text":"Q","text":"Duplicate"},"back":{"rich":[{"text":"A"}]}}}"#,
        ]
    )

    let diagnostics = AuthoredDeck.validate(at: bundle)

    #expect(diagnostics.filter { $0.code == "AD032" }.count == 2)
}

@Test func authoredDeckEnforcesAggregateSourceByteLimitBeforeCompilation() throws {
    let directory = try authoredTestDirectory()
    let bundle = try authoredBundle(
        in: directory,
        manifestRecords: [authoredManifest, authoredType, authoredDeck],
        itemRecords: []
    )
    let limits = AuthoredDeckLimits(
        maximumSourceBytes: 1_000_000,
        maximumTotalSourceBytes: 100
    )

    let diagnostics = AuthoredDeck.validate(at: bundle, limits: limits)

    #expect(diagnostics.contains(where: { $0.code == "AD018" }))
}

@Test func authoredDeckRejectsUndeclaredItemParts() throws {
    let directory = try authoredTestDirectory()
    let bundle = try authoredBundle(
        in: directory,
        manifestRecords: [authoredManifest, authoredType, authoredDeck],
        itemRecords: []
    )
    try #"{"kind":"item","deck":"root","type":"Study","fields":{}}"#.write(
        to: bundle.appendingPathComponent("items/undeclared.jsonl"),
        atomically: true,
        encoding: .utf8
    )

    let diagnostics = AuthoredDeck.validate(at: bundle)

    #expect(diagnostics.contains(where: { $0.code == "AD109" }))
}

@Test func authoredDeckRejectsSymlinkInItemPartPath() throws {
    let directory = try authoredTestDirectory()
    let bundle = try authoredBundle(
        in: directory,
        manifestRecords: [
            #"{"kind":"neoanki","version":1,"root":"root","parts":["items/link/items.jsonl"]}"#,
            authoredType,
            authoredDeck,
        ],
        itemRecords: []
    )
    let outside = directory.appendingPathComponent("outside-items", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data().write(to: outside.appendingPathComponent("items.jsonl"))
    try FileManager.default.createSymbolicLink(
        at: bundle.appendingPathComponent("items/link"),
        withDestinationURL: outside
    )

    let diagnostics = AuthoredDeck.validate(at: bundle)

    #expect(diagnostics.contains(where: { $0.code == "AD108" }))
}

@Test func authoredDeckRejectsMediaTraversalWithoutMutation() async throws {
    let directory = try authoredTestDirectory()
    let bundle = try authoredBundle(
        in: directory,
        manifestRecords: [authoredManifest, authoredType, authoredDeck],
        itemRecords: [
            #"{"kind":"item","deck":"root","type":"Study","fields":{"front":{"text":"Q"},"back":{"rich":[{"text":"A"}]},"image":{"media":{"path":"media/../outside.png"}}}}"#,
        ]
    )
    var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    png.append(0x41)
    try png.write(to: bundle.appendingPathComponent("outside.png"))
    let store = try ItemStore(databaseURL: directory.appendingPathComponent("library.sqlite"))
    try await store.bootstrap()

    await #expect(throws: AuthoredDeckError.self) {
        try await AuthoredDeck.importDeck(from: bundle, into: store)
    }
    #expect(try await store.listDecks().isEmpty)
    #expect(try await store.listItems().isEmpty)
}

@Test func authoredDeckRejectsSymlinkedMediaDirectory() throws {
    let directory = try authoredTestDirectory()
    let bundle = try authoredBundle(
        in: directory,
        manifestRecords: [authoredManifest, authoredType, authoredDeck],
        itemRecords: [
            #"{"kind":"item","deck":"root","type":"Study","fields":{"front":{"text":"Q"},"back":{"rich":[{"text":"A"}]},"image":{"media":{"path":"media/outside.png"}}}}"#,
        ]
    )
    let outside = directory.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    png.append(0x41)
    try png.write(to: outside.appendingPathComponent("outside.png"))
    try FileManager.default.createSymbolicLink(
        at: bundle.appendingPathComponent("media"),
        withDestinationURL: outside
    )

    let diagnostics = AuthoredDeck.validate(at: bundle)

    #expect(diagnostics.contains(where: { $0.code == "AD251" || $0.code == "AD252" }))
}

@Test func authoredDeckImportsValidatedRelativeMedia() async throws {
    let directory = try authoredTestDirectory()
    let bundle = try authoredBundle(
        in: directory,
        manifestRecords: [authoredManifest, authoredType, authoredDeck],
        itemRecords: [
            #"{"kind":"item","deck":"root","type":"Study","fields":{"front":{"text":"Q"},"back":{"rich":[{"text":"A"}]},"image":{"media":{"path":"media/cell.png","alt":"Cell"}}}}"#,
        ]
    )
    let mediaDirectory = bundle.appendingPathComponent("media", isDirectory: true)
    try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
    var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    png.append(0x41)
    try png.write(to: mediaDirectory.appendingPathComponent("cell.png"))
    let mediaStore = try MediaStore(rootDirectory: directory.appendingPathComponent("storage"))
    let store = try ItemStore(
        databaseURL: directory.appendingPathComponent("library.sqlite"),
        mediaStore: mediaStore
    )
    try await store.bootstrap()

    _ = try await AuthoredDeck.importDeck(from: bundle, into: store)

    let summary = try #require((try await store.listItems()).first)
    let loaded = try #require(await store.fetchItem(id: summary.id))
    guard case let .media(ref) = loaded.item.fields[3].value else {
        Issue.record("Expected imported media")
        return
    }
    #expect(ref.altText == "Cell")
    #expect(try await store.mediaAsset(hash: ref.assetHash)?.byteSize == png.count)
}

@Test func authoredDeckRejectsMissingRequiredFieldAtomically() async throws {
    let directory = try authoredTestDirectory()
    let bundle = try authoredBundle(
        in: directory,
        manifestRecords: [authoredManifest, authoredType, authoredDeck],
        itemRecords: [
            #"{"kind":"item","deck":"root","type":"Study","fields":{"back":{"rich":[{"text":"A"}]}}}"#,
        ]
    )
    let store = try ItemStore(databaseURL: directory.appendingPathComponent("library.sqlite"))
    try await store.bootstrap()

    await #expect(throws: AuthoredDeckError.self) {
        try await AuthoredDeck.importDeck(from: bundle, into: store)
    }
    #expect(try await store.listDecks().isEmpty)
    #expect(try await store.listItems().isEmpty)
}
