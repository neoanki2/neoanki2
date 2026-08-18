import Foundation
import Testing
@testable import NeoAnkiCore

@Test func deckTreeBuildsNestedHierarchy() {
    let parentID = UUID()
    let childID = UUID()
    let summaries = [
        DeckSummary(id: parentID, name: "Geography", parentID: nil, itemCount: 0, dueCount: 0),
        DeckSummary(id: childID, name: "Capitals", parentID: parentID, itemCount: 0, dueCount: 0),
    ]

    let tree = DeckTree.build(from: summaries)

    #expect(tree.count == 1)
    #expect(tree.first?.summary.name == "Geography")
    #expect(tree.first?.children.count == 1)
    #expect(tree.first?.children.first?.summary.name == "Capitals")
}

@Test func deckTreeUsesPersistedSiblingOrderBeforeName() {
    let firstID = UUID()
    let secondID = UUID()
    let summaries = [
        DeckSummary(
            id: firstID,
            name: "Zulu",
            parentID: nil,
            sortPosition: 0,
            itemCount: 0,
            dueCount: 0
        ),
        DeckSummary(
            id: secondID,
            name: "Alpha",
            parentID: nil,
            sortPosition: 1,
            itemCount: 0,
            dueCount: 0
        ),
    ]

    #expect(DeckTree.build(from: summaries).map(\.id) == [firstID, secondID])
}

@Test func deckTreeDescendantIDsIncludesNestedDecks() {
    let parentID = UUID()
    let childID = UUID()
    let grandchildID = UUID()
    let summaries = [
        DeckSummary(id: parentID, name: "Geography", parentID: nil, itemCount: 0, dueCount: 0),
        DeckSummary(id: childID, name: "Capitals", parentID: parentID, itemCount: 0, dueCount: 0),
        DeckSummary(id: grandchildID, name: "Europe", parentID: childID, itemCount: 0, dueCount: 0),
    ]

    let descendants = DeckTree.descendantIDs(of: parentID, in: summaries)

    #expect(descendants == Set([parentID, childID, grandchildID]))
}

@Test func deckTreeDetectsReparentCycle() {
    let parentID = UUID()
    let childID = UUID()
    let summaries = [
        DeckSummary(id: parentID, name: "Geography", parentID: nil, itemCount: 0, dueCount: 0),
        DeckSummary(id: childID, name: "Capitals", parentID: parentID, itemCount: 0, dueCount: 0),
    ]

    #expect(DeckTree.wouldCreateCycle(deckID: parentID, newParentID: childID, in: summaries))
    #expect(DeckTree.wouldCreateCycle(deckID: parentID, newParentID: parentID, in: summaries))
    #expect(!DeckTree.wouldCreateCycle(deckID: childID, newParentID: nil, in: summaries))
}
