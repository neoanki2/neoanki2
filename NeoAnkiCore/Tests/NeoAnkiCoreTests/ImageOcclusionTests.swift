import Foundation
import SQLite3
import Testing
@testable import NeoAnkiCore

private func occlusionFixture(image: MediaRef? = nil) -> ImageOcclusionContent {
    let reference = image ?? MediaRef(kind: .image, assetHash: String(repeating: "a", count: 64), fileExtension: "png", altText: "A labeled diagram")
    var content = ImageOcclusionContent(image: reference)
    content.addMask(rect: .init(x: 0.1, y: 0.1, width: 0.4, height: 0.4))
    content.addMask(rect: .init(x: 0.3, y: 0.3, width: 0.4, height: 0.4))
    content.masks[0].answerText = "First answer"
    return content
}

private func occlusionType() -> ItemType {
    let field = FieldDef(name: "Image", type: .imageOcclusion, isRequired: true)
    return ItemType(name: "Image Occlusion", fields: [field], templates: [
        Template(name: "Regions", prompt: .init(slots: [.init(source: .field(field.id))]),
                 answer: .init(slots: [.init(source: .field(field.id))]), interaction: .imageOcclusion,
                 skill: .init(input: .image, output: .freeResponse, operation: .recall)),
    ])
}

@Test func occlusionValidatesGeometryGroupsAndImageDescription() throws {
    let valid = occlusionFixture()
    try ImageOcclusionValidation.validate(valid)
    for invalid in [
        OcclusionRect(x: -0.1, y: 0, width: 0.5, height: 0.5),
        OcclusionRect(x: 0.8, y: 0, width: 0.3, height: 0.5),
        OcclusionRect(x: 0, y: 0, width: 0, height: 0.5),
        OcclusionRect(x: .nan, y: 0, width: 0.5, height: 0.5),
    ] {
        var content = valid; content.masks[0].rect = invalid
        #expect(throws: DatabaseError.self) { try ImageOcclusionValidation.validate(content) }
    }
    var missingDescription = valid; missingDescription.image.altText = " "
    #expect(throws: DatabaseError.self) { try ImageOcclusionValidation.validate(missingDescription) }
    var duplicate = valid; duplicate.masks.append(duplicate.masks[0])
    #expect(throws: DatabaseError.self) { try ImageOcclusionValidation.validate(duplicate) }
    var badGroup = valid; badGroup.nextGroup = 2
    #expect(throws: DatabaseError.self) { try ImageOcclusionValidation.validate(badGroup) }
    var wrongMedia = valid; wrongMedia.image.kind = .gif
    #expect(throws: DatabaseError.self) { try ImageOcclusionValidation.validate(wrongMedia) }
    var retired = valid; retired.masks.removeLast()
    retired.nextGroup = 2
    try ImageOcclusionValidation.validate(retired)
    #expect(throws: DatabaseError.self) { try ImageOcclusionValidation.validateTransition(from: valid, to: retired) }
    var replacement = valid; replacement.image.assetHash = String(repeating: "b", count: 64)
    #expect(throws: DatabaseError.self) { try ImageOcclusionValidation.validateTransition(from: valid, to: replacement) }
    replacement.masks = []
    replacement.addMask(rect: valid.masks[0].rect)
    try ImageOcclusionValidation.validateTransition(from: valid, to: replacement)
}

@Test func occlusionRevealSubtractsOverlapsAndNeverLeaksAnswerText() {
    var content = occlusionFixture()
    #expect(content.coveredRects(group: 1, revealed: false).count == 2)
    let pieces = content.coveredRects(group: 1, revealed: true)
    #expect(pieces.count == 2)
    // 0.16 other-mask area minus the 0.04 intersection.
    #expect(abs(pieces.reduce(0) { $0 + $1.width * $1.height } - 0.12) < 0.000001)
    #expect(content.revealedAnswerText(group: 1, revealed: false).isEmpty)
    #expect(content.revealedAnswerText(group: 1, revealed: true) == "First answer")
    content.mode = .hideOneRevealOne
    #expect(content.coveredRects(group: 1, revealed: false) == [content.masks[0].rect])
    #expect(content.coveredRects(group: 1, revealed: true).isEmpty)
    #expect(content.coveredRects(group: 99, revealed: true).count == 2)
    #expect(content.displayGroup(cardGroup: nil, allowsPreview: false) == nil)
    #expect(content.displayGroup(cardGroup: 99, allowsPreview: true) == nil)
    #expect(content.displayGroup(cardGroup: nil, allowsPreview: true) == 1)
    #expect(content.displayGroup(cardGroup: 2, allowsPreview: false) == 2)
}

