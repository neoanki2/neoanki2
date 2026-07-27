import Foundation

/// FSRS (Free Spaced Repetition Scheduler), the default and only scheduler.
///
/// Implements the FSRS-6 memory model: each review updates a card's
/// difficulty (D) and stability (S), and the next interval is derived from S
/// for a target retention. Cards store only `MemoryState`, so parameters can
/// later be optimized from `ReviewLog` history without touching the model.
///
/// Learning and relearning repair policy is applied by `LearningScheduler`;
/// this core derives post-recall due dates from stability at sub-day precision.
public struct FSRSScheduler: Scheduler {
    public struct Parameters: Codable, Equatable, Sendable {
        public static let modelVersion = 6
        public static let defaultRequestRetention = 0.9
        public static let defaultMaximumInterval = 36_500
        /// Whole-day floor retained for documentation compatibility. Zero means
        /// FSRS may choose a positive fractional-day interval.
        public static let minimumInterval = 0

        public struct WeightBound: Equatable, Sendable {
            public let lower: Double
            public let upper: Double

            public init(_ lower: Double, _ upper: Double) {
                self.lower = lower
                self.upper = upper
            }
        }

        /// The 21 FSRS-6 weights.
        public var weights: [Double]
        /// Target probability of recall when a card comes due (0 < r < 1).
        public var requestRetention: Double
        /// Hard cap on any interval, in days.
        public var maximumInterval: Int

        public init(
            weights: [Double] = Parameters.defaultWeights,
            requestRetention: Double = Parameters.defaultRequestRetention,
            maximumInterval: Int = Parameters.defaultMaximumInterval,
            enableFuzz: Bool = true
        ) {
            self.weights = Parameters.sanitizedWeights(weights)
            self.requestRetention = requestRetention.isFinite
                ? min(0.99, max(0.7, requestRetention))
                : Parameters.defaultRequestRetention
            self.maximumInterval = min(
                Parameters.defaultMaximumInterval,
                max(1, maximumInterval)
            )
            self.enableFuzz = enableFuzz
        }

        /// Whether review intervals receive deterministic FSRS-style fuzz.
        public var enableFuzz: Bool

        /// Canonical FSRS-6 defaults from open-spaced-repetition.
        public static let defaultWeights: [Double] = [
            0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001,
            1.8722, 0.1666, 0.796, 1.4835, 0.0614, 0.2629, 1.6483, 0.6014,
            1.8729, 0.5425, 0.0912, 0.0658, 0.1542,
        ]

        /// FSRS-6 optimizer domains pinned to ts-fsrs commit
        /// cdec8d2f8340f8e62ced596c1da02e20e70073f0.
        public static let weightBounds: [WeightBound] = [
            .init(0.001, 100), .init(0.001, 100), .init(0.001, 100), .init(0.001, 100),
            .init(1, 10), .init(0.001, 4), .init(0.001, 4), .init(0, 0.75),
            .init(0, 4.5), .init(0, 0.8), .init(0.001, 3.5), .init(0.001, 5),
            .init(0.001, 0.25), .init(0.001, 0.9), .init(0, 4), .init(0, 1),
            .init(1, 6), .init(0, 2), .init(0, 2), .init(0.01, 0.8), .init(0.1, 0.8),
        ]

        public static func sanitizedWeights(_ weights: [Double]) -> [Double] {
            let migrated: [Double]
            switch weights.count {
            case weightBounds.count:
                migrated = weights
            case 19:
                // Official compatibility mapping from ts-fsrs commit
                // 18562c426a4288ff0722b737fd06fe2746a5716f:
                // no last-stability exponent and FSRS-5's fixed decay.
                migrated = weights + [0.0, 0.5]
            default:
                return defaultWeights
            }
            return zip(migrated, weightBounds).enumerated().map { index, pair in
                let (value, bound) = pair
                guard value.isFinite else { return defaultWeights[index] }
                // Zero is the official FSRS-5 compatibility sentinel. Native
                // FSRS-6 optimization still uses the 0.01 lower bound above.
                if index == 19, value == 0 { return 0 }
                return min(bound.upper, max(bound.lower, value))
            }
        }

