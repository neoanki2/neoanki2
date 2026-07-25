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

/// Fits per-profile FSRS-5 weights from append-only review history.
///
/// The optimizer is deliberately deterministic and dependency-free. It uses
/// bounded coordinate search against binary recall log loss, with a small
/// regularizer that prevents sparse histories from driving weights to bounds.
public struct FSRSOptimizer: Sendable {
    public let minimumObservations: Int
    public let passes: Int
    public let regularization: Double

    public init(
        minimumObservations: Int = 100,
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
        var candidate = baselineWeights
        let previousLoss = Self.logLoss(histories: histories, weights: baselineWeights)
        guard previousLoss.isFinite else { throw FSRSOptimizationError.invalidParameters }

        func objective(_ weights: [Double]) -> Double {
            let loss = Self.logLoss(histories: histories, weights: weights)
            guard loss.isFinite else { return .infinity }
            let penalty = zip(weights, baselineWeights).enumerated().reduce(0.0) { partial, element in
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
            .filter { $0.count >= 2 }
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