@Test func occlusionGroupingUsesStableSchedulingCoordinates() throws {
    var content = occlusionFixture()
    let type = occlusionType()
    let itemID = UUID()
    func cards(_ content: ImageOcclusionContent) -> [Card] {
        CardGenerator.cards(for: Item(id: itemID, itemTypeID: type.id,
                                     fields: [.init(fieldID: type.fields[0].id, value: .imageOcclusion(content))]),
                            type: type, deterministicIDs: true)
    }
    let initial = cards(content)
    #expect(initial.compactMap(\.occlusionGroup) == [1, 2])
    #expect(initial.allSatisfy { $0.clozeGroup == nil })
    content.masks[0].rect.x = 0.2
    content.mode = .hideOneRevealOne
    content.masks.reverse()
    #expect(cards(content).map(\.id) == initial.map(\.id))
    content.masks[0].group = 1
    #expect(cards(content).count == 1)
    content.ungroup(maskIDs: [content.masks[0].id])
    #expect(content.groups == [1, 3])
    content.masks = []
    content.addMask(rect: .init(x: 0, y: 0, width: 0.5, height: 0.5))
    #expect(content.groups == [4])
}

@Test func occlusionNativeAndPortableSerializationRetainMasks() throws {
    let content = occlusionFixture()
    let native = try JSONDecoder().decode(ContentValue.self, from: JSONEncoder().encode(ContentValue.imageOcclusion(content)))
    #expect(native == .imageOcclusion(content))
    let portable = try PortableJSON.encodeContent(native)
    let decoded = try PortableJSON.decodeContent(portable)
    guard case let .imageOcclusion(roundTrip) = decoded else { Issue.record("Lost occlusion content"); return }
    #expect(roundTrip.masks == content.masks)
    #expect(roundTrip.image.assetHash == content.image.assetHash)
    #expect(roundTrip.nextGroup == content.nextGroup)
    #expect(throws: Error.self) { try PortableJSON.decodeContent(portable, formatVersion: 5) }
}

