import Foundation
import NeoAnkiCore
import Testing

@testable import NeoAnki2

@MainActor
private func makeModel() async throws -> (ItemsModel, ItemStore) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-app-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let databaseURL = url.appendingPathComponent("test.sqlite")
    let store = try ItemStore(databaseURL: databaseURL)
    try await store.bootstrap()
    let mediaStore = await store.media
    return (ItemsModel(store: store, mediaStore: mediaStore), store)
}

func importContextualDeck(
    into store: ItemStore,
    typeIDs: [String] = ["Special"],
    defaultType: String? = "Special"
) async throws -> UUID {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-contextual-model-\(UUID().uuidString)", isDirectory: true)
    let bundle = root.appendingPathComponent("Context.neoanki", isDirectory: true)
    let items = bundle.appendingPathComponent("items", isDirectory: true)
    try FileManager.default.createDirectory(at: items, withIntermediateDirectories: true)
    let types = typeIDs.map { id in
        #"{"kind":"type","id":"\#(id)","name":"\#(id) Type","fields":[{"id":"prompt","name":"Prompt","type":"text","required":true},{"id":"answer","name":"Answer","type":"text","required":true}],"templates":[{"name":"Card","prompt":[{"field":"prompt"}],"answer":[{"field":"answer"}],"interaction":"reveal","skill":{"input":"text","output":"text","operation":"recall"}}]}"#
    }
    var deckObject: [String: Any] = [
        "kind": "deck",
        "id": "root",
        "name": "Context Deck",
        "itemTypes": typeIDs,
    ]
    if let defaultType {
        deckObject["defaultType"] = defaultType
    }
    let deck = try String(
        data: JSONSerialization.data(withJSONObject: deckObject, options: [.sortedKeys]),
        encoding: .utf8
    )!
    let records = [
        #"{"kind":"neoanki","version":3,"root":"root","parts":["items/items.jsonl"]}"#,
    ] + types + [deck]
    try (records.joined(separator: "\n") + "\n").write(
        to: bundle.appendingPathComponent("deck.jsonl"),
        atomically: true,
        encoding: .utf8
    )
    try Data().write(to: items.appendingPathComponent("items.jsonl"))
    let result = try await AuthoredDeck.importDeck(from: bundle, into: store)
    return try #require(result.deckIDs.first)
}

@Test @MainActor func itemsModelLoadsEmptyLibrary() async throws {
    let (model, _) = try await makeModel()

    await model.load()

    #expect(model.isLoading == false)
    #expect(model.items.isEmpty)
    #expect(model.itemType?.name == "Basic")
    #expect(model.errorMessage == nil)
}

@Test @MainActor func itemsModelResolvesRecommendedDeckTypeAndKeepsNormalEscapeHatch() async throws {
    let (model, store) = try await makeModel()
    let deckID = try await importContextualDeck(into: store)
    await model.load()

    await model.configureAddItem(for: deckID)

    #expect(model.itemType?.name == "Special Type")
    #expect(model.policyItemTypes.map(\.name) == ["Special Type"])
    #expect(model.normalItemTypes.contains { $0.name == "Basic" })
    #expect(!model.normalItemTypes.contains { $0.name == "Special Type" })
    #expect(model.isRecommendedItemType(try #require(model.itemType?.id)))
}

@Test @MainActor func itemsModelLeavesAmbiguousDeckPolicyUnselected() async throws {
    let (model, store) = try await makeModel()
    let deckID = try await importContextualDeck(
        into: store,
        typeIDs: ["Term", "Example"],
        defaultType: nil
    )
    await model.load()

    await model.configureAddItem(for: deckID)

    #expect(model.policyItemTypes.map(\.name) == ["Term Type", "Example Type"])
    #expect(model.addItemTypeID == nil)
    #expect(model.itemType == nil)
}

@Test @MainActor func itemsModelCanRetainSelectionWhenDeckChangesWithContent() async throws {
    let (model, store) = try await makeModel()
    let deckID = try await importContextualDeck(into: store)
    await model.load()
    let basicID = try #require(model.normalItemTypes.first { $0.name == "Basic" }?.id)
    model.addItemTypeID = basicID

    await model.configureAddItem(for: deckID, resolveSelection: false)

    #expect(model.addItemTypeID == basicID)
    #expect(model.itemType?.name == "Basic")
    #expect(model.policyItemTypes.map(\.name) == ["Special Type"])
}

@Test @MainActor func itemsModelAddsItemToList() async throws {
    let (model, store) = try await makeModel()
    await model.load()

    let frontID = BuiltInItemTypes.frontFieldID
    let backID = BuiltInItemTypes.backFieldID

    let saved = await model.addItem(fieldSpans: [
        frontID: [Span("France")],
        backID: [Span("Paris")],
    ])

    #expect(saved == true)
    #expect(model.items.count == 1)
    #expect(model.items.first?.title == "France")
    #expect(model.items.first?.subtitle == "Paris")
    _ = store
}

