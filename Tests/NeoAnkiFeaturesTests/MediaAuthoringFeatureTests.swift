import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import Testing

@Test(arguments: [false, true]) @MainActor func photoCanBeSavedWithoutDescriptionAndOptionalDescriptionCanBeUpdated(largePhoto: Bool) async throws {
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
    let small = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
    let data = largePhoto ? try oversizedAuthoringPhoto() : small
    if largePhoto { #expect(data.count > MediaValidation.maxBytes(for: .image)) }
    var media = try await model.reserveMedia(data: data, kind: .image, altText: "")
    #expect(media.fileExtension == (largePhoto ? "jpg" : "png"))
    let store = try #require(await repository.mediaStore())
    let storedURL = try await store.resolve(media)
    #expect(try Data(contentsOf: storedURL).count <= MediaValidation.maxBytes(for: .image))
    #expect(ItemDraftValidation.canSave(.init(text: [name.id: "Oak"], media: [photo.id: media]), itemType: type))
    try await model.createItem(itemType: type, deckID: deck.id, values: [photo.id: .media(media), name.id: .text("Oak")])
    let summary = try #require(model.items.first)
    var item = try #require(try await model.item(id: summary.id)?.item)
    #expect(item.deckID == deck.id)
    #expect(item.value(for: photo.id) == .media(media))
    #expect(item.value(for: photo.id)?.mediaReference?.altText?.isEmpty != false)
    media.altText = "Updated visual description"
    item.fields = [FieldValue(fieldID: photo.id, value: .media(media)), FieldValue(fieldID: name.id, value: .text("Oak"))]
    try await model.updateItem(item)
    #expect(try await model.item(id: item.id)?.item.value(for: photo.id) == .media(media))
    media.altText = "   "
    item.fields = [FieldValue(fieldID: photo.id, value: .media(media)), FieldValue(fieldID: name.id, value: .text("Oak"))]
    try await model.updateItem(item)
    #expect(try await model.item(id: item.id)?.item.value(for: photo.id) == .media(media))
    let cards = try await repository.dueCards(scope: .deck(deck.id), asOf: .now)
    #expect(cards.count == 1)
    #expect(model.decks.count == 1)
}

private func oversizedAuthoringPhoto() throws -> Data {
    let width = 2300, height = 1600
    let provider = try #require(CGDataProvider(data: Data(repeating: 180, count: width * height * 4) as CFData))
    let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
        bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 1]] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}
