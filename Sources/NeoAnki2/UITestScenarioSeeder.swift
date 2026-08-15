import Foundation
import NeoAnkiApplication
import NeoAnkiCore

enum UITestScenarioSeeder {
    static func seedIfRequested(store: any LibraryScenarioSeeding) async throws {
        guard AppDatabase.isTesting,
              let scenario = ProcessInfo.processInfo.environment["NEOANKI_TEST_SCENARIO"],
              !scenario.isEmpty
        else {
            return
        }

        try await seed(
            scenario: scenario,
            environment: ProcessInfo.processInfo.environment,
            store: store
        )
    }

    static func seed(
        scenario: String?,
        environment: [String: String],
        store: any LibraryScenarioSeeding
    ) async throws {
        guard let scenario, !scenario.isEmpty else { return }

        switch scenario {
        case "study-type":
            try await seedTextInteraction(.type, store: store, answer: "Paris")
        case "study-choose":
            try await seedTextInteraction(.choose, store: store, answer: "Paris")
        case "study-arrange":
            try await seedTextInteraction(.arrange, store: store, answer: "one two three")
        case "study-record":
            try await seedTextInteraction(.record, store: store, answer: "Spoken answer")
        case "study-cloze":
            try await seedCloze(store: store)
        case "study-reverse":
            try await seedReverseStudy(store: store)
        case "study-edit":
            try await seedBasicItem(
                front: "Capital of Frnace",
                back: "Paris",
                store: store
            )
        case "library-browse":
            try await seedLibraryBrowse(store: store)
        case "scheduling-history":
            try await seedSchedulingHistory(store: store)
        case "image-missing-description":
            try await seedImageMissingDescription(store: store)
        case "deck-with-due-items":
            try await seedDeckWithDueItems(store: store)
        case "deck-scoping":
            try await seedDeckScoping(store: store)
        case "portable-export-source":
            try await seedPortableExportSource(store: store)
        case "type-conflict-local":
            try await seedTypeConflictLocal(environment: environment, store: store)
        case "corrupted-item-type":
            try await seedCorruptedItemType(store: store)
        case "import-with-media":
            try await seedImportWithMedia(environment: environment, store: store)
        case "alternate-import-type":
            try await seedAlternateImportType(store: store)
        case "authoring-fields":
            try await seedAuthoringFieldTypes(store: store)
        case "deck-included-item-types":
            try await seedDeckIncludedItemTypes(store: store)
        case "item-type-risky-edit":
            try await seedRiskyItemTypeEdit(store: store)
        default:
            break
        }
    }

    private static func seedDeckIncludedItemTypes(store: any LibraryScenarioSeeding) async throws {
        try await importIncludedDeck(
            deckName: "Poetry Lab",
            typeName: "Poem Line",
            promptName: "Previous Lines",
            answerName: "Next Line",
            store: store
        )
        try await importIncludedDeck(
            deckName: "Language Lab",
            typeName: "Translation Entry",
            promptName: "Expression",
            answerName: "Translation",
            store: store
        )
    }

    private static func seedRiskyItemTypeEdit(store: any LibraryScenarioSeeding) async throws {
        let front = FieldDef(name: "Front", type: .text, isRequired: true)
        let back = FieldDef(name: "Back", type: .text, isRequired: true)
        let notes = FieldDef(name: "Notes", type: .text)
        let template = Template(
            name: "Card",
            prompt: Side(slots: [Slot(source: .field(front.id))]),
            answer: Side(slots: [Slot(source: .field(back.id))]),
            interaction: .reveal,
            skill: Skill(input: .text, output: .text, operation: .recall)
        )
        let itemType = ItemType(
            name: "Risky Edit",
            fields: [front, back, notes],
            templates: [template]
        )
        _ = try await store.createItemType(itemType)
        _ = try await store.createItem(
            Item(
                itemTypeID: itemType.id,
                fields: [
                    FieldValue(fieldID: front.id, value: .text("Question")),
                    FieldValue(fieldID: back.id, value: .text("Answer")),
                    FieldValue(fieldID: notes.id, value: .text("Keep this content")),
                ]
            )
        )
    }

