import Foundation

/// Filters items and due cards by deck assignment.
public enum DeckScope: Sendable, Equatable, Hashable {
    case allDecks
    case unassigned
    case deck(UUID, includeDescendants: Bool = true)
}
