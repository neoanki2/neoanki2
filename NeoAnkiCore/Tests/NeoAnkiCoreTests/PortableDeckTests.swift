import Foundation
import SQLite3
import Testing
@testable import NeoAnkiCore

private func portableTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("portable-deck-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func portableStore(in directory: URL, name: String) async throws -> ItemStore {
    let root = directory.appendingPathComponent(name, isDirectory: true)
    let media = try MediaStore(rootDirectory: root)
    let store = try ItemStore(
        databaseURL: root.appendingPathComponent("library.sqlite"),
        mediaStore: media
    )
    try await store.bootstrap()
    return store
}

@Test func portableDeckRoundTripImportsContentAndFreshCards() async throws {
    let directory = try portableTestDirectory()
    let source = try await portableStore(in: directory, name: "source")
    let root = try await source.createDeck(Deck(name: "Languages"))
    let child = try await source.createDeck(Deck(name: "Spanish", parentID: root.id))
    let itemType = try await source.defaultItemType()
    let sourceItem = Item(
        itemTypeID: itemType.id,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("hola")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("hello")),
        ],
        tags: ["greeting"],
        deckID: child.id
    )
    _ = try await source.createItem(sourceItem)

    let packageURL = directory.appendingPathComponent("languages.neodeck")
    try await PortableDeck.export(deckID: root.id, from: source, to: packageURL)

    let destination = try await portableStore(in: directory, name: "destination")
    let result = try await PortableDeck.importDeck(from: packageURL, into: destination)

    #expect(result.itemCount == 1)
    #expect(result.createdItemTypeCount == 0)
    #expect(result.reusedItemTypeCount == 1)
    #expect(result.deckIDs.count == 1)
    let decks = try await destination.listDecks()
    #expect(decks.count == 2)
    let items = try await destination.listItems()
    #expect(items.count == 1)
    #expect(items[0].id != sourceItem.id)
    #expect(items[0].title == "hola")
    #expect(items[0].cardCount == 1)
    #expect(try await destination.dueCount() == 1)
}

@Test func portableDeckRejectsWrongApplicationIdentifier() async throws {
    let directory = try portableTestDirectory()
    let source = try await portableStore(in: directory, name: "source")
    let deck = try await source.createDeck(Deck(name: "Deck"))
    let packageURL = directory.appendingPathComponent("deck.neodeck")
    try await PortableDeck.export(deckID: deck.id, from: source, to: packageURL)

    var handle: OpaquePointer?
    #expect(sqlite3_open(packageURL.path, &handle) == SQLITE_OK)
    defer { sqlite3_close(handle) }
    #expect(sqlite3_exec(handle, "PRAGMA application_id = 0;", nil, nil, nil) == SQLITE_OK)

    let destination = try await portableStore(in: directory, name: "destination")
    await #expect(throws: PortableDeckError.self) {
        try await PortableDeck.importDeck(from: packageURL, into: destination)
    }
    #expect(try await destination.listDecks().isEmpty)
    #expect(try await destination.listItems().isEmpty)
}

@Test func portableDeckRejectsSameOriginWithDifferentSchema() async throws {
    let directory = try portableTestDirectory()
    let source = try await portableStore(in: directory, name: "source")
    let deck = try await source.createDeck(Deck(name: "Deck"))
    let type = try ItemTypeBuilder.makeItemType(
        name: "Custom",
        fields: [
            FieldDef(name: "Prompt", type: .text, isRequired: true),
            FieldDef(name: "Answer", type: .text, isRequired: true),
        ]
    )
    _ = try await source.createItemType(type)
    _ = try await source.createItem(Item(
        itemTypeID: type.id,
        fields: type.fields.map { FieldValue(fieldID: $0.id, value: .text($0.name)) },
        deckID: deck.id
    ))
    let first = directory.appendingPathComponent("first.neodeck")
    try await PortableDeck.export(deckID: deck.id, from: source, to: first)

    let destination = try await portableStore(in: directory, name: "destination")
    _ = try await PortableDeck.importDeck(from: first, into: destination)

    var changed = type
    changed.name = "Custom changed"
    _ = try await source.updateItemType(changed)
    let second = directory.appendingPathComponent("second.neodeck")
    try await PortableDeck.export(deckID: deck.id, from: source, to: second)

    await #expect(throws: PortableDeckError.self) {
        try await PortableDeck.importDeck(from: second, into: destination)
    }
    #expect(try await destination.listItems().count == 1)

    let resolved = try await PortableDeck.importDeck(
        from: second,
        into: destination,
        conflictResolution: .importAsDistinctRevision
    )
    #expect(resolved.createdItemTypeCount == 1)
    #expect(try await destination.listItems().count == 2)
    #expect(try await destination.listDecks().count == 2)
}

