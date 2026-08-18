import Foundation

/// A deck with aggregate counts for list and tree display.
public struct DeckSummary: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let parentID: UUID?
    public let newCardsPerDay: Int?
    /// Learner-defined order among decks with the same parent.
    public let sortPosition: Int64
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
        sortPosition: Int64 = 0,
        itemCount: Int,
        dueCount: Int
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.newCardsPerDay = newCardsPerDay
        self.sortPosition = sortPosition
        self.itemCount = itemCount
        self.dueCount = dueCount
    }
}