@Test func occlusionEditPreservesMemoryAndExportPreservesImage() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let media = try MediaStore(rootDirectory: root)
    let databaseURL = root.appendingPathComponent("library.sqlite")
    let store = try ItemStore(databaseURL: databaseURL, mediaStore: media)
    try await store.bootstrap()
    let type = occlusionType()
    _ = try await store.createItemType(type)
    let deck = try await store.createDeck(.init(name: "Diagrams"))
    let image = try await media.ingest(data: Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), kind: .image, fileExtension: "png", altText: "A diagram")
    var content = occlusionFixture(image: image)
    var item = Item(itemTypeID: type.id, fields: [.init(fieldID: type.fields[0].id, value: .imageOcclusion(content))], deckID: deck.id)
    _ = try await store.createItem(item)
    let database = try SQLiteDatabase(path: databaseURL)
    let first = try #require(try await database.fetchCards(for: item.id).first { $0.occlusionGroup == 1 })
    _ = try await store.submitReview(cardID: first.id, rating: .good)
    let learned = try #require(try await database.fetchCard(id: first.id))
    content.masks[0].rect.width = 0.3; content.mode = .hideOneRevealOne
    item.fields[0].value = .imageOcclusion(content)
    _ = try await store.updateItem(item)
    #expect(try await database.fetchCard(id: first.id)?.memory == learned.memory)
    #expect(try await store.mediaAsset(hash: image.assetHash)?.refCount == 1)
    let package = root.appendingPathComponent("diagrams.neodeck")
    try await PortableDeck.export(deckID: deck.id, from: store, to: package)
    let targetRoot = root.appendingPathComponent("target")
    let targetMedia = try MediaStore(rootDirectory: targetRoot)
    let target = try ItemStore(databaseURL: targetRoot.appendingPathComponent("library.sqlite"), mediaStore: targetMedia)
    try await target.bootstrap()
    let result = try await PortableDeck.importDeck(from: package, into: target)
    #expect(result.itemCount == 1)
    #expect(try await target.dueCount() == 2)
    #expect(try await target.mediaAsset(hash: image.assetHash)?.refCount == 1)
    let imported = try #require(try await target.listItems().first)
    let loaded = try #require(try await target.fetchItem(id: imported.id))
    guard case let .imageOcclusion(restored)? = loaded.item.value(for: loaded.itemType.fields[0].id) else { Issue.record("Missing imported masks"); return }
    #expect(restored.masks == content.masks)
    #expect(restored.mode == content.mode)
    #expect(FileManager.default.fileExists(atPath: try await targetMedia.resolve(restored.image).path))
    content.masks.removeAll { $0.group == 2 }
    item.fields[0].value = .imageOcclusion(content)
    _ = try await store.updateItem(item)
    #expect(try await database.fetchCards(for: item.id).count == 1)
    #expect(try await database.fetchCard(id: first.id)?.memory == learned.memory)
    content.masks.append(.init(group: 1, rect: .init(x: 0.6, y: 0.6, width: 0.2, height: 0.2)))
    item.fields[0].value = .imageOcclusion(content)
    _ = try await store.updateItem(item)
    #expect(try await database.fetchCards(for: item.id).map(\.id) == [first.id])
    content.ungroup(maskIDs: [content.masks[1].id])
    item.fields[0].value = .imageOcclusion(content)
    _ = try await store.updateItem(item)
    #expect(try await database.fetchCard(id: first.id)?.memory == learned.memory)
    let beforeReplacement = try await database.fetchCards(for: item.id)
    content.image = try await media.ingest(data: Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 2]), kind: .image, fileExtension: "png", altText: "Replacement diagram")
    content.masks = []
    content.addMask(rect: .init(x: 0.2, y: 0.1, width: 0.3, height: 0.3))
    item.fields[0].value = .imageOcclusion(content)
    _ = try await store.updateItem(item)
    let afterReplacement = try await database.fetchCards(for: item.id)
    #expect(afterReplacement.count == 1)
    #expect(!beforeReplacement.map(\.id).contains(afterReplacement[0].id))
    #expect(afterReplacement[0].memory.reps == 0)
    #expect(try await database.countRawReviewLogs(for: first.id) == 1)
    #expect(try await store.mediaAsset(hash: image.assetHash)?.refCount == 0)
    _ = try await store.collectMediaGarbage()
    #expect(try await store.mediaAsset(hash: image.assetHash) == nil)
    #expect(try await store.mediaAsset(hash: content.image.assetHash)?.refCount == 1)
}

@Test func occlusionBulkDryRunMatchesCommitAndReleasesOnlyAbandonedMedia() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let media = try MediaStore(rootDirectory: root)
    let store = try ItemStore(databaseURL: root.appendingPathComponent("library.sqlite"), mediaStore: media)
    try await store.bootstrap()
    let type = occlusionType()
    _ = try await store.createItemType(type)
    let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    let image = try await media.ingest(data: bytes, kind: .image, fileExtension: "png", altText: "Diagram")
    let content = occlusionFixture(image: image)
    let item = Item(itemTypeID: type.id, fields: [.init(fieldID: type.fields[0].id, value: .imageOcclusion(content))])
    let operations = [ItemBulkOperation(operationID: "create", action: .create(item))]
    let dry = try await store.executeItemBulk(operations, dryRun: true)
    #expect(try await store.listItems().isEmpty)
    #expect(dry[0].cardIDs.count == 2)
    let committed = try await store.executeItemBulk(operations, dryRun: false)
    #expect(dry == committed)
    let firstDeck = try await store.createDeck(.init(name: "First", newCardsPerDay: 1))
    let secondDeck = try await store.createDeck(.init(name: "Second", newCardsPerDay: 1))
    var assigned = item; assigned.deckID = firstDeck.id
    _ = try await store.updateItem(assigned)
    let stored = try #require(try await store.fetchItem(id: item.id))
    let secondItem = Item(itemTypeID: type.id, fields: stored.item.fields, deckID: secondDeck.id)
    _ = try await store.createItem(secondItem)
    let limited = try await store.fetchDueCards()
    #expect(limited.count == 2)
    #expect(limited.allSatisfy { $0.card.occlusionGroup != nil })
    // Saving adopts the reservation; outer editor cleanup must leave it intact.
    try await media.discardDraftReference(image)
    #expect(try await store.mediaAsset(hash: image.assetHash)?.refCount == 2)
    let discarded = try await media.ingest(data: bytes + Data([1]), kind: .image, fileExtension: "png")
    try await media.discardDraftReference(discarded)
    #expect(try await store.mediaAsset(hash: discarded.assetHash) == nil)
    await #expect(throws: MediaError.self) { _ = try await media.resolve(discarded) }
    #expect(try await store.deleteItem(id: item.id))
    #expect(try await store.deleteItem(id: secondItem.id))
    #expect(try await store.mediaAsset(hash: image.assetHash) == nil)
}