@Test func portableDeckRejectsAStaleMappingAfterLocalTypeEdit() async throws {
    let directory = try portableTestDirectory()
    let source = try await portableStore(in: directory, name: "source")
    let deck = try await source.createDeck(Deck(name: "Deck"))
    let type = try ItemTypeBuilder.makeItemType(
        name: "Mapped",
        fields: [
            FieldDef(name: "Prompt", type: .text, isRequired: true),
            FieldDef(name: "Answer", type: .text, isRequired: true),
        ]
    )
    _ = try await source.createItemType(type)
    _ = try await source.createItem(Item(
        itemTypeID: type.id,
        fields: type.fields.map { FieldValue(fieldID: $0.id, value: .text($0.name)) },
        deckID: deck.id
    ))
    let packageURL = directory.appendingPathComponent("mapped.neodeck")
    try await PortableDeck.export(deckID: deck.id, from: source, to: packageURL)

    let destination = try await portableStore(in: directory, name: "destination")
    let first = try await PortableDeck.importDeck(from: packageURL, into: destination)
    #expect(first.createdItemTypeCount == 1)
    let importedItem = try #require((try await destination.listItems()).first)
    let importedRecord = try #require(await destination.fetchItem(id: importedItem.id))
    var editedType = importedRecord.itemType
    editedType.name = "Locally Edited"
    _ = try await destination.updateItemType(editedType)

    await #expect(throws: PortableDeckError.self) {
        try await PortableDeck.importDeck(from: packageURL, into: destination)
    }
    #expect(try await destination.listItems().count == 1)
    #expect(try await destination.listDecks().count == 1)
}

@Test func portableDeckUsesPortableOrdinalJSON() async throws {
    let directory = try portableTestDirectory()
    let source = try await portableStore(in: directory, name: "source")
    let deck = try await source.createDeck(Deck(name: "Deck"))
    let type = try await source.defaultItemType()
    _ = try await source.createItem(Item(
        itemTypeID: type.id,
        fields: [
            FieldValue(fieldID: type.fields[0].id, value: .text("front", lang: "en")),
            FieldValue(fieldID: type.fields[1].id, value: .text("back")),
        ],
        deckID: deck.id
    ))
    let packageURL = directory.appendingPathComponent("ordinal.neodeck")
    try await PortableDeck.export(deckID: deck.id, from: source, to: packageURL)

    var handle: OpaquePointer?
    #expect(sqlite3_open_v2(packageURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
    defer { sqlite3_close(handle) }
    var statement: OpaquePointer?
    #expect(sqlite3_prepare_v2(
        handle,
        "SELECT prompt_json, value_json FROM templates CROSS JOIN item_fields "
            + "WHERE templates.ordinal = 0 AND item_fields.field_ordinal = 0 LIMIT 1;",
        -1,
        &statement,
        nil
    ) == SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    #expect(sqlite3_step(statement) == SQLITE_ROW)
    let prompt = String(cString: sqlite3_column_text(statement, 0))
    let value = String(cString: sqlite3_column_text(statement, 1))
    #expect(prompt.contains(#""source":{"field":0}"#))
    #expect(value == #"{"lang":"en","text":"front","type":"text"}"#)
}

@Test func portableDeckRejectsAdditionalSchemaColumns() async throws {
    let directory = try portableTestDirectory()
    let source = try await portableStore(in: directory, name: "source")
    let deck = try await source.createDeck(Deck(name: "Deck"))
    let packageURL = directory.appendingPathComponent("extra-column.neodeck")
    try await PortableDeck.export(deckID: deck.id, from: source, to: packageURL)

    var handle: OpaquePointer?
    #expect(sqlite3_open(packageURL.path, &handle) == SQLITE_OK)
    #expect(sqlite3_exec(
        handle,
        "ALTER TABLE decks ADD COLUMN attacker_controlled TEXT;",
        nil,
        nil,
        nil
    ) == SQLITE_OK)
    sqlite3_close(handle)

    let destination = try await portableStore(in: directory, name: "destination")
    await #expect(throws: PortableDeckError.self) {
        try await PortableDeck.importDeck(from: packageURL, into: destination)
    }
    #expect(try await destination.listDecks().isEmpty)
}

