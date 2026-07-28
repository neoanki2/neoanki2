import Foundation

/// A study grouping for cards. Hierarchical via `parentID` so users can nest
/// decks, with an optional learner-local throttle for introducing new cards.
public struct Deck: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var parentID: UUID?
    /// Nil keeps the deck unlimited; zero temporarily pauses new introductions.
    public var newCardsPerDay: Int?

    public init(
        id: UUID = UUID(),
        name: String,
        parentID: UUID? = nil,
        newCardsPerDay: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.newCardsPerDay = newCardsPerDay
    }
}
