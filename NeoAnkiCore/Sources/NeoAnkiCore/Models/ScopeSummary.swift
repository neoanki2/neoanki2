import Foundation

/// What one sidebar scope contains and what it owes the learner right now.
///
/// This is the pre-session view of scheduling: it answers "is there anything to
/// study, and if not, when" without loading any card content. Study itself never
/// shows these numbers.
public struct ScopeSummary: Sendable, Equatable {
    /// Items assigned within the scope, including descendant decks when the
    /// scope was resolved with them.
    public let itemCount: Int
    /// Every generated card in the scope, suspended ones included.
    public let cardCount: Int
    /// Cards whose due date has arrived and that are not suspended.
    public let dueNow: Int
    public let newCount: Int
    /// Due new cards that remain inside today's per-deck budgets.
    public let availableNewCount: Int
    /// Due new cards deferred until the next study day.
    public let hiddenNewCount: Int
    public let learningCount: Int
    public let relearningCount: Int
    public let reviewCount: Int
    /// Cards lapsed at least `leechThreshold` times — the ones worth rewriting
    /// rather than drilling.
    public let leechCount: Int
    /// The earliest due date strictly after the reference time, when one exists.
    /// Nil means nothing is scheduled ahead: either the scope is empty or every
    /// card is already due.
    public let nextDueAt: Date?
    public let nextNewCardsAt: Date?

    /// Lapse count at which a card is reported as a leech.
    public static let leechThreshold = 8

    public init(
        itemCount: Int,
        cardCount: Int,
        dueNow: Int,
        newCount: Int,
        availableNewCount: Int = 0,
        hiddenNewCount: Int = 0,
        learningCount: Int,
        relearningCount: Int,
        reviewCount: Int,
        leechCount: Int,
        nextDueAt: Date?,
        nextNewCardsAt: Date? = nil
    ) {
        self.itemCount = itemCount
        self.cardCount = cardCount
        self.dueNow = dueNow
        self.newCount = newCount
        self.availableNewCount = availableNewCount
        self.hiddenNewCount = hiddenNewCount
        self.learningCount = learningCount
        self.relearningCount = relearningCount
        self.reviewCount = reviewCount
        self.leechCount = leechCount
        self.nextDueAt = nextDueAt
        self.nextNewCardsAt = nextNewCardsAt
    }

    public static let empty = ScopeSummary(
        itemCount: 0,
        cardCount: 0,
        dueNow: 0,
        newCount: 0,
        learningCount: 0,
        relearningCount: 0,
        reviewCount: 0,
        leechCount: 0,
        nextDueAt: nil
    )

    /// Relearning is a repair round of learning, so the two read as one bucket
    /// in a three-way breakdown.
    public var inLearningCount: Int { learningCount + relearningCount }

    public var hasItems: Bool { itemCount > 0 }
    public var hasDueCards: Bool { dueNow > 0 }

    public var nextStudyAt: Date? {
        switch (nextDueAt, nextNewCardsAt) {
        case let (scheduled?, newCards?): min(scheduled, newCards)
        case let (scheduled?, nil): scheduled
        case let (nil, newCards?): newCards
        case (nil, nil): nil
        }
    }
}
