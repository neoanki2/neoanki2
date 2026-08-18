import Foundation

public struct DeckNode: Sendable, Identifiable, Equatable {
    public let summary: DeckSummary
    public var children: [DeckNode]

    public var id: UUID { summary.id }

    public init(summary: DeckSummary, children: [DeckNode] = []) {
        self.summary = summary
        self.children = children
    }
}

public enum DeckTree {
    /// Builds a forest using learner-defined sibling order, with stable
    /// name/identifier fallbacks for decks created before ordering existed.
    public static func build(from summaries: [DeckSummary]) -> [DeckNode] {
        let byParent = Dictionary(grouping: summaries, by: { $0.parentID })
        func nodes(for parentID: UUID?) -> [DeckNode] {
            let children = (byParent[parentID] ?? []).sorted(by: areInDisplayOrder)
            return children.map { summary in
                DeckNode(summary: summary, children: nodes(for: summary.id))
            }
        }
        return nodes(for: nil)
    }

    public static func areInDisplayOrder(_ lhs: DeckSummary, _ rhs: DeckSummary) -> Bool {
        if lhs.sortPosition != rhs.sortPosition {
            return lhs.sortPosition < rhs.sortPosition
        }
        let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// Returns the given deck and all nested subdeck IDs.
    public static func descendantIDs(of deckID: UUID, in summaries: [DeckSummary]) -> Set<UUID> {
        let byParent = Dictionary(grouping: summaries, by: { $0.parentID })
        var result: Set<UUID> = [deckID]
        var frontier = [deckID]
        while let current = frontier.popLast() {
            for child in byParent[current] ?? [] {
                if result.insert(child.id).inserted {
                    frontier.append(child.id)
                }
            }
        }
        return result
    }

    /// Returns true when `candidateParentID` is the deck itself or one of its descendants.
    public static func wouldCreateCycle(
        deckID: UUID,
        newParentID: UUID?,
        in summaries: [DeckSummary]
    ) -> Bool {
        guard let newParentID else { return false }
        if newParentID == deckID { return true }
        let descendants = descendantIDs(of: deckID, in: summaries)
        return descendants.contains(newParentID)
    }
}
