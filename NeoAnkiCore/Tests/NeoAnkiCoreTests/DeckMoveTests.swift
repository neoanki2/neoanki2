import Foundation
import Testing
@testable import NeoAnkiCore

private func makeDeckMoveStore() async throws -> ItemStore {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-deck-move-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = try ItemStore(databaseURL: directory.appendingPathComponent("library.sqlite"))
    try await store.bootstrap()
    return store
}

@Test func deckMovesPersistSiblingOrderAndHierarchy() async throws {
    let store = try await makeDeckMoveStore()
    let alpha = try await store.createDeck(Deck(name: "Alpha"))
    let beta = try await store.createDeck(Deck(name: "Beta"))
    let gamma = try await store.createDeck(Deck(name: "Gamma"))

    #expect(try await store.moveDeck(id: gamma.id, to: .before(alpha.id)))
    var tree = DeckTree.build(from: try await store.deckSummaries())
    #expect(tree.map(\.id) == [gamma.id, alpha.id, beta.id])

    #expect(try await store.moveDeck(id: alpha.id, to: .inside(beta.id)))
    tree = DeckTree.build(from: try await store.deckSummaries())
    #expect(tree.map(\.id) == [gamma.id, beta.id])
    #expect(tree.last?.children.map(\.id) == [alpha.id])
    #expect(try await store.deck(id: alpha.id).parentID == beta.id)

    #expect(try await store.moveDeck(id: alpha.id, to: .topLevel))
    tree = DeckTree.build(from: try await store.deckSummaries())
    #expect(tree.map(\.id) == [gamma.id, beta.id, alpha.id])
    #expect(try await store.deck(id: alpha.id).parentID == nil)
}

@Test func deckMoveRejectsMovingAParentIntoItsDescendant() async throws {
    let store = try await makeDeckMoveStore()
    let parent = try await store.createDeck(Deck(name: "Parent"))
    let child = try await store.createDeck(Deck(name: "Child", parentID: parent.id))

    await #expect(throws: DatabaseError.self) {
        try await store.moveDeck(id: parent.id, to: .inside(child.id))
    }

    #expect(try await store.deck(id: parent.id).parentID == nil)
    #expect(try await store.deck(id: child.id).parentID == parent.id)
}
