import Foundation

/// Normalizes every import writer's input, preserving the source's sibling order.
enum DeckImportOrdering {
    static func parentFirst(_ decks: [Deck]) throws -> [Deck] {
        let ids = Set(decks.map(\.id))
        guard ids.count == decks.count,
              decks.allSatisfy({ $0.parentID.map(ids.contains) ?? true }) else {
            throw PortableDeckError.invalidPackage("Deck identities or parents are invalid.")
        }
        let children = Dictionary(grouping: decks, by: \.parentID)
        var pending = Array((children[nil] ?? []).reversed())
        var ordered: [Deck] = []
        ordered.reserveCapacity(decks.count)
        while let deck = pending.popLast() {
            ordered.append(deck)
            pending.append(contentsOf: (children[deck.id] ?? []).reversed())
        }
        guard ordered.count == decks.count else {
            throw PortableDeckError.invalidPackage("The deck hierarchy contains a cycle.")
        }
        return ordered
    }
}
