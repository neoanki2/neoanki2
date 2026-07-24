import Foundation

/// FSRS (Free Spaced Repetition Scheduler), the default and only scheduler.
///
/// Implements the FSRS-5 memory model: each review updates a card's
/// difficulty (D) and stability (S), and the next interval is derived from S
/// for a target retention. Cards store only `MemoryState`, so parameters can
/// later be optimized from `ReviewLog` history without touching the model.
///
/// Note: learning/relearning step policy (e.g. "see again in 10 minutes") is a
/// scheduling layer that can sit on top of this; the core derives intervals
/// purely from stability, floored at one day.
public struct FSRSScheduler: Scheduler {
    public struct Parameters: Codable, Equatable, Sendable {
        /// The 19 FSRS-5 weights.
        public var weights: [Double]
        /// Target probability of recall when a card comes due (0 < r < 1).
        public var requestRetention: Double
        /// Hard cap on any interval, in days.
        public var maximumInterval: Int

        public init(
            weights: [Double] = Parameters.defaultWeights,
            requestRetention: Double = 0.9,
            maximumInterval: Int = 36_500
        ) {
            self.weights = weights
            self.requestRetention = requestRetention
            self.maximumInterval = maximumInterval
        }

        /// FSRS-5 default weights, used until per-user optimization runs.
        public static let defaultWeights: [Double] = [
            0.40255, 1.18385, 3.173, 15.69105, 7.1949, 0.5345, 1.4604, 0.0046,
            1.54575, 0.1192, 1.01925, 1.9395, 0.11, 0.29605, 2.2698, 0.2315,
            2.9898, 0.51655, 0.6621,
        ]
    }

    private let params: Parameters
    private let decay = -0.5
    private let factor: Double
    private let minimumStability = 0.1

    public init(parameters: Parameters = Parameters()) {
        self.params = parameters
        self.factor = pow(0.9, 1.0 / decay) - 1.0
    }

    // MARK: - Scheduler

    public func schedule(
        _ state: MemoryState,
        rating: ReviewRating,
        now: Date = .now
    ) -> MemoryState {
        var next = state
        let isFirstReview = state.reps == 0 || state.phase == .new

        let stability: Double
        let difficulty: Double

        if isFirstReview {
            difficulty = initialDifficulty(rating)
            stability = initialStability(rating)
        } else {
            let elapsedDays = elapsed(from: state.lastReview, to: now)
            let r = retrievability(elapsedDays: elapsedDays, stability: state.stability)
            difficulty = nextDifficulty(state.difficulty, rating: rating)
            stability = rating == .again
                ? forgetStability(difficulty: difficulty, stability: state.stability, retrievability: r)
                : recallStability(
                    difficulty: difficulty,
                    stability: state.stability,
                    retrievability: r,
                    rating: rating
                )
        }

        next.difficulty = difficulty
        next.stability = max(minimumStability, stability)
        next.lastReview = now
        next.reps += 1

        if rating == .again {
            next.phase = .relearning
            if !isFirstReview { next.lapses += 1 }
        } else {
            next.phase = .review
        }

        let interval = intervalDays(for: next.stability)
        next.due = now.addingTimeInterval(Double(interval) * 86_400.0)
        return next
    }

    // MARK: - Public helpers

    /// Predicted probability of recall right now, useful for UI and queue
    /// ordering. Returns 1 for cards that have never been reviewed.
    public func retrievability(of state: MemoryState, asOf now: Date = .now) -> Double {
        guard state.reps > 0, state.stability > 0 else { return 1 }
        return retrievability(
            elapsedDays: elapsed(from: state.lastReview, to: now),
            stability: state.stability
        )
    }

    /// The interval, in days, this state would receive at the target retention.
    public func intervalDays(for stability: Double) -> Int {
        let ideal = (stability / factor) * (pow(params.requestRetention, 1.0 / decay) - 1.0)
        return min(params.maximumInterval, max(1, Int(ideal.rounded())))
    }

    // MARK: - FSRS-5 core

    private func retrievability(elapsedDays: Double, stability: Double) -> Double {
        pow(1.0 + factor * elapsedDays / stability, decay)
    }

    private func initialStability(_ rating: ReviewRating) -> Double {
        max(minimumStability, params.weights[rating.rawValue - 1])
    }

    private func initialDifficulty(_ rating: ReviewRating) -> Double {
        let w = params.weights
        let d = w[4] - exp(w[5] * Double(rating.rawValue - 1)) + 1.0
        return clampDifficulty(d)
    }

    private func nextDifficulty(_ difficulty: Double, rating: ReviewRating) -> Double {
        let w = params.weights
        let deltaD = -w[6] * Double(rating.rawValue - 3)
        let damped = difficulty + deltaD * (10.0 - difficulty) / 9.0
        let easyInit = w[4] - exp(w[5] * 3.0) + 1.0
        let reverted = w[7] * clampDifficulty(easyInit) + (1.0 - w[7]) * damped
        return clampDifficulty(reverted)
    }

    private func recallStability(
        difficulty: Double,
        stability: Double,
        retrievability r: Double,
        rating: ReviewRating
    ) -> Double {
        let w = params.weights
        let hardPenalty = rating == .hard ? w[15] : 1.0
        let easyBonus = rating == .easy ? w[16] : 1.0
        let growth = exp(w[8])
            * (11.0 - difficulty)
            * pow(stability, -w[9])
            * (exp(w[10] * (1.0 - r)) - 1.0)
            * hardPenalty
            * easyBonus
        return stability * (1.0 + growth)
    }

    private func forgetStability(
        difficulty: Double,
        stability: Double,
        retrievability r: Double
    ) -> Double {
        let w = params.weights
        let sf = w[11]
            * pow(difficulty, -w[12])
            * (pow(stability + 1.0, w[13]) - 1.0)
            * exp(w[14] * (1.0 - r))
        // Post-lapse stability should not exceed the pre-lapse value.
        return min(sf, stability)
    }

    private func clampDifficulty(_ value: Double) -> Double {
        min(10.0, max(1.0, value))
    }

    private func elapsed(from last: Date?, to now: Date) -> Double {
        guard let last else { return 0 }
        return max(0, now.timeIntervalSince(last) / 86_400.0)
    }
}