@Test func occlusionStructuredJSONAndAuthoredVersionSixImportRealMedia() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    try bytes.write(to: root.appendingPathComponent("image.png"))
    let store = try ItemStore(databaseURL: root.appendingPathComponent("library.sqlite"))
    try await store.bootstrap()
    let type = occlusionType()
    _ = try await store.createItemType(type)
    let masks = occlusionFixture().masks
    let maskJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(masks))
    let json: [String: Any] = ["itemType": type.name, "rows": [["Image": ["imageOcclusion": ["path": "image.png", "altText": "Diagram", "mode": "hideOneRevealOne", "masks": maskJSON, "nextGroup": 3]]]]]
    #expect(try await store.importItems(from: JSONSerialization.data(withJSONObject: json), adapter: JSONImportAdapter(), itemTypeID: type.id, context: .init(baseDirectory: root)) == 1)
    #expect(try await store.dueCount() == 2)
    let bundle = root.appendingPathComponent("Diagrams.neoanki")
    try FileManager.default.createDirectory(at: bundle.appendingPathComponent("items"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bundle.appendingPathComponent("media"), withIntermediateDirectories: true)
    try bytes.write(to: bundle.appendingPathComponent("media/image.png"))
    let records = [
        #"{"kind":"neoanki","version":6,"root":"root","parts":["items/items.jsonl"]}"#,
        #"{"kind":"deck","id":"root","name":"Diagrams","itemTypes":["Occlusion"],"defaultType":"Occlusion"}"#,
        #"{"kind":"type","id":"Occlusion","name":"Occlusion","fields":[{"id":"image","name":"Image","type":"imageOcclusion","required":true}],"templates":[{"name":"Regions","prompt":[{"field":"image"}],"answer":[{"field":"image"}],"interaction":"imageOcclusion","skill":{"input":"image","output":"freeResponse","operation":"recall"}}]}"#,
    ]
    let manifest = bundle.appendingPathComponent("deck.jsonl")
    try records.joined(separator: "\n").write(to: manifest, atomically: true, encoding: .utf8)
    let itemRecord: [String: Any] = ["kind": "item", "deck": "root", "type": "Occlusion", "fields": ["image": ["imageOcclusion": ["image": ["path": "media/image.png", "alt": "Diagram"], "mode": "hideAllRevealOne", "masks": maskJSON, "nextGroup": 3]]]]
    try JSONSerialization.data(withJSONObject: itemRecord).write(to: bundle.appendingPathComponent("items/items.jsonl"))
    #expect(AuthoredDeck.validate(at: bundle).isEmpty)
    let target = try ItemStore(databaseURL: root.appendingPathComponent("target/library.sqlite"))
    try await target.bootstrap()
    let imported = try await AuthoredDeck.importDeck(from: bundle, into: target)
    #expect(imported.itemCount == 1)
    #expect(try await target.dueCount() == 2)
    try records.joined(separator: "\n").replacingOccurrences(of: "\"version\":6", with: "\"version\":5").write(to: manifest, atomically: true, encoding: .utf8)
    #expect(!AuthoredDeck.validate(at: bundle).isEmpty)
}

@Test func occlusionMigrationAddsColumnWithoutChangingExistingCards() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("library.sqlite")
    let store = try ItemStore(databaseURL: url)
    try await store.bootstrap()
    let type = try await store.defaultItemType()
    let item = Item(itemTypeID: type.id, fields: type.fields.map { .init(fieldID: $0.id, value: .text("Content")) })
    _ = try await store.createItem(item)
    let database = try SQLiteDatabase(path: url)
    let before = try await database.fetchCards(for: item.id)
    var connection: OpaquePointer?
    #expect(sqlite3_open(url.path, &connection) == SQLITE_OK)
    defer { sqlite3_close(connection) }
    #expect(sqlite3_exec(connection, "ALTER TABLE cards DROP COLUMN occlusion_group; UPDATE schema_version SET version = 29;", nil, nil, nil) == SQLITE_OK)
    try await database.migrate()
    #expect(try await database.fetchCards(for: item.id) == before)
}
