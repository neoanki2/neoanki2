import Foundation
import NeoAnkiCore
import NeoAnkiDeckBuilderKit
import PoemDeckBuilder
import Testing

@Test func poemBuilderNormalizesLineEndingsAndPreservesStanzas() {
    let poem = PoemDeckGenerator.parse(" first\r\n\r\nsecond\rthird\n   \nfourth ")
    let lines = PoemDeckGenerator.usableLines(in: "first\r\n\r\nsecond\rthird\n   \nfourth")

    #expect(lines == ["first", "second", "third", "fourth"])
    #expect(poem.stanzas == [["first"], ["second", "third"], ["fourth"]])
    #expect(poem.lines.map(\.startsStanza) == [false, true, false, true])
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
    #expect(manifest.contains(#""version":5"#))
    #expect(manifest.contains(#""operation":"recall""#))
    #expect(!manifest.contains(#""operation":"recognize""#))

    let manifestRecords = try jsonLines(
        at: generated.bundleURL.appendingPathComponent("deck.jsonl")
    )
    let typeRecord = try #require(manifestRecords.first { $0["kind"] as? String == "type" })
    let fields = try #require(typeRecord["fields"] as? [[String: Any]])
    #expect(fields.map { $0["id"] as? String } == [
        "front", "back", "attribution", "stanza-break",
    ])
    #expect(fields.last?["name"] as? String == "Stanza Break")
    #expect(fields.last?["required"] as? Bool == false)
    let templates = try #require(typeRecord["templates"] as? [[String: Any]])
    let template = try #require(templates.first)
    #expect(template["layout"] as? String == "focus")
    let components = try #require(template["components"] as? [[String: Any]])
    #expect(components.map { $0["region"] as? String } == [
        "label", "primary", "secondary", "secondary",
    ])
    #expect(components.map { $0["purpose"] as? String } == [
        "supporting", "question", "expectedAnswer", "expectedAnswer",
    ])
    #expect(components.map { $0["field"] as? String } == [
        "attribution", "front", "stanza-break", "back",
    ])
    #expect(components.map { $0["reveal"] as? String } == [
        "always", "always", "hiddenUntilAnswer", "hiddenUntilAnswer",
    ])

    let records = try jsonLines(
        at: generated.bundleURL.appendingPathComponent("items/poem.jsonl")
    )
    #expect(records.count == 3)
    #expect(records.allSatisfy { ($0["tags"] as? [String]) == ["author:Ліна"] })
    #expect(records.allSatisfy {
        textField("attribution", in: $0) == "спини мене отямся і отям · Ліна"
    })
    #expect(textField("front", in: records[0]) == "line one")
    #expect(textField("back", in: records[0]) == #"line "two""#)
    #expect(textField("front", in: records[1]) == "line one\nline \"two\"")
    #expect(textField("back", in: records[1]) == "line three")
    #expect(textField("front", in: records[2]) == "line \"two\"\nline three")
    #expect(textField("back", in: records[2]) == "line four")
}

