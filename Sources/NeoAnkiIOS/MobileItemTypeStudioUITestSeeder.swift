#if os(iOS)
import Foundation
import NeoAnkiApplication
import NeoAnkiCore

/// Deterministic repository fixtures for isolated iOS UI journeys. The reset
/// launch argument is required so normal app launches can never seed content.
enum MobileItemTypeStudioUITestSeeder {
    private static let scenario = "item-type-studio"
    private static let legacyItemTypeID = UUID(
        uuidString: "B3000001-0000-4000-8000-000000000001"
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
            id: UUID(uuidString: "B3000001-0010-4000-8000-000000000001")!,
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
                    id: UUID(uuidString: "B3000001-0022-4000-8000-000000000001")!,
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
