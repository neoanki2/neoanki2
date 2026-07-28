import Foundation

public enum FSRSOptimizationError: Error, Equatable, Sendable, LocalizedError {
    case insufficientData(required: Int, available: Int)
    case invalidParameters

    public var errorDescription: String? {
        switch self {
        case let .insufficientData(required, available):
            return "At least \(required) usable review outcomes are needed; \(available) are available."
        case .invalidParameters:
            return "The saved scheduling parameters are invalid."
        }
    }
}

public struct FSRSOptimizationResult: Equatable, Sendable {
    public let parameters: FSRSScheduler.Parameters
    public let previousLoss: Double
    public let optimizedLoss: Double
    public let observationCount: Int
    public let improved: Bool

    public init(
        parameters: FSRSScheduler.Parameters,
        previousLoss: Double,
        optimizedLoss: Double,
        observationCount: Int,
        improved: Bool
    ) {
        self.parameters = parameters
        self.previousLoss = previousLoss
        self.optimizedLoss = optimizedLoss
        self.observationCount = observationCount
        self.improved = improved
    }
}

/// Decides when accumulated review history is worth refitting weights against.
///
/// Fitting is automatic, so the decision runs on every session end and has to
/// be cheap and stable. It compares the number of active review logs against
/// the number present at the last attempt — one `COUNT` — rather than replaying
/// history to count usable outcomes, which is the fit itself.
public struct FSRSOptimizationSchedule: Sendable, Equatable {
    /// A fit cannot use more outcomes than there are logs, so this is the
    /// cheapest sound gate before the first attempt.
    public static let defaultMinimumReviewLogs = FSRSOptimizer.defaultMinimumObservations
    public static let defaultMinimumNewReviewLogs = 50
    public static let defaultGrowthFraction = 0.25
    public static let defaultStaleInterval: TimeInterval = 30 * 86_400

    /// What the last attempt saw. Recorded whether or not it changed anything,
    /// so an attempt that finds too little usable history does not repeat on
    /// every session end.
    public struct Attempt: Sendable, Equatable {
        public let reviewLogCount: Int
        public let attemptedAt: Date

        public init(reviewLogCount: Int, attemptedAt: Date) {
            self.reviewLogCount = reviewLogCount
            self.attemptedAt = attemptedAt
        }
    }

    public let minimumReviewLogs: Int
    public let minimumNewReviewLogs: Int
    public let growthFraction: Double
    public let staleInterval: TimeInterval

    public init(
        minimumReviewLogs: Int = Self.defaultMinimumReviewLogs,
        minimumNewReviewLogs: Int = Self.defaultMinimumNewReviewLogs,
        growthFraction: Double = Self.defaultGrowthFraction,
        staleInterval: TimeInterval = Self.defaultStaleInterval
    ) {
        self.minimumReviewLogs = max(1, minimumReviewLogs)
        self.minimumNewReviewLogs = max(1, minimumNewReviewLogs)
        self.growthFraction = max(0, growthFraction)
        self.staleInterval = max(0, staleInterval)
    }

    public func needsOptimization(
        reviewLogCount: Int,
        lastAttempt: Attempt?,
        now: Date
    ) -> Bool {
        guard reviewLogCount >= minimumReviewLogs else { return false }
        guard let lastAttempt else { return true }

        // Refitting against history the last attempt already saw cannot reach a
        // different answer, however old that attempt is.
        let newReviewLogs = reviewLogCount - lastAttempt.reviewLogCount
        guard newReviewLogs > 0 else { return false }

        if now >= lastAttempt.attemptedAt.addingTimeInterval(staleInterval) { return true }

        // Proportional, so a long history is not refitted for a handful of new
        // reviews that cannot move the weights.
        let proportional = (Double(lastAttempt.reviewLogCount) * growthFraction).rounded(.up)
        let required = max(Double(minimumNewReviewLogs), proportional)
        return Double(newReviewLogs) >= required
    }
}

/// Fits per-profile FSRS-6 weights from append-only review history.
///
/// The optimizer is deliberately deterministic and dependency-free. It uses
/// bounded coordinate search against binary recall log loss, with a small
/// regularizer that prevents sparse histories from driving weights to bounds.
public struct FSRSOptimizer: Sendable {
    public static let defaultMinimumObservations = 100
    public static let minimumReviewsPerCardForOutcome = 2

    public let minimumObservations: Int
    public let passes: Int
    public let regularization: Double

    public init(
        minimumObservations: Int = Self.defaultMinimumObservations,
        passes: Int = 5,
        regularization: Double = 0.002
    ) {
        self.minimumObservations = max(1, minimumObservations)
        self.passes = max(1, passes)
        self.regularization = max(0, regularization)
    }

