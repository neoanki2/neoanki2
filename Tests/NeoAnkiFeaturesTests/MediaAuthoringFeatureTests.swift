import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import Testing

@Test @MainActor func photoCanBeAttachedBeforeNamingAndRequiresLatestDescriptionAtSave() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("photo-authoring-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
    let model = LibraryFeatureModel(library: repository)
    await model.bootstrap()
    let photo = FieldDef(name: "Photo", type: .image, isRequired: false)
    let name = FieldDef(name: "Name", type: .text, isRequired: true)
    let type = ItemType(name: "My photo cards", fields: [photo, name], templates: [
        Template(name: "Name it", prompt: Side(slots: [Slot(source: .field(photo.id))]),
                 answer: Side(slots: [Slot(source: .field(name.id))]), interaction: .reveal,
                 skill: Skill(input: .image, output: .text, operation: .recognize))
    ])
    _ = try await repository.createItemType(type)
    let deck = try await repository.createDeck(Deck(name: "Nature"))
    let data = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
    var media = try await model.reserveMedia(data: data, kind: .image, altText: "")
    await #expect(throws: ItemDraftError.missingMediaDescription("Photo")) {
        try await model.createItem(itemType: type, deckID: deck.id, values: [photo.id: .media(media), name.id: .text("Oak")])
    }
    #expect(!ItemDraftValidation.canSave(.init(text: [name.id: "Oak"], media: [photo.id: media]), itemType: type))
    media.altText = "A tree with lobed leaves"
    try await model.createItem(itemType: type, deckID: deck.id, values: [photo.id: .media(media), name.id: .text("Oak")])
    let summary = try #require(model.items.first)
    var item = try #require(try await model.item(id: summary.id)?.item)
    #expect(item.deckID == deck.id)
    #expect(item.value(for: photo.id) == .media(media))
    media.altText = "Updated visual description"
    item.fields = [FieldValue(fieldID: photo.id, value: .media(media)), FieldValue(fieldID: name.id, value: .text("Oak"))]
    try await model.updateItem(item)
    #expect(try await model.item(id: item.id)?.item.value(for: photo.id) == .media(media))
    let cards = try await repository.dueCards(scope: .deck(deck.id), asOf: .now)
    #expect(cards.count == 1)
    #expect(model.decks.count == 1)
}
