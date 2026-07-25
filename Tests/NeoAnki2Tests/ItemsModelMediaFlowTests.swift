import Foundation
import NeoAnkiCore
import Testing

@testable import NeoAnki2

@Test @MainActor func itemsModelMediaEditMaintainsDescriptionsAndReferenceCounts() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-items-media-flow-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try ItemStore(databaseURL: root.appendingPathComponent("test.sqlite"))
    try await store.bootstrap()
    let mediaStore = try #require(await store.media)
    let model = ItemsModel(store: store, mediaStore: mediaStore)

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

    let firstData = try #require(Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    ))
    var secondData = firstData
    secondData.append(0x00)
    let first = try await mediaStore.ingest(data: firstData, kind: .image, fileExtension: "png")
    let second = try await mediaStore.ingest(data: secondData, kind: .image, fileExtension: "png")

    #expect(await model.addItem(
        fieldSpans: [captionField.id: [Span("First")]],
        fieldMedia: [imageField.id: first],
        fieldMediaAltText: [imageField.id: "First diagram"]
    ))
    let itemID = try #require(model.items.first?.id)
    var stored = try #require(try await store.fetchItem(id: itemID)?.item)
    guard case let .media(savedFirst)? = stored.value(for: imageField.id) else {
        Issue.record("Expected stored image media.")
        return
    }
    #expect(savedFirst.altText == "First diagram")
    #expect(try await store.mediaAsset(hash: first.assetHash)?.refCount == 1)

    #expect(await model.updateItem(
        id: itemID,
        fieldSpans: [captionField.id: [Span("Second")]],
        fieldMedia: [imageField.id: second],
        fieldMediaAltText: [imageField.id: "Second diagram"]
    ))
    #expect(try await store.mediaAsset(hash: first.assetHash)?.refCount == 0)
    #expect(try await store.mediaAsset(hash: second.assetHash)?.refCount == 1)
    stored = try #require(try await store.fetchItem(id: itemID)?.item)
    guard case let .media(savedSecond)? = stored.value(for: imageField.id) else {
        Issue.record("Expected updated image media.")
        return
    }
    #expect(savedSecond.altText == "Second diagram")

    #expect(await model.updateItem(
        id: itemID,
        fieldSpans: [captionField.id: [Span("Invalid")]],
        fieldMedia: [imageField.id: second],
        fieldMediaAltText: [imageField.id: "   "]
    ) == false)
    stored = try #require(try await store.fetchItem(id: itemID)?.item)
    #expect(stored.value(for: captionField.id) == .text("Second"))

    #expect(await model.deleteItem(id: itemID))
    #expect(try await store.mediaAsset(hash: first.assetHash) == nil)
    #expect(try await store.mediaAsset(hash: second.assetHash) == nil)
    #expect(model.dueCount == 0)
}
