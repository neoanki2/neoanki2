import Foundation

/// A resolved deck filter for aggregate queries. `DeckScope` describes what the
/// caller asked for; this describes the deck identifiers that request became
/// once descendants were expanded.
enum CardScope: Sendable, Equatable {
    case all
    case unassigned
    case decks(Set<UUID>)
}

/// One item's cards, folded down to what a list row needs.
struct ItemCardState: Sendable, Equatable {
    var cardCount: Int = 0
    var dueAt: Date?
    var phase: Phase?
    var lapses: Int = 0

    var scheduleSummary: ItemScheduleSummary {
        ItemScheduleSummary(dueAt: dueAt, phase: phase, lapses: lapses)
    }
}

/// Raw card aggregates for one scope, read in a single pass.
struct CardScheduleTotals: Sendable, Equatable {
    var cardCount: Int = 0
    var dueNow: Int = 0
    var newCount: Int = 0
    var availableNewCount: Int = 0
    var hiddenNewCount: Int = 0
    var learningCount: Int = 0
    var relearningCount: Int = 0
    var reviewCount: Int = 0
    var leechCount: Int = 0
    var nextDueAt: Date?
}
