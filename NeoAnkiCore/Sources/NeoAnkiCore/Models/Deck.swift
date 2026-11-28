import Foundation

/// A study grouping for cards. Hierarchical via `parentID` so users can nest
/// decks, with an optional learner-local throttle for introducing new cards.
public struct Deck: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var parentID: UUID?
    /// Nil keeps the deck unlimited; zero temporarily pauses new introductions.
    public var newCardsPerDay: Int?
    /// Controls whether this branch participates in study from All Decks.
    public var includeInAllDecksStudy: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        parentID: UUID? = nil,
        newCardsPerDay: Int? = nil,
        includeInAllDecksStudy: Bool = true
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.newCardsPerDay = newCardsPerDay
        self.includeInAllDecksStudy = includeInAllDecksStudy
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            name: try values.decode(String.self, forKey: .name),
            parentID: try values.decodeIfPresent(UUID.self, forKey: .parentID),
            newCardsPerDay: try values.decodeIfPresent(Int.self, forKey: .newCardsPerDay),
            includeInAllDecksStudy: try values.decodeIfPresent(Bool.self, forKey: .includeInAllDecksStudy) ?? true
        )
    }
}
