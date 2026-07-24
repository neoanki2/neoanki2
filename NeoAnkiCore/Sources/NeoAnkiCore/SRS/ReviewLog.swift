import Foundation

/// An append-only record of a single review. Kept for stats and, crucially,
/// to train/optimize the scheduler (e.g. FSRS parameter fitting) later.
public struct ReviewLog: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let cardID: UUID
    public let reviewedAt: Date
    public let rating: ReviewRating
    /// Days since the previous review of this card.
    public let elapsedDays: Double
    /// Days the card had been scheduled for when it was shown.
    public let scheduledDays: Double
    /// The card's phase immediately before this review.
    public let phaseBefore: Phase
    /// How long the learner spent on the card, in milliseconds.
    public let durationMs: Int

    public init(
        id: UUID = UUID(),
        cardID: UUID,
        reviewedAt: Date,
        rating: ReviewRating,
        elapsedDays: Double,
        scheduledDays: Double,
        phaseBefore: Phase,
        durationMs: Int
    ) {
        self.id = id
        self.cardID = cardID
        self.reviewedAt = reviewedAt
        self.rating = rating
        self.elapsedDays = elapsedDays
        self.scheduledDays = scheduledDays
        self.phaseBefore = phaseBefore
        self.durationMs = durationMs
    }
}