    public func optimize(
        logs: [ReviewLog],
        startingAt parameters: FSRSScheduler.Parameters = .init()
    ) throws -> FSRSOptimizationResult {
        let histories = Self.usableHistories(from: logs)
        let observationCount = Self.observationCount(in: histories)
        guard observationCount >= minimumObservations else {
            throw FSRSOptimizationError.insufficientData(
                required: minimumObservations,
                available: observationCount
            )
        }

        let baselineWeights = FSRSScheduler.Parameters.sanitizedWeights(parameters.weights)
        let optimizationBaseline = zip(
            baselineWeights,
            FSRSScheduler.Parameters.weightBounds
        ).map { value, bound in
            min(bound.upper, max(bound.lower, value))
        }
        var candidate = optimizationBaseline
        let previousLoss = Self.logLoss(histories: histories, weights: baselineWeights)
        guard previousLoss.isFinite else { throw FSRSOptimizationError.invalidParameters }

        func objective(_ weights: [Double]) -> Double {
            let loss = Self.logLoss(histories: histories, weights: weights)
            guard loss.isFinite else { return .infinity }
            let penalty = zip(weights, optimizationBaseline).enumerated().reduce(0.0) { partial, element in
                let (index, values) = element
                let width = FSRSScheduler.Parameters.weightBounds[index].upper
                    - FSRSScheduler.Parameters.weightBounds[index].lower
                let normalized = (values.0 - values.1) / max(width, 1e-9)
                return partial + normalized * normalized
            }
            return loss + regularization * penalty
        }

        var bestObjective = objective(candidate)
        var stepScale = 0.08
        for _ in 0..<passes {
            var changed = false
            for index in candidate.indices {
                let bound = FSRSScheduler.Parameters.weightBounds[index]
                let step = max((bound.upper - bound.lower) * stepScale, 0.000_1)
                var bestValue = candidate[index]

                for proposed in [
                    min(bound.upper, candidate[index] + step),
                    max(bound.lower, candidate[index] - step),
                ] where proposed != candidate[index] {
                    var trial = candidate
                    trial[index] = proposed
                    let trialObjective = objective(trial)
                    if trialObjective + 1e-12 < bestObjective {
                        bestObjective = trialObjective
                        bestValue = proposed
                    }
                }

                if bestValue != candidate[index] {
                    candidate[index] = bestValue
                    changed = true
                }
            }
            stepScale *= changed ? 0.65 : 0.5
        }

        let optimizedLoss = Self.logLoss(histories: histories, weights: candidate)
        let improved = optimizedLoss.isFinite && optimizedLoss + 1e-7 < previousLoss
        let finalWeights = improved ? candidate : baselineWeights
        let finalParameters = FSRSScheduler.Parameters(
            weights: finalWeights,
            requestRetention: parameters.requestRetention,
            maximumInterval: parameters.maximumInterval,
            enableFuzz: parameters.enableFuzz
        )
        return FSRSOptimizationResult(
            parameters: finalParameters,
            previousLoss: previousLoss,
            optimizedLoss: improved ? optimizedLoss : previousLoss,
            observationCount: observationCount,
            improved: improved
        )
    }

    public func logLoss(
        logs: [ReviewLog],
        parameters: FSRSScheduler.Parameters = .init()
    ) -> Double {
        Self.logLoss(
            histories: Self.usableHistories(from: logs),
            weights: parameters.weights
        )
    }

    private static func usableHistories(from logs: [ReviewLog]) -> [[ReviewLog]] {
        let valid = logs.enumerated().filter {
            $0.element.reviewedAt.timeIntervalSinceReferenceDate.isFinite
                && $0.element.elapsedDays.isFinite
                && $0.element.elapsedDays >= 0
                && $0.element.scheduledDays.isFinite
                && $0.element.scheduledDays >= 0
                && $0.element.durationMs >= 0
        }
        return Dictionary(grouping: valid, by: \.element.cardID)
            .values
            .map {
                $0.sorted {
                    if $0.element.reviewedAt == $1.element.reviewedAt {
                        switch ($0.element.sequence, $1.element.sequence) {
                        case let (lhs?, rhs?) where lhs != rhs:
                            return lhs < rhs
                        default:
                            return $0.offset < $1.offset
                        }
                    }
                    return $0.element.reviewedAt < $1.element.reviewedAt
                }
                .map(\.element)
            }
            .filter { $0.count >= Self.minimumReviewsPerCardForOutcome }
            // A persisted MemoryState snapshot is not part of ReviewLog. Without
            // the card's first review, replaying a mature partial history from
            // `.new` would fit against fabricated stability and difficulty.
            .filter { $0.first?.phaseBefore == .new }
            .sorted { lhs, rhs in
                (lhs.first?.cardID.uuidString ?? "") < (rhs.first?.cardID.uuidString ?? "")
            }
    }

    private static func observationCount(in histories: [[ReviewLog]]) -> Int {
        histories.reduce(0) { $0 + max(0, $1.count - 1) }
    }

    private static func logLoss(histories: [[ReviewLog]], weights: [Double]) -> Double {
        guard weights.count == FSRSScheduler.Parameters.weightBounds.count else {
            return .infinity
        }
        let parameters = FSRSScheduler.Parameters(weights: weights, enableFuzz: false)
        let scheduler = FSRSScheduler(parameters: parameters)
        var total = 0.0
        var count = 0

        for history in histories {
            guard let first = history.first else { continue }
            var state = MemoryState.new(due: first.reviewedAt)
            for (index, log) in history.enumerated() {
                if index > 0 {
                    let probability = min(
                        1 - 1e-6,
                        max(1e-6, scheduler.retrievability(
                            elapsedDays: log.elapsedDays,
                            stability: state.stability
                        ))
                    )
                    let recalled = log.rating != .again
                    total -= recalled ? Foundation.log(probability) : Foundation.log(1 - probability)
                    count += 1
                }
                state = scheduler.schedule(state, rating: log.rating, now: log.reviewedAt)
                guard state.stability.isFinite, state.difficulty.isFinite else {
                    return .infinity
                }
            }
        }

        return count > 0 ? total / Double(count) : .infinity
    }
}
