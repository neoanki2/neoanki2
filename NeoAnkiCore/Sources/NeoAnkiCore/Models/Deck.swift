import Foundation

/// A study grouping for cards. Hierarchical via `parentID` so users can nest
/// decks; organization only, carrying no scheduling semantics itself.
public struct Deck: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var parentID: UUID?

    public init(id: UUID = UUID(), name: String, parentID: UUID? = nil) {
        self.id = id
        self.name = name
        self.parentID = parentID
    }
}