    private static func importIncludedDeck(
        deckName: String,
        typeName: String,
        promptName: String,
        answerName: String,
        store: any LibraryScenarioSeeding
    ) async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoanki-ui-included-\(UUID().uuidString)", isDirectory: true)
        let bundle = workspace.appendingPathComponent("Fixture.neoanki", isDirectory: true)
        let items = bundle.appendingPathComponent("items", isDirectory: true)
        try FileManager.default.createDirectory(at: items, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let records = [
            #"{"kind":"neoanki","version":3,"root":"root","parts":["items/items.jsonl"]}"#,
            """
            {"kind":"type","id":"included","name":"\(typeName)","fields":[{"id":"prompt","name":"\(promptName)","type":"text","required":true},{"id":"answer","name":"\(answerName)","type":"text","required":true}],"templates":[{"name":"Recall","prompt":[{"field":"prompt"}],"answer":[{"field":"answer"}],"interaction":"reveal","skill":{"input":"text","output":"text","operation":"recall"}}]}
            """,
            """
            {"kind":"deck","id":"root","name":"\(deckName)","itemTypes":["included"],"defaultType":"included"}
            """,
        ]
        try (records.joined(separator: "\n") + "\n").write(
            to: bundle.appendingPathComponent(AuthoredDeck.manifestName),
            atomically: true,
            encoding: .utf8
        )
        try Data().write(to: items.appendingPathComponent("items.jsonl"))
        _ = try await store.importAuthoredDeck(from: bundle)
    }

    private static func seedTextInteraction(
        _ interaction: Interaction,
        store: any LibraryScenarioSeeding,
        answer: String
    ) async throws {
        let prompt = FieldDef(name: "Prompt", type: .text, isRequired: true)
        let answerField = FieldDef(name: "Answer", type: .text, isRequired: true)
        let template = Template(
            name: interaction.rawValue.capitalized,
            prompt: Side(slots: [Slot(source: .field(prompt.id))]),
            answer: Side(slots: [Slot(source: .field(answerField.id))]),
            interaction: interaction,
            skill: Skill(
                input: .text,
                output: interaction == .choose ? .selection : .freeResponse,
                operation: interaction == .arrange ? .order : .recall
            )
        )
        let itemType = ItemType(
            name: "UI \(interaction.rawValue.capitalized)",
            fields: [prompt, answerField],
            templates: [template]
        )
        _ = try await store.createItemType(itemType)
        _ = try await store.createItem(
            Item(
                itemTypeID: itemType.id,
                fields: [
                    FieldValue(fieldID: prompt.id, value: .text("Question cue")),
                    FieldValue(fieldID: answerField.id, value: .text(answer)),
                ]
            )
        )
    }

    private static func seedCloze(store: any LibraryScenarioSeeding) async throws {
        _ = try await store.createItem(
            Item(
                itemTypeID: BuiltInItemTypes.clozeID,
                fields: [
                    FieldValue(
                        fieldID: BuiltInItemTypes.clozeTextFieldID,
                        value: .cloze(
                            "The capital of France is Paris.",
                            blanks: [ClozeSpan(group: 1, start: 25, length: 5)]
                        )
                    ),
                    FieldValue(
                        fieldID: BuiltInItemTypes.clozeContextFieldID,
                        value: .rich([Span("European capitals")])
                    ),
                ]
            )
        )
    }

    private static func seedReverseStudy(store: any LibraryScenarioSeeding) async throws {
        let front = FieldDef(name: "Front", type: .text, isRequired: true)
        let back = FieldDef(name: "Back", type: .text, isRequired: true)
        let forward = Template(
            name: "Card",
            prompt: Side(slots: [Slot(source: .field(front.id))]),
            answer: Side(slots: [Slot(source: .field(back.id))]),
            interaction: .reveal,
            skill: Skill(input: .text, output: .text, operation: .recall)
        )
        let reverse = Template(
            name: "Reverse",
            prompt: Side(slots: [Slot(source: .field(back.id))]),
            answer: Side(slots: [Slot(source: .field(front.id))]),
            interaction: .reveal,
            skill: Skill(input: .text, output: .text, operation: .recall)
        )
        let itemType = ItemType(
            name: "UI Reverse",
            fields: [front, back],
            templates: [forward, reverse]
        )
        _ = try await store.createItemType(itemType)
        _ = try await store.createItem(
            Item(
                itemTypeID: itemType.id,
                fields: [
                    FieldValue(fieldID: front.id, value: .text("Reverse Q")),
                    FieldValue(fieldID: back.id, value: .text("Reverse A")),
                ]
            )
        )
    }

