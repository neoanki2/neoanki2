import Foundation

/// Local scheduling availability, independent of content and maturity reads.
/// Deck rows retain Home's global eligibility/descendant rollup semantics;
/// the selected scope is evaluated separately, just like starting study there.
public struct LibraryDueSnapshot: Sendable, Equatable {
    public let total: Int
    public let unassigned: Int
    public let decks: [UUID: Int]
    public let activeScope: DeckScope?
    public let activeScopeCount: Int?
    public let sourceRevision: Int64
    public let calculatedAt: Date
    public let validUntil: Date
    /// The next actual study opportunity, which can be later than the cache's
    /// conservative rollover expiration (or absent in an empty library).
    public let nextStudyAt: Date?

    public init(total: Int, unassigned: Int, decks: [UUID: Int], activeScope: DeckScope?,
                activeScopeCount: Int?, sourceRevision: Int64, calculatedAt: Date, validUntil: Date,
                nextStudyAt: Date? = nil) {
        self.total = total; self.unassigned = unassigned; self.decks = decks
        self.activeScope = activeScope; self.activeScopeCount = activeScopeCount
        self.sourceRevision = sourceRevision; self.calculatedAt = calculatedAt; self.validUntil = validUntil
        self.nextStudyAt = nextStudyAt
    }

    public func count(for scope: DeckScope) -> Int? {
        switch scope {
        case .allDecks: return total
        case .unassigned: return unassigned
        case .deck: return scope == activeScope ? activeScopeCount : nil
        }
    }
}
