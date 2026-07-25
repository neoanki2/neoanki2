import Foundation
import NeoAnkiCore
import NeoAnkiTestSupport
import Testing

@Test func nativeJSONImportCreatesItemsAndCards() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()

        let json = """
        {
          "itemType": "Basic",
          "rows": [
            { "Front": "One", "Back": "1" },
            { "Front": "Two", "Back": "2", "tags": ["sample"] }
          ]
        }
        """.data(using: .utf8)!

        let imported = try await ctx.store.importItems(
            from: json,
            adapter: JSONImportAdapter(),
            now: ctx.clock.now()
        )
        #expect(imported == 2)
        try await ctx.assertItemCount(2)

        let due = try await ctx.startStudySession()
        #expect(due.count == 2)
    }
}

@Test func nativeCSVImportCreatesItems() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()

        let csv = """
        Front,Back,tags
        Alpha,Beta,tag1
        Gamma,Delta,
        """.data(using: .utf8)!

        let imported = try await ctx.store.importItems(
            from: csv,
            adapter: CSVImportAdapter(itemTypeName: "Basic"),
            now: ctx.clock.now()
        )
        #expect(imported == 2)
        try await ctx.assertItemCount(2)
    }
}

@Test func importRejectsUnknownField() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()

        let json = """
        {
          "itemType": "Basic",
          "rows": [
            { "Front": "Q", "Back": "A", "Unknown": "x" }
          ]
        }
        """.data(using: .utf8)!

        await #expect(throws: ImportError.unknownField("Unknown")) {
            try await ctx.store.importItems(from: json, adapter: JSONImportAdapter())
        }
    }
}

@Test func importRejectsMissingItemType() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()

        let json = """
        {
          "itemType": "Nonexistent",
          "rows": [
            { "Front": "Q", "Back": "A" }
          ]
        }
        """.data(using: .utf8)!

        await #expect(throws: ImportError.itemTypeNotFound("Nonexistent")) {
            try await ctx.store.importItems(from: json, adapter: JSONImportAdapter())
        }
    }
}

@Test func importCanRunTwiceForDuplicateRows() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()

        let json = """
        {
          "itemType": "Basic",
          "rows": [
            { "Front": "Dup", "Back": "A" }
          ]
        }
        """.data(using: .utf8)!

        let first = try await ctx.store.importItems(from: json, adapter: JSONImportAdapter())
        let second = try await ctx.store.importItems(from: json, adapter: JSONImportAdapter())

        #expect(first == 1)
        #expect(second == 1)
        try await ctx.assertItemCount(2)
    }
}

@Test func nativeJSONImportIngestsMediaPathsAndBase64() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()
        let fixture = ItemTypeFixtures.capitals()
        _ = try await ctx.store.createItemType(fixture.type)

        let importDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoanki-media-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: importDirectory, withIntermediateDirectories: true)
        let pngData = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D,
        ] + Array(repeating: UInt8(0), count: 8))
        try pngData.write(to: importDirectory.appendingPathComponent("map.png"))

        let json = """
        {
          "itemType": "Capitals",
          "rows": [
            {
              "Country": "France",
              "Capital": "Paris",
              "Map": { "path": "map.png" }
            },
            {
              "Country": "Japan",
              "Capital": "Tokyo",
              "Map": {
                "base64": "\(pngData.base64EncodedString())",
                "altText": "Map of Japan"
              }
            }
          ]
        }
        """.data(using: .utf8)!

        let imported = try await ctx.store.importItems(
            from: json,
            adapter: JSONImportAdapter(),
            context: ImportContext(baseDirectory: importDirectory)
        )

        #expect(imported == 2)
        let summaries = try await ctx.store.listItems()
        let importedItems = try await summaries.asyncMap { summary in
            try await ctx.store.fetchItem(id: summary.id)?.item
        }.compactMap { $0 }
        let mediaRefs = importedItems.compactMap { item -> MediaRef? in
            guard case let .media(ref)? = item.value(for: fixture.map.id) else { return nil }
            return ref
        }

        #expect(mediaRefs.count == 2)
        #expect(Set(mediaRefs.map(\.assetHash)).count == 1)
        #expect(mediaRefs.first(where: { $0.altText != nil })?.altText == "Map of Japan")
        let mediaStore = try #require(await ctx.store.media)
        for ref in mediaRefs {
            let resolved = try await mediaStore.resolve(ref)
            #expect(FileManager.default.fileExists(atPath: resolved.path))
        }
    }
}