@Test @MainActor func itemsModelSurfacesValidationErrors() async throws {
    let (model, _) = try await makeModel()
    await model.load()

    let saved = await model.addItem(fieldSpans: [
        BuiltInItemTypes.frontFieldID: [Span("Only front")],
    ])

    #expect(saved == false)
    #expect(model.errorMessage == "Back is required.")
    #expect(model.items.isEmpty)
}

@Test @MainActor func itemsModelPersistsRichTextFields() async throws {
    let (model, store) = try await makeModel()
    await model.load()

    let frontID = BuiltInItemTypes.frontFieldID
    let backID = BuiltInItemTypes.backFieldID
    let richFront = [Span("Q", styles: [.bold]), Span("uestion", styles: [])]

    let saved = await model.addItem(fieldSpans: [
        frontID: richFront,
        backID: [Span("Answer", styles: [.italic])],
    ])

    #expect(saved == true)

    let itemID = try #require(model.items.first?.id)
    let fetched = try await store.fetchItem(id: itemID)
    let item = try #require(fetched?.item)

    #expect(item.value(for: frontID) == .rich(richFront))
    #expect(item.value(for: backID) == .rich([Span("Answer", styles: [.italic])]))
    #expect(model.items.first?.title == "Question")
    #expect(model.items.first?.subtitle == "Answer")
}

@Test @MainActor func itemsModelUpdatesExistingItemContent() async throws {
    let (model, store) = try await makeModel()
    await model.load()

    let frontID = BuiltInItemTypes.frontFieldID
    let backID = BuiltInItemTypes.backFieldID
    #expect(await model.addItem(fieldSpans: [
        frontID: [Span("France")],
        backID: [Span("Paris")],
    ]))
    let itemID = try #require(model.items.first?.id)

    let updated = await model.updateItem(
        id: itemID,
        fieldSpans: [
            frontID: [Span("Japan")],
            backID: [Span("Tokyo", styles: [.bold])],
        ]
    )

    #expect(updated)
    #expect(model.items.first?.title == "Japan")
    #expect(model.items.first?.subtitle == "Tokyo")
    #expect(model.dueCount == 1)
    let stored = try #require(try await store.fetchItem(id: itemID)?.item)
    #expect(stored.value(for: frontID) == .text("Japan"))
    #expect(stored.value(for: backID) == .rich([Span("Tokyo", styles: [.bold])]))
}

@Test @MainActor func itemsModelRejectsInvalidUpdateWithoutChangingStoredItem() async throws {
    let (model, store) = try await makeModel()
    await model.load()

    let frontID = BuiltInItemTypes.frontFieldID
    let backID = BuiltInItemTypes.backFieldID
    #expect(await model.addItem(fieldSpans: [
        frontID: [Span("France")],
        backID: [Span("Paris")],
    ]))
    let itemID = try #require(model.items.first?.id)

    let updated = await model.updateItem(
        id: itemID,
        fieldSpans: [frontID: [Span("Japan")]]
    )

    #expect(updated == false)
    #expect(model.errorMessage == "Back is required.")
    let stored = try #require(try await store.fetchItem(id: itemID)?.item)
    #expect(stored.value(for: frontID) == .text("France"))
    #expect(stored.value(for: backID) == .text("Paris"))
}

@Test @MainActor func itemsModelUpdatesAgainstTheLatestStoredSchema() async throws {
    let (model, store) = try await makeModel()
    await model.load()

    let frontID = BuiltInItemTypes.frontFieldID
    let backID = BuiltInItemTypes.backFieldID
    #expect(await model.addItem(fieldSpans: [
        frontID: [Span("France")],
        backID: [Span("Paris")],
    ]))
    let itemID = try #require(model.items.first?.id)

    var latestType = try await store.itemType(id: BuiltInItemTypes.basicID)
    let note = FieldDef(name: "Note", type: .text, isRequired: false)
    latestType.fields.append(note)
    _ = try await store.updateItemType(latestType)

    let updated = await model.updateItem(
        id: itemID,
        fieldSpans: [
            frontID: [Span("France")],
            backID: [Span("Paris")],
            note.id: [Span("Capital city")],
        ]
    )

    #expect(updated)
    let stored = try #require(try await store.fetchItem(id: itemID)?.item)
    #expect(stored.value(for: note.id) == .text("Capital city"))
}

