#if os(iOS)
import Foundation
import NeoAnkiApplication
import NeoAnkiCore

/// Deterministic repository fixtures for isolated iOS UI journeys. The reset
/// launch argument is required so normal app launches can never seed content.
enum MobileItemTypeStudioUITestSeeder {
    private static let scenario = "item-type-studio"
    static let legacyItemTypeID = UUID(
        uuidString: "B3000001-0000-4000-8000-000000000001"
    )!
    static let legacyCardSetupID = UUID(
        uuidString: "B3000001-0010-4000-8000-000000000001"
    )!
    static let legacyAdditionalComponentID = UUID(
        uuidString: "B3000001-0022-4000-8000-000000000001"
    )!

    static func seedIfRequested(library: any LibraryRepository) async throws {
        let process = ProcessInfo.processInfo
        guard process.arguments.contains("-NeoAnkiUITestingReset"),
              process.environment["NEOANKI_TEST_SCENARIO"] == scenario
        else {
            return
        }

        let catalog = try await library.loadItemTypeCatalog()
        if catalog.allItemTypes.contains(where: { $0.id == legacyItemTypeID }) == false {
            try await seedLegacyEditableItemType(library: library)
        }
        if catalog.includedWithDecks.contains(where: { $0.deckPath == "Studio Fixtures" }) == false {
            try await importReadOnlyItemType(library: library)
        }
    }

    private static func seedLegacyEditableItemType(
        library: any LibraryRepository
    ) async throws {
        let front = FieldDef(
            id: UUID(uuidString: "B3000001-0001-4000-8000-000000000001")!,
            name: "Front",
            type: .text,
            isRequired: true
        )
        let back = FieldDef(
            id: UUID(uuidString: "B3000001-0002-4000-8000-000000000001")!,
            name: "Back",
            type: .text,
            isRequired: true
        )
        let cloze = FieldDef(
            id: UUID(uuidString: "B3000001-0003-4000-8000-000000000001")!,
            name: "Cloze Text",
            type: .cloze,
            isRequired: false
        )
        let notes = FieldDef(
            id: UUID(uuidString: "B3000001-0004-4000-8000-000000000001")!,
            name: "Legacy Notes",
            type: .text
        )
        let legacy = Template(
            id: legacyCardSetupID,
            name: "Legacy Additional",
            layout: .focus,
            components: [
                TemplateComponent(
                    id: UUID(uuidString: "B3000001-0020-4000-8000-000000000001")!,
                    region: .primary,
                    purpose: .question,
                    source: .field(front.id)
                ),
                TemplateComponent(
                    id: UUID(uuidString: "B3000001-0021-4000-8000-000000000001")!,
                    region: .secondary,
                    purpose: .expectedAnswer,
                    source: .field(back.id),
                    presentation: Presentation(reveal: .hiddenUntilAnswer)
                ),
                // Purpose/region is intentionally noncanonical. The Studio must
                // surface it under Additional content without normalizing it.
                TemplateComponent(
                    id: legacyAdditionalComponentID,
                    region: .secondary,
                    purpose: .supporting,
                    source: .field(notes.id)
                ),
            ],
            interaction: .reveal,
            skill: Skill(input: .text, output: .text, operation: .recall)
        )
        let clozeSetup = Template(
            id: UUID(uuidString: "B3000001-0011-4000-8000-000000000001")!,
            name: "Cloze Fixture",
            prompt: Side(slots: [
                Slot(
                    source: .field(cloze.id),
                    presentation: Presentation(reveal: .hiddenUntilAnswer)
                ),
            ]),
            answer: Side(slots: [Slot(source: .field(cloze.id))]),
            interaction: .cloze,
            skill: Skill(input: .text, output: .freeResponse, operation: .recall)
        )
        let itemType = ItemType(
            id: legacyItemTypeID,
            name: "Studio Legacy Fixture",
            fields: [front, back, cloze, notes],
            templates: [legacy, clozeSetup]
        )
        _ = try await library.createItemType(itemType)
        _ = try await library.createItem(
            Item(
                itemTypeID: itemType.id,
                fields: [
                    FieldValue(fieldID: front.id, value: .text("Question")),
                    FieldValue(fieldID: back.id, value: .text("Answer")),
                    FieldValue(fieldID: cloze.id, value: .empty),
                    FieldValue(fieldID: notes.id, value: .text("Preserve me")),
                ]
            ),
            asOf: Date(timeIntervalSince1970: 1_725_000_000)
        )
    }