@Test func portableDeckStreamsLargeMediaRoundTrip() async throws {
    let directory = try portableTestDirectory()
    let source = try await portableStore(in: directory, name: "source")
    let deck = try await source.createDeck(Deck(name: "Media"))
    let caption = FieldDef(name: "Caption", type: .text, isRequired: true)
    let image = FieldDef(name: "Image", type: .image, isRequired: true)
    let type = ItemType(
        name: "Image",
        fields: [caption, image],
        templates: [
            Template(
                name: "Image",
                prompt: Side(slots: [.init(source: .field(caption.id))]),
                answer: Side(slots: [.init(source: .field(image.id))]),
                interaction: .reveal,
                skill: Skill(input: .text, output: .image, operation: .recall)
            ),
        ]
    )
    _ = try await source.createItemType(type)
    var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    png.append(Data(repeating: 0x41, count: 2_000_000))
    let ref = try await source.media!.ingest(data: png, kind: .image, fileExtension: "png")
    _ = try await source.createItem(Item(
        itemTypeID: type.id,
        fields: [
            FieldValue(fieldID: caption.id, value: .text("large")),
            FieldValue(fieldID: image.id, value: .media(ref)),
        ],
        deckID: deck.id
    ))

    let packageURL = directory.appendingPathComponent("large.neodeck")
    try await PortableDeck.export(deckID: deck.id, from: source, to: packageURL)
    let destination = try await portableStore(in: directory, name: "destination")
    let result = try await PortableDeck.importDeck(from: packageURL, into: destination)
    #expect(result.itemCount == 1)
    let imported = try await destination.listItems()
    #expect(imported.count == 1)
    #expect(try await destination.mediaAsset(hash: ref.assetHash)?.byteSize == png.count)
}

@Test func portableDeckDatabaseFailureRollsBackDeckTypeItemsAndMedia() async throws {
    let directory = try portableTestDirectory()
    let source = try await portableStore(in: directory, name: "source")
    let deck = try await source.createDeck(Deck(name: "Atomic"))
    let caption = FieldDef(name: "Caption", type: .text, isRequired: true)
    let image = FieldDef(name: "Image", type: .image, isRequired: true)
    let type = ItemType(
        name: "Atomic Media",
        fields: [caption, image],
        templates: [
            Template(
                name: "Recall",
                prompt: Side(slots: [.init(source: .field(caption.id))]),
                answer: Side(slots: [.init(source: .field(image.id))]),
                interaction: .reveal,
                skill: Skill(input: .text, output: .image, operation: .recall)
            ),
        ]
    )
    _ = try await source.createItemType(type)
    let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x41])
    let ref = try await source.media!.ingest(data: bytes, kind: .image, fileExtension: "png")
    _ = try await source.createItem(Item(
        itemTypeID: type.id,
        fields: [
            FieldValue(fieldID: caption.id, value: .text("atomic")),
            FieldValue(fieldID: image.id, value: .media(ref)),
        ],
        deckID: deck.id
    ))
    let packageURL = directory.appendingPathComponent("atomic.neodeck")
    try await PortableDeck.export(deckID: deck.id, from: source, to: packageURL)

    let destination = try await portableStore(in: directory, name: "destination")
    let databaseURL = directory
        .appendingPathComponent("destination", isDirectory: true)
        .appendingPathComponent("library.sqlite")
    var handle: OpaquePointer?
    #expect(sqlite3_open(databaseURL.path, &handle) == SQLITE_OK)
    #expect(sqlite3_exec(
        handle,
        """
        CREATE TRIGGER fail_portable_item_insert
        BEFORE INSERT ON items
        BEGIN
            SELECT RAISE(ABORT, 'forced portable import failure');
        END;
        """,
        nil,
        nil,
        nil
    ) == SQLITE_OK)
    sqlite3_close(handle)

    await #expect(throws: Error.self) {
        try await PortableDeck.importDeck(from: packageURL, into: destination)
    }
    #expect(try await destination.listDecks().isEmpty)
    #expect(try await destination.listItems().isEmpty)
    #expect(try await destination.listItemTypes().allSatisfy { $0.name != type.name })
    #expect(try await destination.mediaAsset(hash: ref.assetHash) == nil)
}