    private static func seedBasicItem(
        front: String,
        back: String,
        store: any LibraryScenarioSeeding
    ) async throws {
        _ = try await store.createItem(
            Item(
                itemTypeID: BuiltInItemTypes.basicID,
                fields: [
                    FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text(front)),
                    FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text(back)),
                ]
            )
        )
    }

    private static func seedLibraryBrowse(store: any LibraryScenarioSeeding) async throws {
        let target = try await store.createDeck(Deck(name: "Target Deck"))
        let history = try await store.createDeck(Deck(name: "History"))
        let keep = try await store.createDeck(Deck(name: "Keep Deck"))
        let unassigned = [
            ("Original", "Answer"),
            ("Keep Item", "Still Here"),
            ("Remove", "Me"),
            ("Movable", "Item"),
            ("Browse Delete", "Answer"),
            ("Browse Move", "Answer"),
        ]
        for (front, back) in unassigned {
            try await seedBasicItem(front: front, back: back, store: store)
        }
        for (front, back, deckID) in [
            ("Deck Item", "B", keep.id),
            ("Target Seed", "Target", target.id),
            ("History Seed", "History", history.id),
        ] {
            _ = try await store.createItem(
                Item(
                    itemTypeID: BuiltInItemTypes.basicID,
                    fields: [
                        FieldValue(
                            fieldID: BuiltInItemTypes.frontFieldID,
                            value: .text(front)
                        ),
                        FieldValue(
                            fieldID: BuiltInItemTypes.backFieldID,
                            value: .text(back)
                        ),
                    ],
                    deckID: deckID
                )
            )
        }
    }

    private static func seedSchedulingHistory(store: any LibraryScenarioSeeding) async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await store.createItem(
            Item(
                itemTypeID: BuiltInItemTypes.basicID,
                fields: [
                    FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("History")),
                    FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Seed")),
                ]
            ),
            asOf: start
        )
        guard let card = try await store.dueCards(
            scope: .allDecks,
            asOf: start,
            limit: nil
        ).first else { return }
        for index in 0..<130 {
            let rating: ReviewRating = index == 0 || index % 5 != 0 ? .good : .again
            _ = try await store.submitReview(
                cardID: card.id,
                rating: rating,
                asOf: start.addingTimeInterval(Double(index * 12) * 86_400),
                durationMilliseconds: 1_000
            )
        }
        // The reviewed card is now scheduled years out. Two fresh cards let the
        // journey grade one, explicitly end with another still due, and verify
        // that automatic fitting never interrupts the session.
        _ = try await store.createItem(
            Item(
                itemTypeID: BuiltInItemTypes.basicID,
                fields: [
                    FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Due card")),
                    FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Due answer")),
                ]
            )
        )
        _ = try await store.createItem(
            Item(
                itemTypeID: BuiltInItemTypes.basicID,
                fields: [
                    FieldValue(
                        fieldID: BuiltInItemTypes.frontFieldID,
                        value: .text("Remaining due card")
                    ),
                    FieldValue(
                        fieldID: BuiltInItemTypes.backFieldID,
                        value: .text("Remaining due answer")
                    ),
                ]
            )
        )
    }

    private static func seedImageMissingDescription(store: any LibraryScenarioSeeding) async throws {
        let image = FieldDef(name: "Image", type: .image, isRequired: true)
        let caption = FieldDef(name: "Caption", type: .text, isRequired: true)
        let template = Template(
            name: "Recognize",
            prompt: Side(slots: [Slot(source: .field(image.id))]),
            answer: Side(slots: [Slot(source: .field(caption.id))]),
            interaction: .reveal,
            skill: Skill(input: .image, output: .text, operation: .recognize)
        )
        let itemType = ItemType(
            name: "UI Image",
            fields: [image, caption],
            templates: [template]
        )
        _ = try await store.createItemType(itemType)
        guard let mediaStore = await store.mediaStore(),
              let bytes = Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
              )
        else {
            return
        }
        let ref = try await mediaStore.ingest(data: bytes, kind: .image, fileExtension: "png")
        _ = try await store.createItem(
            Item(
                itemTypeID: itemType.id,
                fields: [
                    FieldValue(fieldID: image.id, value: .media(ref)),
                    FieldValue(fieldID: caption.id, value: .text("A diagram")),
                ]
            )
        )
    }

    private static func seedDeckWithDueItems(store: any LibraryScenarioSeeding) async throws {
        let deck = try await store.createDeck(Deck(name: "Due Deck"))
        for index in 1...3 {
            _ = try await store.createItem(
                Item(
                    itemTypeID: BuiltInItemTypes.basicID,
                    fields: [
                        FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Due \(index)")),
                        FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer \(index)")),
                    ],
                    deckID: deck.id
                )
            )
        }
    }

    private static func seedDeckScoping(store: any LibraryScenarioSeeding) async throws {
        let deck = try await store.createDeck(Deck(name: "Scoped"))
        try await seedBasicItem(
            front: "Unassigned Item",
            back: "A",
            store: store
        )
        _ = try await store.createItem(
            Item(
                itemTypeID: BuiltInItemTypes.basicID,
                fields: [
                    FieldValue(
                        fieldID: BuiltInItemTypes.frontFieldID,
                        value: .text("Deck Item")
                    ),
                    FieldValue(
                        fieldID: BuiltInItemTypes.backFieldID,
                        value: .text("B")
                    ),
                ],
                deckID: deck.id
            )
        )
    }

    private static func seedPortableExportSource(store: any LibraryScenarioSeeding) async throws {
        let deck = try await store.createDeck(Deck(name: "Export Deck"))
        _ = try await store.createItem(
            Item(
                itemTypeID: BuiltInItemTypes.basicID,
                fields: [
                    FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Export Front")),
                    FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Export Back")),
                ],
                deckID: deck.id
            )
        )
    }

    private static func seedTypeConflictLocal(
        environment: [String: String],
        store: any LibraryScenarioSeeding
    ) async throws {
        guard let fixtureDirectory = environment["NEOANKI_TEST_FIXTURE_DIR"],
              !fixtureDirectory.isEmpty
        else {
            return
        }
        let firstURL = URL(fileURLWithPath: fixtureDirectory, isDirectory: true)
            .appendingPathComponent("conflict-first.neodeck")
        guard FileManager.default.fileExists(atPath: firstURL.path) else { return }
        _ = try await store.importPortableDeck(from: firstURL, conflictResolution: .reject)

        let loaded = try await store.loadItemTypes()
        if let customType = loaded.itemTypes.first(where: { $0.name == "Portable Custom" }) {
            var revised = customType
            revised.name = "Portable Custom Revised"
            _ = try await store.updateItemType(revised)
        }
    }

    private static func seedCorruptedItemType(store: any LibraryScenarioSeeding) async throws {
        let good = try ItemTypeBuilder.makeItemType(
            name: "Good",
            fields: [
                FieldDef(name: "Front", type: .text),
                FieldDef(name: "Back", type: .text),
            ]
        )
        let damaged = try ItemTypeBuilder.makeItemType(
            name: "Damaged",
            fields: [
                FieldDef(name: "Front", type: .text),
                FieldDef(name: "Back", type: .text),
            ]
        )
        _ = try await store.createItemType(good)
        _ = try await store.createItemType(damaged)
        _ = try await store.createItem(
            Item(
                itemTypeID: good.id,
                fields: [
                    FieldValue(fieldID: good.fields[0].id, value: .text("Good question")),
                    FieldValue(fieldID: good.fields[1].id, value: .text("Good answer")),
                ]
            )
        )
        try await store.corruptItemTypeDefinitionForTesting(id: damaged.id)
        _ = try await store.loadItemTypes()
    }

    private static func seedImportWithMedia(
        environment: [String: String],
        store: any LibraryScenarioSeeding
    ) async throws {
        guard let fixtureDirectory = environment["NEOANKI_TEST_FIXTURE_DIR"],
              !fixtureDirectory.isEmpty
        else {
            return
        }
        let mediaDirectory = URL(fileURLWithPath: fixtureDirectory, isDirectory: true)
            .appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let pngBytes = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        try pngBytes.write(to: mediaDirectory.appendingPathComponent("cover.png"))
    }

    private static func seedAlternateImportType(store: any LibraryScenarioSeeding) async throws {
        let front = FieldDef(name: "Front", type: .text, isRequired: true)
        let back = FieldDef(name: "Back", type: .text, isRequired: true)
        let template = Template(
            name: "Basic",
            prompt: Side(slots: [Slot(source: .field(front.id))]),
            answer: Side(slots: [Slot(source: .field(back.id))]),
            interaction: .reveal,
            skill: Skill(input: .text, output: .text, operation: .recall)
        )
        let itemType = ItemType(name: "Alternate", fields: [front, back], templates: [template])
        _ = try await store.createItemType(itemType)
    }

    private static func seedAuthoringFieldTypes(store: any LibraryScenarioSeeding) async throws {
        _ = try await store.createDeck(Deck(name: "Empty Deck"))
        try await createAuthoringItemType(
            name: "Numeric",
            frontType: .richText,
            backType: .number,
            store: store
        )
        try await createAuthoringItemType(
            name: "Secondary",
            frontType: .richText,
            backType: .richText,
            store: store
        )
        try await createAuthoringItemType(
            name: "Cloze Author",
            frontType: .cloze,
            backType: .richText,
            store: store
        )
    }

    private static func createAuthoringItemType(
        name: String,
        frontType: FieldType,
        backType: FieldType,
        store: any LibraryScenarioSeeding
    ) async throws {
        let front = FieldDef(name: "Front", type: frontType, isRequired: true)
        let back = FieldDef(name: "Back", type: backType, isRequired: true)
        let template = Template(
            name: "Card",
            prompt: Side(slots: [Slot(source: .field(front.id))]),
            answer: Side(slots: [Slot(source: .field(back.id))]),
            interaction: frontType == .cloze ? .cloze : .reveal,
            skill: Skill(input: .text, output: .text, operation: .recall)
        )
        _ = try await store.createItemType(
            ItemType(name: name, fields: [front, back], templates: [template])
        )
    }
}