@Test func poemBuilderMarksStanzaStartsOnlyAfterReveal() throws {
    let generated = try PoemDeckGenerator.generate(
        input: PoemDeckInput(
            destinationDeckID: UUID(),
            author: "Author",
            title: "Poem",
            text: "one\ntwo\n\n\nthree\nfour"
        )
    )
    defer { generated.cleanup() }

    let records = try jsonLines(
        at: generated.bundleURL.appendingPathComponent("items/poem.jsonl")
    )
    #expect(records.count == 3)
    #expect(textField("front", in: records[1]) == "one\ntwo")
    #expect(textField("back", in: records[1]) == "three")
    #expect(textField("stanza-break", in: records[0]) == nil)
    #expect(textField("stanza-break", in: records[1]) == "Stanza break")
    #expect(textField("stanza-break", in: records[2]) == nil)
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
    let attribution = try #require(loaded.itemType.field(named: "Attribution"))
    #expect(loaded.item.value(for: attribution.id) == .text("спини мене отямся і отям · Ліна"))
    let template = try #require(loaded.itemType.templates.first)
    #expect(template.layout == .focus)
    let resolved = SideContent.resolvedComponents(for: template, from: loaded.item)
    #expect(resolved.map(\.region) == [.label, .primary, .secondary])
    #expect(resolved.map(\.purpose) == [.supporting, .question, .expectedAnswer])
    #expect(resolved.first?.value == .text("спини мене отямся і отям · Ліна"))
    #expect(resolved.first?.presentation.reveal == .always)
    #expect(resolved.last?.presentation.reveal == .hiddenUntilAnswer)
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

@Test func poemReconciliationRepairsCopiedContextAndAddsRevealedStanzaFeedback() throws {
    let fixture = poemFixture(
        lines: ["one", "two", "three", "four"],
        corruptedPromptAtAnswerIndex: 3
    )
    let records = [fixture.records[2], fixture.records[0], fixture.records[1]]

    let snapshot = try PoemDeckReconciler.snapshot(records: records)
    #expect(snapshot.sourceText == "one\ntwo\nthree\nfour")
    #expect(snapshot.mismatches.count == 1)

    let preview = try PoemDeckReconciler.preview(
        sourceText: "one\ntwo\n\nthree\nfour",
        records: records
    )
    #expect(preview.poem.stanzas.count == 2)
    #expect(preview.repairedMismatchCount == 1)
    #expect(preview.changes.count == 2)
    #expect(preview.updatedItemType.fields.contains {
        $0.name == PoemDeckReconciler.stanzaBreakFieldName && !$0.isRequired
    })
    let marker = try #require(preview.updatedItemType.field(
        named: PoemDeckReconciler.stanzaBreakFieldName
    ))
    let markerComponent = try #require(preview.updatedItemType.templates[0].components.first {
        $0.source == .field(marker.id)
    })
    #expect(markerComponent.purpose == .expectedAnswer)
    #expect(markerComponent.presentation.reveal == .hiddenUntilAnswer)
    try PoemDeckReconciler.validateGeneratedChain(
        items: preview.replacements,
        itemType: preview.updatedItemType
    )
}

@Test func poemReconciliationRejectsLineCountChangesAndAmbiguousChains() throws {
    let fixture = poemFixture(lines: ["one", "two", "three"])
    #expect(throws: PoemDeckReconciliationError.self) {
        try PoemDeckReconciler.preview(
            sourceText: "one\ntwo\nthree\nfour",
            records: fixture.records
        )
    }

    let front = try #require(fixture.itemType.field(named: "Front"))
    let back = try #require(fixture.itemType.field(named: "Back"))
    let duplicateA = Item(
        itemTypeID: fixture.itemType.id,
        fields: [
            .init(fieldID: front.id, value: .text("one\ntwo")),
            .init(fieldID: back.id, value: .text("branch A")),
        ]
    )
    let duplicateB = Item(
        itemTypeID: fixture.itemType.id,
        fields: [
            .init(fieldID: front.id, value: .text("one\ntwo")),
            .init(fieldID: back.id, value: .text("branch B")),
        ]
    )
    let ambiguous = [
        fixture.records[0],
        PoemDeckItemRecord(item: duplicateA, itemType: fixture.itemType),
        PoemDeckItemRecord(item: duplicateB, itemType: fixture.itemType),
    ]
    #expect(throws: PoemDeckReconciliationError.self) {
        try PoemDeckReconciler.snapshot(records: ambiguous)
    }
}

@Test func atomicPoemReconciliationPreservesCardIdentityMemoryAndReviews() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("poem-reconcile-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ItemStore(databaseURL: directory.appendingPathComponent("library.sqlite"))
    try await store.bootstrap()

    let fixture = poemFixture(
        lines: ["one", "two", "three", "four"],
        corruptedPromptAtAnswerIndex: 3
    )
    _ = try await store.createItemType(fixture.itemType)
    let deck = try await store.createDeck(Deck(name: "Poem"))
    for record in fixture.records {
        var item = record.item
        item.deckID = deck.id
        _ = try await store.createItem(item)
    }

    let cardsBefore = try await store.fetchDueCards(
        scope: .deck(deck.id, includeDescendants: false),
        asOf: .now,
        limit: nil
    )
    let reviewedCard = try #require(cardsBefore.first)
    _ = try await store.submitReviewWithReceipt(
        cardID: reviewedCard.id,
        rating: .good,
        now: .now,
        durationMs: 1_000
    )
    let reviewedState = try await store.card(id: reviewedCard.id).memory
    #expect(try await store.reviewLogCount(for: reviewedCard.id) == 1)

    let summaries = try await store.listItems(
        scope: .deck(deck.id, includeDescendants: false),
        sort: .createdAscending
    )
    var storedRecords: [PoemDeckItemRecord] = []
    for summary in summaries {
        let loaded = try #require(await store.fetchItem(id: summary.id))
        storedRecords.append(.init(item: loaded.item, itemType: loaded.itemType))
    }
    let preview = try PoemDeckReconciler.preview(
        sourceText: "one\ntwo\n\nthree\nfour",
        records: storedRecords
    )
    let changedIDs = Set(preview.changes.map(\.itemID))
    let results = try await store.reconcileItemTypeAndItems(
        expectedItemType: preview.originalItemType,
        updatedItemType: preview.updatedItemType,
        replacements: preview.replacements.filter { changedIDs.contains($0.id) }
    )

    #expect(Set(results.flatMap(\.cardIDs)) == Set(cardsBefore.filter {
        changedIDs.contains($0.item.id)
    }.map(\.id)))
    #expect(try await store.card(id: reviewedCard.id).memory == reviewedState)
    #expect(try await store.reviewLogCount(for: reviewedCard.id) == 1)
    let updatedRecords = try await store.listItems(
        scope: .deck(deck.id, includeDescendants: false),
        sort: .createdAscending
    )
    var reloaded: [PoemDeckItemRecord] = []
    for summary in updatedRecords {
        let loaded = try #require(await store.fetchItem(id: summary.id))
        reloaded.append(.init(item: loaded.item, itemType: loaded.itemType))
    }
    #expect(try PoemDeckReconciler.snapshot(records: reloaded).mismatches.isEmpty)
}

