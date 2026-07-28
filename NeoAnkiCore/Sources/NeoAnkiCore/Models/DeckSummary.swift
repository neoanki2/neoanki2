import Foundation

/// A deck with aggregate counts for list and tree display.
public struct DeckSummary: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let parentID: UUID?
    public let newCardsPerDay: Int?
    /// Items in this deck and all descendant decks, matching the scope you get
    /// by selecting the deck.
    public let itemCount: Int
    /// Due cards in this deck and all descendant decks.
    public let dueCount: Int

    public init(
        id: UUID,
        name: String,
        parentID: UUID?,
        newCardsPerDay: Int? = nil,
        itemCount: Int,
        dueCount: Int
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.newCardsPerDay = newCardsPerDay
        self.itemCount = itemCount
        self.dueCount = dueCount
    }
}
