import Foundation
import NeoAnkiCore

enum UITestScenarioSeeder {
    static func seedIfRequested(store: ItemStore) async throws {
        guard AppDatabase.isTesting,
              let scenario = ProcessInfo.processInfo.environment["NEOANKI_TEST_SCENARIO"],
              !scenario.isEmpty
        else {
            return
        }

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
        case "scheduling-history":
            try await seedSchedulingHistory(store: store)
        case "image-missing-description":
            try await seedImageMissingDescription(store: store)
        case "deck-with-due-items":
            try await seedDeckWithDueItems(store: store)
        case "portable-export-source":
            try await seedPortableExportSource(store: store)
        case "type-conflict-local":
            try await seedTypeConflictLocal(store: store)
        case "corrupted-item-type":
            try await seedCorruptedItemType(store: store)
        case "import-with-media":
            try await seedImportWithMedia(store: store)
        case "alternate-import-type":
            try await seedAlternateImportType(store: store)
        default:
            break
        }
    }

    private static func seedTextInteraction(
        _ interaction: Interaction,
        store: ItemStore,
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

    private static func seedCloze(store: ItemStore) async throws {
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

    private static func seedSchedulingHistory(store: ItemStore) async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await store.createItem(
            Item(
                itemTypeID: BuiltInItemTypes.basicID,
                fields: [
                    FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("History")),
                    FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Seed")),
                ]
            ),
            now: start
        )
        guard let card = try await store.fetchDueCards(asOf: start).first else { return }
        for index in 0..<130 {
            let rating: ReviewRating = index == 0 || index % 5 != 0 ? .good : .again
            _ = try await store.submitReviewWithReceipt(
                cardID: card.id,
                rating: rating,
                now: start.addingTimeInterval(Double(index * 12) * 86_400),
                durationMs: 1_000
            )
        }
        // The reviewed card is now scheduled years out, so a second card gives
        // the session something to study — automatic fitting happens when a
        // session ends, and a session needs a due card to end.
        _ = try await store.createItem(
            Item(
                itemTypeID: BuiltInItemTypes.basicID,
                fields: [
                    FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Due card")),
                    FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Due answer")),
                ]
            )
        )
    }

    private static func seedImageMissingDescription(store: ItemStore) async throws {
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
        guard let mediaStore = await store.media,
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

    private static func seedDeckWithDueItems(store: ItemStore) async throws {
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

    private static func seedPortableExportSource(store: ItemStore) async throws {
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

    private static func seedTypeConflictLocal(store: ItemStore) async throws {
        guard let fixtureDirectory = ProcessInfo.processInfo.environment["NEOANKI_TEST_FIXTURE_DIR"],
              !fixtureDirectory.isEmpty
        else {
            return
        }
        let firstURL = URL(fileURLWithPath: fixtureDirectory, isDirectory: true)
            .appendingPathComponent("conflict-first.neodeck")
        guard FileManager.default.fileExists(atPath: firstURL.path) else { return }
        _ = try await PortableDeck.importDeck(from: firstURL, into: store)

        let loaded = try await store.loadItemTypes()
        if let customType = loaded.itemTypes.first(where: { $0.name == "Portable Custom" }) {
            var revised = customType
            revised.name = "Portable Custom Revised"
            _ = try await store.updateItemType(revised)
        }
    }

    private static func seedCorruptedItemType(store: ItemStore) async throws {
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
        try await store.testingCorruptItemTypeDefinition(id: damaged.id)
        _ = try await store.loadItemTypes()
    }

    private static func seedImportWithMedia(store: ItemStore) async throws {
        guard let fixtureDirectory = ProcessInfo.processInfo.environment["NEOANKI_TEST_FIXTURE_DIR"],
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

    private static func seedAlternateImportType(store: ItemStore) async throws {
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
}