        private enum CodingKeys: String, CodingKey {
            case weights, requestRetention, maximumInterval, enableFuzz
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                weights: try values.decode([Double].self, forKey: .weights),
                requestRetention: try values.decode(Double.self, forKey: .requestRetention),
                maximumInterval: try values.decode(Int.self, forKey: .maximumInterval),
                enableFuzz: try values.decodeIfPresent(Bool.self, forKey: .enableFuzz) ?? true
            )
        }
    }

    private let params: Parameters
    private let decay: Double
    private let factor: Double
    private let minimumStability = 0.001
    private let minimumIntervalDays = 1.0 / 1_440.0

    public init(parameters: Parameters = Parameters()) {
        self.params = parameters
        self.decay = -parameters.weights[20]
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
            if elapsedDays < 1 {
                stability = sameDayStability(stability: state.stability, rating: rating)
            } else if rating == .again {
                stability = forgetStability(
                    difficulty: state.difficulty,
                    stability: state.stability,
                    retrievability: r
                )
            } else {
                stability = recallStability(
                    difficulty: state.difficulty,
                    stability: state.stability,
                    retrievability: r,
                    rating: rating
                )
            }
        }

        next.difficulty = difficulty
        next.stability = stability.isFinite
            ? min(Double(Parameters.defaultMaximumInterval), max(minimumStability, stability))
            : minimumStability
        next.lastReview = now
        next.reps += 1

        if rating == .again {
            next.phase = .relearning
            if !isFirstReview { next.lapses += 1 }
        } else {
            next.phase = .review
        }

        let interval = scheduledIntervalDays(
            for: next.stability,
            state: state,
            rating: rating,
            now: now
        )
        next.due = now.addingTimeInterval(interval * 86_400.0)
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

    /// The interval in days, preserving fractional days for intraday scheduling.
    public func intervalDays(for stability: Double) -> Double {
        guard stability.isFinite, stability > 0 else { return minimumIntervalDays }
        let ideal = (stability / factor) * (pow(params.requestRetention, 1.0 / decay) - 1.0)
        guard ideal.isFinite else { return minimumIntervalDays }
        return min(Double(params.maximumInterval), max(minimumIntervalDays, ideal))
    }

    /// FSRS forgetting curve probability for an elapsed interval.
    public func retrievability(elapsedDays: Double, stability: Double) -> Double {
        guard elapsedDays.isFinite, stability.isFinite, stability > 0 else { return 0 }
        let value = pow(1.0 + factor * max(0, elapsedDays) / stability, decay)
        return value.isFinite ? min(1, max(0, value)) : 0
    }

    // MARK: - FSRS-6 core

    private func initialStability(_ rating: ReviewRating) -> Double {
        max(0.1, params.weights[rating.rawValue - 1])
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
        let reverted = w[7] * easyInit + (1.0 - w[7]) * damped
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
        let shortTermCap = stability / exp(w[17] * w[18])
        return min(sf, shortTermCap)
    }

    /// FSRS-6 short-term update. w19 reduces the effect as stability grows.
    private func sameDayStability(stability: Double, rating: ReviewRating) -> Double {
        let exponent = params.weights[17]
            * (Double(rating.rawValue) - 3.0 + params.weights[18])
        var increase = pow(stability, -params.weights[19]) * exp(exponent)
        if rating != .again {
            increase = max(1, increase)
        }
        let value = stability * increase
        return value.isFinite ? value : stability
    }

    private func scheduledIntervalDays(
        for stability: Double,
        state: MemoryState,
        rating: ReviewRating,
        now: Date
    ) -> Double {
        let interval = intervalDays(for: stability)
        guard params.enableFuzz, interval >= 2.5, interval < Double(params.maximumInterval) else {
            return interval
        }
        return Double(fuzz(
            interval: Int(interval.rounded()),
            unit: deterministicUnit(state: state, rating: rating, now: now)
        ))
    }

    /// Exposed for parity tests and queue previews that need reproducible fuzz.
    public func fuzz(interval: Int, unit: Double) -> Int {
        guard interval >= 3 else { return max(1, interval) }
        let delta: Int
        switch interval {
        case ..<7:
            delta = max(1, Int((Double(interval) * 0.15).rounded()))
        case ..<30:
            delta = max(2, Int((Double(interval) * 0.10).rounded()))
        default:
            delta = max(4, Int((Double(interval) * 0.05).rounded()))
        }
        let lower = max(1, interval - delta)
        let upper = min(params.maximumInterval, interval + delta)
        let clampedUnit = unit.isFinite ? min(0.999_999_999, max(0, unit)) : 0.5
        return lower + Int((Double(upper - lower + 1) * clampedUnit).rounded(.down))
    }

    private func deterministicUnit(state: MemoryState, rating: ReviewRating, now: Date) -> Double {
        var seed = state.stability.bitPattern
        seed ^= state.difficulty.bitPattern &* 0x9E37_79B9_7F4A_7C15
        seed ^= now.timeIntervalSinceReferenceDate.bitPattern
        seed ^= UInt64(state.reps) &* 0xBF58_476D_1CE4_E5B9
        seed ^= UInt64(rating.rawValue) &* 0x94D0_49BB_1331_11EB
        seed ^= seed >> 30
        seed &*= 0xBF58_476D_1CE4_E5B9
        seed ^= seed >> 27
        seed &*= 0x94D0_49BB_1331_11EB
        seed ^= seed >> 31
        return Double(seed >> 11) / Double(UInt64(1) << 53)
    }

    private func clampDifficulty(_ value: Double) -> Double {
        min(10.0, max(1.0, value))
    }

    private func elapsed(from last: Date?, to now: Date) -> Double {
        guard let last else { return 0 }
        return max(0, now.timeIntervalSince(last) / 86_400.0)
    }
}