@Test func portableDeckRoundTripsEveryNonMediaContentValue() async throws {
    let directory = try portableTestDirectory()
    let source = try await portableStore(in: directory, name: "source")
    let deck = try await source.createDeck(Deck(name: "Content"))
    let plain = FieldDef(name: "Plain", type: .text, isRequired: true)
    let rich = FieldDef(name: "Rich", type: .richText, isRequired: true)
    let number = FieldDef(name: "Number", type: .number, isRequired: true)
    let cloze = FieldDef(name: "Cloze", type: .cloze, isRequired: true)
    let type = ItemType(
        name: "Portable Content",
        fields: [plain, rich, number, cloze],
        templates: [
            Template(
                name: "Recall",
                prompt: Side(slots: [.init(source: .field(plain.id))]),
                answer: Side(slots: [.init(source: .field(rich.id))]),
                interaction: .reveal,
                skill: Skill(input: .text, output: .text, operation: .recall),
                generateWhen: .all([
                    .fieldNotEmpty(plain.id),
                    .any([.fieldNotEmpty(rich.id), .fieldEmpty(number.id)]),
                ])
            ),
        ]
    )
    _ = try await source.createItemType(type)
    let expected: [ContentValue] = [
        .text("café", lang: "fr"),
        .rich([
            Span("bold", styles: [.bold, .highlight]),
            Span(" code", styles: [.code]),
        ]),
        .number(42.5),
        .cloze("Paris", blanks: [.init(group: 1, start: 0, length: 5, hint: "city")]),
    ]
    _ = try await source.createItem(Item(
        itemTypeID: type.id,
        fields: zip(type.fields, expected).map {
            FieldValue(fieldID: $0.0.id, value: $0.1)
        },
        tags: ["unicode-✓", "repeated", "repeated"],
        deckID: deck.id
    ))

    let packageURL = directory.appendingPathComponent("content.neodeck")
    try await PortableDeck.export(deckID: deck.id, from: source, to: packageURL)
    let destination = try await portableStore(in: directory, name: "destination")
    _ = try await PortableDeck.importDeck(from: packageURL, into: destination)

    let summaries = try await destination.listItems()
    let summary = try #require(summaries.first)
    let imported = try #require(await destination.fetchItem(id: summary.id))
    #expect(imported.item.fields.map(\.value) == expected)
    #expect(imported.item.tags == ["unicode-✓", "repeated", "repeated"])
    #expect(imported.itemType.templates[0].generateWhen != nil)
}

@Test func portableDeckRepeatedImportReusesTypesWithoutOverwritingContent() async throws {
    let directory = try portableTestDirectory()
    let source = try await portableStore(in: directory, name: "source")
    let deck = try await source.createDeck(Deck(name: "Repeat"))
    let type = try await source.defaultItemType()
    _ = try await source.createItem(Item(
        itemTypeID: type.id,
        fields: [
            FieldValue(fieldID: type.fields[0].id, value: .text("front")),
            FieldValue(fieldID: type.fields[1].id, value: .text("back")),
        ],
        deckID: deck.id
    ))
    let packageURL = directory.appendingPathComponent("repeat.neodeck")
    try await PortableDeck.export(deckID: deck.id, from: source, to: packageURL)

    let destination = try await portableStore(in: directory, name: "destination")
    let initialTypeCount = try await destination.listItemTypes().count
    let first = try await PortableDeck.importDeck(from: packageURL, into: destination)
    let second = try await PortableDeck.importDeck(from: packageURL, into: destination)

    #expect(first.reusedItemTypeCount == 1)
    #expect(second.reusedItemTypeCount == 1)
    #expect(try await destination.listItemTypes().count == initialTypeCount)
    #expect(try await destination.listItems().count == 2)
    #expect(try await destination.listDecks().count == 2)
}

@Test func portableDeckSameNameDifferentSchemaCreatesDistinctType() async throws {
    let directory = try portableTestDirectory()
    let source = try await portableStore(in: directory, name: "source")
    let deck = try await source.createDeck(Deck(name: "Source"))
    let importedType = try ItemTypeBuilder.makeItemType(
        name: "Shared Name",
        fields: [
            FieldDef(name: "Question", type: .text, isRequired: true),
            FieldDef(name: "Answer", type: .text, isRequired: true),
        ]
    )
    _ = try await source.createItemType(importedType)
    _ = try await source.createItem(Item(
        itemTypeID: importedType.id,
        fields: importedType.fields.map { FieldValue(fieldID: $0.id, value: .text($0.name)) },
        deckID: deck.id
    ))
    let packageURL = directory.appendingPathComponent("same-name.neodeck")
    try await PortableDeck.export(deckID: deck.id, from: source, to: packageURL)

    let destination = try await portableStore(in: directory, name: "destination")
    let localType = try ItemTypeBuilder.makeItemType(
        name: "Shared Name",
        fields: [
            FieldDef(name: "Local Front", type: .text, isRequired: true),
            FieldDef(name: "Local Back", type: .text, isRequired: true),
        ]
    )
    _ = try await destination.createItemType(localType)
    let result = try await PortableDeck.importDeck(from: packageURL, into: destination)

    #expect(result.createdItemTypeCount == 1)
    #expect(try await destination.listItemTypes().filter { $0.name == "Shared Name" }.count == 2)
}
