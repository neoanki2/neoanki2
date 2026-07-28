import Foundation

/// An item's scheduling state, rolled up from the cards it generated.
///
/// An item has no due date of its own — each card is scheduled independently —
/// so browsing reports the card the learner will meet first.
public struct ItemScheduleSummary: Sendable, Equatable {
    /// Soonest due date among the item's unsuspended cards. Nil when every card
    /// is suspended, or the item generated none.
    public let dueAt: Date?
    /// Phase of that soonest-due card, so the reported state matches the
    /// reported date.
    public let phase: Phase?
    /// Highest lapse count across the item's unsuspended cards.
    public let lapses: Int

    public init(dueAt: Date?, phase: Phase?, lapses: Int) {
        self.dueAt = dueAt
        self.phase = phase
        self.lapses = lapses
    }

    public func isDue(asOf now: Date = .now) -> Bool {
        guard let dueAt else { return false }
        return dueAt <= now
    }

    /// True when this item is worth rewriting rather than drilling again.
    public var isLeech: Bool { lapses >= ScopeSummary.leechThreshold }
}

/// How a browsed item list is ordered.
///
/// `createdAscending` is the default because authored and generated decks are
/// written in reading order; showing them newest-first renders sequential
/// content backwards.
public enum ItemSortOrder: String, Sendable, CaseIterable {
    case createdAscending
    case createdDescending
    case dueSoonest
    case titleAscending
}