@Test func atomicPoemReconciliationPlansEveryReplacementBeforeWriting() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("poem-reconcile-rollback-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ItemStore(databaseURL: directory.appendingPathComponent("library.sqlite"))
    try await store.bootstrap()
    let fixture = poemFixture(lines: ["one", "two", "three"])
    _ = try await store.createItemType(fixture.itemType)
    let deck = try await store.createDeck(Deck(name: "Poem"))
    for record in fixture.records {
        var item = record.item
        item.deckID = deck.id
        _ = try await store.createItem(item)
    }
    let before = try #require(await store.fetchItem(id: fixture.records[0].item.id))
    let preview = try PoemDeckReconciler.preview(
        sourceText: "one\nchanged\nthree",
        records: fixture.records.map {
            var record = $0
            var item = record.item
            item.deckID = deck.id
            record = PoemDeckItemRecord(item: item, itemType: record.itemType)
            return record
        }
    )
    var invalid = preview.replacements[1]
    invalid.deckID = UUID()

    await #expect(throws: Error.self) {
        try await store.reconcileItemTypeAndItems(
            expectedItemType: preview.originalItemType,
            updatedItemType: preview.updatedItemType,
            replacements: [preview.replacements[0], invalid]
        )
    }
    let after = try #require(await store.fetchItem(id: fixture.records[0].item.id))
    #expect(after.item == before.item)
    #expect(after.itemType == before.itemType)
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

private func poemFixture(
    lines: [String],
    corruptedPromptAtAnswerIndex: Int? = nil
) -> (itemType: ItemType, records: [PoemDeckItemRecord]) {
    let front = FieldDef(name: "Front", type: .text, isRequired: true)
    let back = FieldDef(name: "Back", type: .text, isRequired: true)
    let attribution = FieldDef(name: "Attribution", type: .text, isRequired: true)
    let itemType = ItemType(
        name: "Poem Line",
        fields: [front, back, attribution],
        templates: [Template(
            name: "Card",
            layout: .focus,
            components: [
                TemplateComponent(
                    region: .label,
                    purpose: .supporting,
                    source: .field(attribution.id)
                ),
                TemplateComponent(
                    region: .primary,
                    purpose: .question,
                    source: .field(front.id)
                ),
                TemplateComponent(
                    region: .secondary,
                    purpose: .expectedAnswer,
                    source: .field(back.id),
                    presentation: Presentation(reveal: .hiddenUntilAnswer)
                ),
            ],
            interaction: .reveal,
            skill: Skill(input: .text, output: .freeResponse, operation: .recall)
        )]
    )
    let records = (1 ..< lines.count).map { answerIndex in
        let start = max(0, answerIndex - 2)
        var prompt = lines[start ..< answerIndex].joined(separator: "\n")
        if corruptedPromptAtAnswerIndex == answerIndex, answerIndex >= 2 {
            prompt = "wrong\n" + lines[answerIndex - 1]
        }
        let item = Item(
            itemTypeID: itemType.id,
            fields: [
                .init(fieldID: front.id, value: .text(prompt)),
                .init(fieldID: back.id, value: .text(lines[answerIndex])),
                .init(fieldID: attribution.id, value: .text("Poem · Author")),
            ]
        )
        return PoemDeckItemRecord(item: item, itemType: itemType)
    }
    return (itemType, records)
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
