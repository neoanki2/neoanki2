import Foundation

/// A deck with aggregate counts for list and tree display.
public struct DeckSummary: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let parentID: UUID?
    /// Items assigned directly to this deck (not nested subdecks).
    public let itemCount: Int
    /// Due cards in this deck and all descendant decks.
    public let dueCount: Int

    public init(
        id: UUID,
        name: String,
        parentID: UUID?,
        itemCount: Int,
        dueCount: Int
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.itemCount = itemCount
        self.dueCount = dueCount
    }
}