@Test @MainActor func itemsModelUpdateReportsMissingItem() async throws {
    let (model, _) = try await makeModel()
    await model.load()

    let updated = await model.updateItem(
        id: UUID(),
        fieldSpans: [
            BuiltInItemTypes.frontFieldID: [Span("Question")],
            BuiltInItemTypes.backFieldID: [Span("Answer")],
        ]
    )

    #expect(updated == false)
    #expect(model.errorMessage == "This item no longer exists.")
}

@Test @MainActor func itemsModelUpdatePreservesLanguageMetadataAndTags() async throws {
    let (model, store) = try await makeModel()
    let item = Item(
        itemTypeID: BuiltInItemTypes.basicID,
        fields: [
            FieldValue(
                fieldID: BuiltInItemTypes.frontFieldID,
                value: .text("Hola", lang: "es")
            ),
            FieldValue(
                fieldID: BuiltInItemTypes.backFieldID,
                value: .text("Hello", lang: "en")
            ),
        ],
        tags: ["language", "spanish"]
    )
    _ = try await store.createItem(item)
    await model.load()

    #expect(await model.updateItem(
        id: item.id,
        fieldSpans: [
            BuiltInItemTypes.frontFieldID: [Span("Adiós")],
            BuiltInItemTypes.backFieldID: [Span("Goodbye")],
        ]
    ))

    let stored = try #require(try await store.fetchItem(id: item.id)?.item)
    #expect(stored.value(for: BuiltInItemTypes.frontFieldID) == .text("Adiós", lang: "es"))
    #expect(stored.value(for: BuiltInItemTypes.backFieldID) == .text("Goodbye", lang: "en"))
    #expect(stored.tags == ["language", "spanish"])
}

@Test @MainActor func itemsModelRequiresDescriptionsForImageContent() async throws {
    let (model, store) = try await makeModel()
    let imageField = FieldDef(name: "Image", type: .image, isRequired: true)
    let captionField = FieldDef(name: "Caption", type: .text, isRequired: true)
    let itemType = ItemType(
        name: "Image Notes",
        fields: [imageField, captionField],
        templates: [
            Template(
                name: "Recognize",
                prompt: Side(slots: [Slot(source: .field(imageField.id))]),
                answer: Side(slots: [Slot(source: .field(captionField.id))]),
                interaction: .reveal,
                skill: Skill(input: .image, output: .text, operation: .recognize)
            ),
        ]
    )
    _ = try await store.createItemType(itemType)
    await model.load()
    model.addItemTypeID = itemType.id

    let saved = await model.addItem(
        fieldSpans: [captionField.id: [Span("A mountain lake")]],
        fieldMedia: [
            imageField.id: MediaRef(
                kind: .image,
                assetHash: String(repeating: "0", count: 64),
                fileExtension: "png"
            ),
        ]
    )

    #expect(saved == false)
    #expect(model.errorMessage == "Add a description for Image so it works with VoiceOver.")
    #expect(model.items.isEmpty)
}

@Test @MainActor func itemsModelRequiresDescriptionsForGIFContent() async throws {
    let (model, store) = try await makeModel()
    let gifField = FieldDef(name: "Animation", type: .gif, isRequired: true)
    let captionField = FieldDef(name: "Caption", type: .text, isRequired: true)
    let itemType = ItemType(
        name: "Animated Notes",
        fields: [gifField, captionField],
        templates: [
            Template(
                name: "Recognize",
                prompt: Side(slots: [Slot(source: .field(gifField.id))]),
                answer: Side(slots: [Slot(source: .field(captionField.id))]),
                interaction: .reveal,
                skill: Skill(input: .image, output: .text, operation: .recognize)
            ),
        ]
    )
    _ = try await store.createItemType(itemType)
    await model.load()
    model.addItemTypeID = itemType.id

    let saved = await model.addItem(
        fieldSpans: [captionField.id: [Span("An animation")]],
        fieldMedia: [
            gifField.id: MediaRef(
                kind: .gif,
                assetHash: String(repeating: "0", count: 64),
                fileExtension: "gif"
            ),
        ]
    )

    #expect(saved == false)
    #expect(model.errorMessage == "Add a description for Animation so it works with VoiceOver.")
}

@Test @MainActor func itemsModelDeletesItemFromList() async throws {
    let (model, _) = try await makeModel()
    await model.load()

    let saved = await model.addItem(fieldSpans: [
        BuiltInItemTypes.frontFieldID: [Span("France")],
        BuiltInItemTypes.backFieldID: [Span("Paris")],
    ])
    #expect(saved == true)
    #expect(model.items.count == 1)
    #expect(model.dueCount == 1)

    let itemID = try #require(model.items.first?.id)
    let deleted = await model.deleteItem(id: itemID)

    #expect(deleted == true)
    #expect(model.items.isEmpty)
    #expect(model.dueCount == 0)
    #expect(model.errorMessage == nil)
}
