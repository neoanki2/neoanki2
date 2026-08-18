import Foundation

/// A semantic deck-tree move. Using neighboring deck identifiers keeps the
/// command stable even when another move changes numeric positions first.
public enum DeckMoveDestination: Sendable, Equatable {
    case before(UUID)
    case after(UUID)
    case inside(UUID)
    case topLevel
}