@Test func nativeJSONImportInfersBase64AudioAndVideoFormats() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()
        let title = FieldDef(name: "Title", type: .text, isRequired: true)
        let answer = FieldDef(name: "Answer", type: .text, isRequired: true)
        let audio = FieldDef(name: "Audio", type: .audio)
        let video = FieldDef(name: "Video", type: .video)
        let template = try TemplateBuilder.makeRevealTemplate(
            name: "Card",
            promptFieldID: title.id,
            answerFieldID: answer.id,
            in: ItemType(name: "Media", fields: [title, answer, audio, video], templates: [])
        )
        let itemType = ItemType(
            name: "Media",
            fields: [title, answer, audio, video],
            templates: [template]
        )
        _ = try await ctx.store.createItemType(itemType)

        let audioData = Data([0x00, 0x00, 0x00, 0x18] + Array("ftypM4A ".utf8))
        let videoData = Data([0x00, 0x00, 0x00, 0x18] + Array("ftypisom".utf8))
        let json = """
        {
          "itemType": "Media",
          "rows": [{
            "Title": "Native media",
            "Answer": "Validated",
            "Audio": {
              "base64": "\(audioData.base64EncodedString())",
              "altText": "Spoken example"
            },
            "Video": {
              "base64": "\(videoData.base64EncodedString())",
              "altText": "Demonstration clip"
            }
          }]
        }
        """.data(using: .utf8)!

        #expect(try await ctx.store.importItems(from: json, adapter: JSONImportAdapter()) == 1)
        let summary = try #require(try await ctx.store.listItems().first)
        let item = try #require(try await ctx.store.fetchItem(id: summary.id)?.item)
        guard case let .media(audioRef)? = item.value(for: audio.id),
              case let .media(videoRef)? = item.value(for: video.id)
        else {
            Issue.record("Expected imported audio and video references")
            return
        }
        #expect(audioRef.kind == .audio)
        #expect(audioRef.fileExtension == "m4a")
        #expect(audioRef.altText == "Spoken example")
        #expect(videoRef.kind == .video)
        #expect(videoRef.fileExtension == "mp4")
        #expect(videoRef.altText == "Demonstration clip")
    }
}

@Test func nativeJSONImportRejectsInvalidOrMismatchedBase64Media() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()
        let fixture = ItemTypeFixtures.capitals()
        _ = try await ctx.store.createItemType(fixture.type)

        let invalid = """
        {
          "itemType": "Capitals",
          "rows": [{
            "Country": "Nowhere",
            "Capital": "None",
            "Map": { "base64": "bm90LWEtcG5n" }
          }]
        }
        """.data(using: .utf8)!
        await #expect(throws: ImportError.self) {
            try await ctx.store.importItems(from: invalid, adapter: JSONImportAdapter())
        }

        let gif = Data("GIF89a".utf8)
        let mismatched = """
        {
          "itemType": "Capitals",
          "rows": [{
            "Country": "Nowhere",
            "Capital": "None",
            "Map": { "base64": "\(gif.base64EncodedString())" }
          }]
        }
        """.data(using: .utf8)!
        await #expect(throws: ImportError.self) {
            try await ctx.store.importItems(from: mismatched, adapter: JSONImportAdapter())
        }
    }
}

@Test func nativeJSONImportPersistsStructuredCloze() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()
        let sentence = FieldDef(name: "Sentence", type: .cloze, isRequired: true)
        let explanation = FieldDef(name: "Explanation", type: .text, isRequired: true)
        let template = Template(
            name: "Cloze",
            prompt: Side(slots: [Slot(source: .field(sentence.id))]),
            answer: Side(slots: [Slot(source: .field(explanation.id))]),
            interaction: .reveal,
            skill: Skill(input: .text, output: .text, operation: .recall)
        )
        let itemType = ItemType(
            name: "Cloze Notes",
            fields: [sentence, explanation],
            templates: [template]
        )
        _ = try await ctx.store.createItemType(itemType)

        let json = """
        {
          "itemType": "Cloze Notes",
          "rows": [
            {
              "Sentence": {
                "text": "Paris is in France.",
                "blanks": [
                  { "group": 1, "start": 12, "length": 6, "hint": "country" }
                ]
              },
              "Explanation": "Paris is the capital of France."
            }
          ]
        }
        """.data(using: .utf8)!

        #expect(try await ctx.store.importItems(from: json, adapter: JSONImportAdapter()) == 1)
        let summary = try #require(try await ctx.store.listItems().first)
        let item = try #require(try await ctx.store.fetchItem(id: summary.id)?.item)
        #expect(
            item.value(for: sentence.id) == .cloze(
                "Paris is in France.",
                blanks: [ClozeSpan(group: 1, start: 12, length: 6, hint: "country")]
            )
        )
    }
}

@Test func nativeCSVImportRejectsStructuredFieldsClearly() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()
        let sentence = FieldDef(name: "Sentence", type: .cloze, isRequired: true)
        let explanation = FieldDef(name: "Explanation", type: .text, isRequired: true)
        let template = Template(
            name: "Cloze",
            prompt: Side(slots: [Slot(source: .field(sentence.id))]),
            answer: Side(slots: [Slot(source: .field(explanation.id))]),
            interaction: .reveal,
            skill: Skill(input: .text, output: .text, operation: .recall)
        )
        let itemType = ItemType(
            name: "Cloze Notes",
            fields: [sentence, explanation],
            templates: [template]
        )
        _ = try await ctx.store.createItemType(itemType)
        let csv = "Sentence,Explanation\nParis is in France.,Country fact\n".data(using: .utf8)!

        await #expect(
            throws: ImportError.invalidFormat(
                "CSV cannot import the structured field \"Sentence\". Use JSON for cloze and media fields."
            )
        ) {
            try await ctx.store.importItems(
                from: csv,
                adapter: CSVImportAdapter(itemTypeName: itemType.name),
                itemTypeID: itemType.id
            )
        }
    }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var values: [T] = []
        for element in self {
            values.append(try await transform(element))
        }
        return values
    }
}