    private static func importReadOnlyItemType(
        library: any LibraryRepository
    ) async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoanki-ios-studio-\(UUID().uuidString)", isDirectory: true)
        let bundle = workspace.appendingPathComponent("Fixture.neoanki", isDirectory: true)
        let items = bundle.appendingPathComponent("items", isDirectory: true)
        try FileManager.default.createDirectory(at: items, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let records = [
            #"{"kind":"neoanki","version":3,"root":"root","parts":["items/items.jsonl"]}"#,
            #"{"kind":"type","id":"included","name":"Read-only Fixture","fields":[{"id":"prompt","name":"Prompt","type":"text","required":true},{"id":"answer","name":"Answer","type":"text","required":true}],"templates":[{"name":"Recall","prompt":[{"field":"prompt"}],"answer":[{"field":"answer"}],"interaction":"reveal","skill":{"input":"text","output":"text","operation":"recall"}}]}"#,
            #"{"kind":"deck","id":"root","name":"Studio Fixtures","itemTypes":["included"],"defaultType":"included"}"#,
        ]
        try (records.joined(separator: "\n") + "\n").write(
            to: bundle.appendingPathComponent(AuthoredDeck.manifestName),
            atomically: true,
            encoding: .utf8
        )
        try Data().write(to: items.appendingPathComponent("items.jsonl"))
        _ = try await library.importAuthoredDeck(from: bundle)
    }
}
#endif

