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
    /// Durable append order assigned by persistence. In-memory/test logs may
    /// omit it, in which case their input order is preserved for timestamp ties.
    public let sequence: Int64?
    /// Full scheduling provenance. Absent on records written before the
    /// versioned scheduler audit format was introduced.
    public let schedulingAudit: ReviewSchedulingAudit?
    public let vocabularyPrompt: String?

    public init(
        id: UUID = UUID(),
        cardID: UUID,
        reviewedAt: Date,
        rating: ReviewRating,
        elapsedDays: Double,
        scheduledDays: Double,
        phaseBefore: Phase,
        durationMs: Int,
        sequence: Int64? = nil,
        schedulingAudit: ReviewSchedulingAudit? = nil,
        vocabularyPrompt: String? = nil
    ) {
        self.id = id
        self.cardID = cardID
        self.reviewedAt = reviewedAt
        self.rating = rating
        self.elapsedDays = elapsedDays
        self.scheduledDays = scheduledDays
        self.phaseBefore = phaseBefore
        self.durationMs = durationMs
        self.sequence = sequence
        self.schedulingAudit = schedulingAudit
        self.vocabularyPrompt = vocabularyPrompt
    }

    func withSequence(_ sequence: Int64) -> ReviewLog {
        withVocabularyPrompt(vocabularyPrompt, sequence: sequence)
    }

    func withVocabularyPrompt(_ prompt: String?, sequence: Int64? = nil) -> ReviewLog {
        ReviewLog(
            id: id,
            cardID: cardID,
            reviewedAt: reviewedAt,
            rating: rating,
            elapsedDays: elapsedDays,
            scheduledDays: scheduledDays,
            phaseBefore: phaseBefore,
            durationMs: durationMs,
            sequence: sequence ?? self.sequence,
            schedulingAudit: schedulingAudit,
            vocabularyPrompt: prompt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, cardID, reviewedAt, rating, elapsedDays, scheduledDays
        case phaseBefore, durationMs, sequence, schedulingAudit, vocabularyPrompt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            cardID: try values.decode(UUID.self, forKey: .cardID),
            reviewedAt: try values.decode(Date.self, forKey: .reviewedAt),
            rating: try values.decode(ReviewRating.self, forKey: .rating),
            elapsedDays: try values.decode(Double.self, forKey: .elapsedDays),
            scheduledDays: try values.decode(Double.self, forKey: .scheduledDays),
            phaseBefore: try values.decode(Phase.self, forKey: .phaseBefore),
            durationMs: try values.decode(Int.self, forKey: .durationMs),
            sequence: try values.decodeIfPresent(Int64.self, forKey: .sequence),
            schedulingAudit: try values.decodeIfPresent(
                ReviewSchedulingAudit.self,
                forKey: .schedulingAudit
            ),
            vocabularyPrompt: try values.decodeIfPresent(String.self, forKey: .vocabularyPrompt)
        )
    }
}
