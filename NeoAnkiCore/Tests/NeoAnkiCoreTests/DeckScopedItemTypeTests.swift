import Foundation
import SQLite3
import Testing
@testable import NeoAnkiCore

private func scopeFixture() async throws -> (ItemStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("deck-types-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("library.sqlite")
    let store = try ItemStore(databaseURL: url)
    try await store.bootstrap()
    return (store, url)
}

@Test func deckTypesStayInsideTheirDeckAndReuseKeepsIdentity() async throws {
    let (store, _) = try await scopeFixture()
    let body = try await store.createDeck(Deck(name: "Human Body"))
    let grammar = try await store.createDeck(Deck(name: "Grammar"))
    let organ = try await store.createItemType(BuiltInItemTypes.basic.duplicated(name: "Organ"), deckID: body.id, availableEverywhere: false)
    #expect(try await store.authoringItemTypes(for: body.id).itemTypes.map(\.id) == [organ.id])
    #expect(try await store.authoringItemTypes(for: grammar.id).itemTypes.contains { $0.id == organ.id } == false)
    #expect(try await store.loadItemTypeCatalog().itemTypes.contains { $0.id == organ.id } == false)
    try await store.attachItemType(id: organ.id, to: grammar.id)
    #expect(try await store.authoringItemTypes(for: grammar.id).itemTypes.map(\.id) == [organ.id])
    var renamed = organ; renamed.name = "Anatomy"
    _ = try await store.updateItemType(renamed)
    #expect(try await store.authoringItemTypes(for: grammar.id).itemTypes.first?.name == "Anatomy")
}

@Test func subdeckOverrideCanBeEmptyAndInheritanceCanBeRestored() async throws {
    let (store, _) = try await scopeFixture()
    let parent = try await store.createDeck(Deck(name: "Parent"))
    let child = try await store.createDeck(Deck(name: "Child", parentID: parent.id))
    let type = try await store.createItemType(BuiltInItemTypes.basic.duplicated(name: "Local"), deckID: parent.id, availableEverywhere: false)
    #expect(try await store.authoringItemTypes(for: child.id).sourceDeckID == parent.id)
    try await store.setDeckItemTypes(.init(deckID: child.id))
    #expect(try await store.authoringItemTypes(for: child.id).usesSharedFallback)
    #expect(try await store.authoringItemTypes(for: child.id).itemTypes.contains { $0.id == type.id } == false)
    try await store.setDeckItemTypes(.init(deckID: child.id, inherits: true))
    #expect(try await store.authoringItemTypes(for: child.id).itemTypes.map(\.id) == [type.id])
}

@Test func legacyUnscopedCreationNeedsOrganizationAndUnlockDoesNotShare() async throws {
    let (store, _) = try await scopeFixture()
    let type = try await store.createItemType(BuiltInItemTypes.basic.duplicated(name: "Legacy"))
    #expect(try await store.loadItemTypeCatalog().needsOrganization.contains { $0.id == type.id })
    _ = try await store.unlockItemType(id: type.id)
    #expect(try await store.authoringItemTypes(for: nil).itemTypes.contains { $0.id == type.id } == false)
    try await store.setItemTypeAvailability(id: type.id, availableEverywhere: true)
    #expect(try await store.authoringItemTypes(for: nil).itemTypes.contains { $0.id == type.id })
}

@Test func removingAttachmentAndMovingItemsPreservesCardsAndHistory() async throws {
    let (store, _) = try await scopeFixture()
    let first = try await store.createDeck(Deck(name: "First"))
    let second = try await store.createDeck(Deck(name: "Second"))
    let type = try await store.createItemType(BuiltInItemTypes.basic.duplicated(name: "Local"), deckID: first.id, availableEverywhere: false)
    let item = Item(itemTypeID: type.id, fields: type.fields.map { .init(fieldID: $0.id, value: .text($0.name)) }, deckID: first.id)
    _ = try await store.createItem(item)
    let before = try await store.cards()
    try await store.setDeckItemTypes(.init(deckID: first.id))
    _ = try await store.updateItemDeck(itemID: item.id, deckID: second.id)
    let after = try await store.cards()
    #expect(after.map(\.id) == before.map(\.id))
    #expect(after.map(\.memory) == before.map(\.memory))
    #expect(try await store.itemRecord(id: item.id).item.itemTypeID == type.id)
    #expect(try await store.authoringItemTypes(for: second.id).itemTypes.contains { $0.id == type.id } == false)
}

@Test func scopeMetadataWinsOverLateLegacyMemberships() async throws {
    let (store, _) = try await scopeFixture()
    let deck = try await store.createDeck(Deck(name: "Deck"))
    let type = try await store.createItemType(BuiltInItemTypes.basic.duplicated(name: "Local"), deckID: deck.id, availableEverywhere: false)
    try await store.applySynchronizedBatch([.itemTypeMembership(.library(itemTypeID: type.id))])
    #expect(try await store.authoringItemTypes(for: nil).itemTypes.contains { $0.id == type.id } == false)
    #expect(try await store.authoringItemTypes(for: deck.id).itemTypes.map(\.id) == [type.id])
}

@Test func portableRoundTripPreservesEmptyOverridesAndLinkedTypes() async throws {
    let (store, url) = try await scopeFixture()
    let root = try await store.createDeck(Deck(name: "Root"))
    let child = try await store.createDeck(Deck(name: "Empty", parentID: root.id))
    let type = try await store.createItemType(BuiltInItemTypes.basic.duplicated(name: "Organ"), deckID: root.id, availableEverywhere: false)
    try await store.setDeckItemTypes(.init(deckID: root.id, itemTypeIDs: [type.id], defaultItemTypeID: type.id))
    try await store.setDeckItemTypes(.init(deckID: child.id))
    let file = url.deletingLastPathComponent().appendingPathComponent("export.neodeck")
    try await PortableDeck.export(deckID: root.id, from: store, to: file)
    let (destination, _) = try await scopeFixture()
    let result = try await PortableDeck.importDeck(from: file, into: destination)
    let importedRoot = try #require(result.deckIDs.first)
    let decks = try await destination.listDecks()
    let importedChild = try #require(decks.first { $0.parentID == importedRoot })
    #expect(try await destination.authoringItemTypes(for: importedRoot).itemTypes.first?.name == "Organ")
    #expect(try await destination.authoringItemTypes(for: importedRoot).defaultItemTypeID != nil)
    #expect(try await destination.authoringItemTypes(for: importedChild.id).usesSharedFallback)
    #expect(try await destination.authoringItemTypes(for: nil).itemTypes.contains { $0.name == "Organ" } == false)
}


@Test func automaticScopeMigrationPreservesContentAndIsIdempotent() async throws {
    let (store, url) = try await scopeFixture()
    let first = try await store.createDeck(Deck(name: "First"))
    let second = try await store.createDeck(Deck(name: "Second"))
    let used = try await store.createItemType(BuiltInItemTypes.basic.duplicated(name: "Used"))
    let unused = try await store.createItemType(BuiltInItemTypes.basic.duplicated(name: "Unused"))
    for deck in [first, second] {
        _ = try await store.createItem(Item(itemTypeID: used.id, fields: used.fields.map { .init(fieldID: $0.id, value: .text($0.name)) }, deckID: deck.id))
    }
    let before = try await store.cards()
    var handle: OpaquePointer?
    #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
    defer { sqlite3_close(handle) }
    #expect(sqlite3_exec(handle, "DELETE FROM item_type_settings; DELETE FROM deck_item_type_settings; UPDATE schema_version SET version = 30;", nil, nil, nil) == SQLITE_OK)
    let database = try SQLiteDatabase(path: url)
    try await database.migrate()
    try await database.migrate()
    #expect(try await store.authoringItemTypes(for: first.id).itemTypes.map(\.id) == [used.id])
    #expect(try await store.authoringItemTypes(for: second.id).itemTypes.map(\.id) == [used.id])
    #expect(try await store.loadItemTypeCatalog().needsOrganization.contains { $0.id == unused.id })
    #expect(try await store.cards() == before)
}

@Test func linkedEditImpactIncludesInheritedAndSharedFallbackDecks() async throws {
    let (store, _) = try await scopeFixture()
    let parent = try await store.createDeck(Deck(name: "Parent"))
    let child = try await store.createDeck(Deck(name: "Child", parentID: parent.id))
    let local = try await store.createItemType(BuiltInItemTypes.basic.duplicated(name: "Local"), deckID: parent.id, availableEverywhere: false)
    #expect(try await store.itemTypeEditingImpact(id: local.id).deckPaths == ["Parent", "Parent / Child"])
    try await store.setDeckItemTypes(.init(deckID: child.id))
    #expect(try await store.itemTypeEditingImpact(id: BuiltInItemTypes.basicID).deckPaths == ["Parent / Child"])
}


@Test func deletingUnusedAttachedTypeRemovesItsDefaultAndExportReferences() async throws {
    let (store, url) = try await scopeFixture()
    let deck = try await store.createDeck(Deck(name: "Deck"))
    let type = try await store.createItemType(BuiltInItemTypes.basic.duplicated(name: "Temporary"), deckID: deck.id, availableEverywhere: false)
    try await store.setDeckItemTypes(.init(deckID: deck.id, itemTypeIDs: [type.id], defaultItemTypeID: type.id))
    #expect(try await store.deleteItemType(id: type.id))
    #expect(try await store.authoringItemTypes(for: deck.id).usesSharedFallback)
    try await PortableDeck.export(deckID: deck.id, from: store, to: url.deletingLastPathComponent().appendingPathComponent("empty.neodeck"))
}