#if os(iOS)
/// Real repository content for visual acceptance; gated by reset + scenario.
enum MobileRedesignUITestSeeder {
    static func seedIfRequested(library: any LibraryRepository) async throws {
        let process = ProcessInfo.processInfo
        guard process.arguments.contains("-NeoAnkiUITestingReset"),
              process.environment["NEOANKI_TEST_SCENARIO"] == "mobile-redesign" else { return }
        guard try await library.items(scope: .allDecks, sort: .createdAscending, search: "").isEmpty else { return }
        let root = try await library.createDeck(Deck(name: "Study Fixtures"))
        let media = await library.mediaStore()
        let imageData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aE1sAAAAASUVORK5CYII=")!
        for (index, interaction) in Interaction.allCases.enumerated() {
            let deck = try await library.createDeck(Deck(name: interaction.rawValue, parentID: root.id))
            let front = FieldDef(name: "Question", type: interaction == .cloze ? .cloze : .text, isRequired: true)
            let back = FieldDef(name: "Answer", type: .text, isRequired: false)
            let visual = FieldDef(name: "Image", type: .image)
            let layout = CardLayoutID.allCases[index % CardLayoutID.allCases.count]
            var components = [TemplateComponent(region: .primary, purpose: .question, source: .field(front.id))]
            if interaction != .audioSubmission {
                components.append(TemplateComponent(region: .secondary, purpose: .expectedAnswer,
                    source: .field(back.id), presentation: Presentation(reveal: .hiddenUntilAnswer)))
            }
            if layout == .mediaAside || layout == .mediaHero {
                components.append(TemplateComponent(region: .media, purpose: .supporting, source: .field(visual.id)))
            }
            let type = ItemType(name: "Fixture \(interaction.rawValue)", fields: [front, back, visual], templates: [
                Template(name: interaction.rawValue, layout: layout, components: components, interaction: interaction,
                    skill: Skill(input: .text, output: interaction == .audioSubmission || interaction == .record ? .audio : .text, operation: interaction == .audioSubmission ? .explain : .recall))
            ])
            _ = try await library.createItemType(type)
            var fields = [FieldValue(fieldID: front.id, value: interaction == .cloze
                ? .cloze("The answer is Paris.", blanks: [ClozeSpan(group: 1, start: 14, length: 5)])
                : .text("Practice \(interaction.rawValue): what do you remember?"))]
            fields.append(FieldValue(fieldID: back.id, value: interaction == .audioSubmission ? .empty : .text(interaction == .arrange ? "one two three" : "Paris")))
            if layout == .mediaAside || layout == .mediaHero,
               let image = try await media?.ingest(data: imageData, kind: .image, fileExtension: "png", altText: "A small white sample image") {
                fields.append(FieldValue(fieldID: visual.id, value: .media(image)))
            }
            _ = try await library.createItem(Item(itemTypeID: type.id, fields: fields, deckID: deck.id))
        }
        let attentionDeck = try await library.createDeck(Deck(name: "Needs Attention", parentID: root.id))
        if let basic = try await library.loadItemTypes().itemTypes.first(where: { $0.name == "Basic" }) {
            let item = Item(itemTypeID: basic.id, fields: basic.fields.map {
                FieldValue(fieldID: $0.id, value: .text($0.name == "Front" ? "Repeatedly forgotten prompt" : "Private answer"))
            }, deckID: attentionDeck.id)
            _ = try await library.createItem(item)
            if let due = try await library.dueCards(scope: .deck(attentionDeck.id), asOf: .now).first {
                // Exercise the public grading capability to produce eight lapses.
                let start = Date.now.addingTimeInterval(-17 * 86_400)
                for day in 0..<8 {
                    let instant = start.addingTimeInterval(Double(day) * 86_400)
                    _ = try await library.submitReview(cardID: due.id, rating: .easy, asOf: instant, durationMilliseconds: 1000)
                    _ = try await library.submitReview(cardID: due.id, rating: .again, asOf: instant.addingTimeInterval(1), durationMilliseconds: 1000)
                }
            }
        }
        let savedDeck = try await library.createDeck(Deck(name: "Saved Recording", parentID: root.id))
        let prompt = FieldDef(name: "Prompt", type: .text, isRequired: true)
        let spoken = ItemType(name: "Saved Recording", fields: [prompt], templates: [Template(
            name: "Spoken", prompt: Side(slots: [Slot(source: .field(prompt.id))]), answer: Side(slots: []),
            interaction: .audioSubmission, skill: Skill(input: .text, output: .audio, operation: .explain))])
        _ = try await library.createItemType(spoken)
        _ = try await library.createItem(Item(itemTypeID: spoken.id, fields: [FieldValue(fieldID: prompt.id, value: .text("Explain your favorite book"))], deckID: savedDeck.id))
        if let due = try await library.dueCards(scope: .deck(savedDeck.id), asOf: .now).first {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: file) }
            // Valid silent AAC permits persistence/playback without host capture.
            let audio = Data(base64Encoded: "AAAAHGZ0eXBNNEEgAAACAE00QSBpc29taXNvMgAAAAhmcmVlAAAAXW1kYXTeAgBMYXZjNjIuMjguMTAxAAIwQA4BGCAHARggBwEYIAcBGCAHARggBwEYIAcBGCAHARggBwEYIAcBGCAHARggBwEYIAcBGCAHARggBwEYIAcBGCAHAAADP21vb3YAAABsbXZoZAAAAAAAAAAAAAAAAAAAA+gAAAfQAAEAAAEAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAAAJpdHJhawAAAFx0a2hkAAAAAwAAAAAAAAAAAAAAAQAAAAAAAAfQAAAAAAAAAAAAAAABAQAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAJGVkdHMAAAAcZWxzdAAAAAAAAAABAAAH0AAABAAAAQAAAAAB4W1kaWEAAAAgbWRoZAAAAAAAAAAAAAAAAAAAH0AAAEKAVcQAAAAAAC1oZGxyAAAAAAAAAABzb3VuAAAAAAAAAAAAAAAAU291bmRIYW5kbGVyAAAAAYxtaW5mAAAAEHNtaGQAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAVBzdGJsAAAAanN0c2QAAAAAAAAAAQAAAFptcDRhAAAAAAAAAAEAAAAAAAAAAAABABAAAAAAH0AAAAAAADZlc2RzAAAAAAOAgIAlAAEABICAgBdAFQAAAAAAfQAAAAE/BYCAgAUViFblAAaAgIABAgAAACBzdHRzAAAAAAAAAAIAAAAQAAAEAAAAAAEAAAKAAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAARAAAAAQAAAFhzdHN6AAAAAAAAAAAAAAARAAAAFQAAAAQAAAAEAAAABAAAAAQAAAAEAAAABAAAAAQAAAAEAAAABAAAAAQAAAAEAAAABAAAAAQAAAAEAAAABAAAAAQAAAAUc3RjbwAAAAAAAAABAAAALAAAABpzZ3BkAQAAAHJvbGwAAAACAAAAAf//AAAAHHNiZ3AAAAAAcm9sbAAAAAEAAAARAAAAAQAAAGJ1ZHRhAAAAWm1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAALWlsc3QAAAAlqXRvbwAAAB1kYXRhAAAAAQAAAABMYXZmNjIuMTIuMTAx")!
            try audio.write(to: file)
            _ = try await library.completeAudioSubmission(StudyResponseDraft(cardID: due.id, fileURL: file, durationMilliseconds: 2000, capturedAt: .now))
        }
        let authoringFields = [
            FieldDef(name: "Prompt", type: .text, isRequired: true),
            FieldDef(name: "Answer", type: .text, isRequired: true),
            FieldDef(name: "Number", type: .number),
            FieldDef(name: "Rich Text", type: .richText),
            FieldDef(name: "Cloze", type: .cloze),
            FieldDef(name: "Image", type: .image),
            FieldDef(name: "GIF", type: .gif),
            FieldDef(name: "Audio", type: .audio),
            FieldDef(name: "Video", type: .video),
        ]
        let authoringType = ItemType(name: "All Field Types", fields: authoringFields, templates: [Template(
            name: "Recall", prompt: Side(slots: [Slot(source: .field(authoringFields[0].id))]),
            answer: Side(slots: [Slot(source: .field(authoringFields[1].id))]), interaction: .reveal,
            skill: Skill(input: .text, output: .text, operation: .recall))])
        _ = try await library.createItemType(authoringType)
        let authoringImage = try await library.reserveMedia(data: imageData, kind: .image, altText: "Authoring image", asOf: .now).reference
        let authoringValues: [ContentValue] = [.text("Authoring media fixture"), .text("An answer"), .number(42.5),
            .rich([Span("Formatted text", styles: [.bold])]), .cloze("A blank to edit", blanks: [ClozeSpan(group: 1, start: 2, length: 5)]),
            .media(authoringImage), .empty, .empty, .empty]
        _ = try await library.createItem(Item(itemTypeID: authoringType.id,
            fields: zip(authoringFields, authoringValues).map { FieldValue(fieldID: $0.id, value: $1) }))
        let longDeck = try await library.createDeck(Deck(name: "Long Content", parentID: root.id))
        let basic = try await library.loadItemTypes().itemTypes.first { $0.name == "Basic" }
        if let basic {
            _ = try await library.createItem(Item(itemTypeID: basic.id, fields: basic.fields.map {
                FieldValue(fieldID: $0.id, value: .text(String(repeating: $0.name == "Front" ? "A long question invites careful reading. " : "CONCEALED ANSWER with a detailed explanation. ", count: 60)))
            }, deckID: longDeck.id))
        }
    }
}
#endif
