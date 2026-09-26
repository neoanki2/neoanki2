import Foundation

/// A learner-facing account of demonstrated recall, separate from scheduling phase.
public enum CardMaturityStatus: String, Codable, Sendable, Equatable {
    case notStarted
    case learning
    case maintaining
    case inactive

    public static let minimumSpacedRecallDays = 7.0
    public static let maintainingStabilityDays = 30.0

    public static func evaluate(card: Card, reviews: [ReviewLog]) -> Self {
        var evidence = CardMaturityEvidence()
        for review in reviews.sorted(by: { left, right in
            if left.reviewedAt != right.reviewedAt { return left.reviewedAt < right.reviewedAt }
            return (left.sequence ?? 0) < (right.sequence ?? 0)
        }) where review.cardID == card.id {
            evidence.observe(review)
        }
        return evaluate(card: card, evidence: evidence)
    }

    static func evaluate(card: Card, evidence: CardMaturityEvidence) -> Self {
        if card.isSuspended { return .inactive }
        if card.memory.phase == .new || card.memory.reps == 0 { return .notStarted }
        guard card.memory.phase == .review,
              card.memory.stability.isFinite,
              card.memory.stability >= maintainingStabilityDays,
              evidence.spacedSuccesses >= 2 else {
            return .learning
        }
        return .maintaining
    }
}

struct CardMaturityEvidence: Sendable {
    private(set) var spacedSuccesses = 0
    private var previousReviewAt: Date?

    mutating func observe(_ review: ReviewLog) {
        let gap = previousReviewAt.map { review.reviewedAt.timeIntervalSince($0) / 86_400 }
        switch review.rating {
        case .again:
            spacedSuccesses = 0
        case .good, .easy:
            if let gap, gap.isFinite,
               gap >= CardMaturityStatus.minimumSpacedRecallDays {
                spacedSuccesses = min(2, spacedSuccesses + 1)
            }
        case .hard:
            break
        }
        previousReviewAt = review.reviewedAt
    }
}

public struct CardMaturityDetail: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let templateID: UUID
    public let clozeGroup: Int?
    public let status: CardMaturityStatus

    public init(id: UUID, templateID: UUID, clozeGroup: Int?, status: CardMaturityStatus) {
        self.id = id
        self.templateID = templateID
        self.clozeGroup = clozeGroup
        self.status = status
    }
}

public struct MaturitySummary: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case noActiveCards
        case notStarted
        case learning
        case maintaining
    }

    public let activeCardCount: Int
    public let maintainingCardCount: Int
    public let notStartedCardCount: Int

    public init(activeCardCount: Int = 0, maintainingCardCount: Int = 0, notStartedCardCount: Int = 0) {
        self.activeCardCount = activeCardCount
        self.maintainingCardCount = maintainingCardCount
        self.notStartedCardCount = notStartedCardCount
    }

    public static let empty = MaturitySummary()

    public var status: Status {
        if activeCardCount == 0 { return .noActiveCards }
        if maintainingCardCount == activeCardCount { return .maintaining }
        if notStartedCardCount == activeCardCount { return .notStarted }
        return .learning
    }

    public func adding(_ other: MaturitySummary) -> MaturitySummary {
        MaturitySummary(
            activeCardCount: activeCardCount + other.activeCardCount,
            maintainingCardCount: maintainingCardCount + other.maintainingCardCount,
            notStartedCardCount: notStartedCardCount + other.notStartedCardCount
        )
    }

    static func one(_ status: CardMaturityStatus) -> MaturitySummary {
        switch status {
        case .inactive: .empty
        case .notStarted: MaturitySummary(activeCardCount: 1, notStartedCardCount: 1)
        case .learning: MaturitySummary(activeCardCount: 1)
        case .maintaining: MaturitySummary(activeCardCount: 1, maintainingCardCount: 1)
        }
    }
}
