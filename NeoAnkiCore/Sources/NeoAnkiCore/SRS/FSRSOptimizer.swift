import Foundation
import NeoAnkiFSRS

public enum FSRSOptimizationError: Error, Equatable, Sendable, LocalizedError {
    case insufficientData(required: Int, available: Int)
    case invalidParameters
    case optimizerParityNotVerified

    public var errorDescription: String? {
        switch self {
        case let .insufficientData(required, available):
            "At least \(required) usable interday outcomes are needed; \(available) are available."
        case .invalidParameters:
            "The saved scheduling parameters are invalid."
        case .optimizerParityNotVerified:
            "Full FSRS training is disabled until the native optimizer passes the pinned reference fixtures."
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

public struct FSRSOptimizationSchedule: Sendable, Equatable {
    public static let defaultMinimumReviewLogs = FSRSOptimizer.defaultMinimumObservations
    public static let defaultMinimumNewReviewLogs = 200
    public static let defaultGrowthFraction = 0.25
    public static let defaultStaleInterval: TimeInterval = 30 * 86_400

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

    public func needsOptimization(reviewLogCount: Int, lastAttempt: Attempt?, now: Date) -> Bool {
        guard reviewLogCount >= minimumReviewLogs else { return false }
        guard let lastAttempt else { return true }
        let newLogs = reviewLogCount - lastAttempt.reviewLogCount
        guard newLogs > 0 else { return false }
        if now >= lastAttempt.attemptedAt.addingTimeInterval(staleInterval) { return true }
        let proportional = (Double(lastAttempt.reviewLogCount) * growthFraction).rounded(.up)
        return Double(newLogs) >= max(Double(minimumNewReviewLogs), proportional)
    }
}

/// NeoAnkiCore history adapter for the native reference optimizer. Intraday
/// answers remain in each card sequence; only interday reviews become targets.
public struct FSRSOptimizer: Sendable {
    public static let defaultMinimumObservations = 400
    public static let minimumReviewsPerCardForOutcome = 2

    public let minimumObservations: Int
    /// Retained as a source-compatible alias for the pinned five epochs.
    public let passes: Int
    public let regularization: Double

    public init(
        minimumObservations: Int = Self.defaultMinimumObservations,
        passes: Int = 5,
        regularization: Double = 1
    ) {
        self.minimumObservations = max(1, minimumObservations)
        self.passes = 5
        self.regularization = 1
    }

    public func optimize(
        logs: [ReviewLog],
        startingAt parameters: FSRSScheduler.Parameters = .init()
    ) throws -> FSRSOptimizationResult {
        let examples = Self.examples(from: logs)
        guard examples.count >= minimumObservations else {
            throw FSRSOptimizationError.insufficientData(
                required: minimumObservations,
                available: examples.count
            )
        }
        let baseline = try evaluation(examples: examples, parameters: parameters)
        guard baseline.isFinite else { throw FSRSOptimizationError.invalidParameters }
        let optimized: NeoAnkiFSRS.OptimizationResult
        do {
            optimized = try NeoAnkiFSRS.Optimizer().computeParameters(examples: examples)
        } catch NeoAnkiFSRS.FSRSError.notEnoughData {
            throw FSRSOptimizationError.insufficientData(
                required: minimumObservations,
                available: examples.count
            )
        } catch {
            throw FSRSOptimizationError.invalidParameters
        }
        let candidateLoss = optimized.evaluation.logLoss
        let improved = candidateLoss.isFinite && candidateLoss + 1e-7 < baseline
        return FSRSOptimizationResult(
            parameters: improved ? FSRSScheduler.Parameters(
                weights: optimized.parameters.values.map(Double.init),
                requestRetention: parameters.requestRetention,
                maximumInterval: parameters.maximumInterval,
                enableFuzz: false
            ) : parameters,
            previousLoss: baseline,
            optimizedLoss: improved ? candidateLoss : baseline,
            observationCount: examples.count,
            improved: improved
        )
    }

    public func logLoss(
        logs: [ReviewLog],
        parameters: FSRSScheduler.Parameters = .init()
    ) -> Double {
        (try? evaluation(examples: Self.examples(from: logs), parameters: parameters)) ?? .infinity
    }

    private func evaluation(
        examples: [TrainingExample],
        parameters: FSRSScheduler.Parameters
    ) throws -> Double {
        let native = try NeoAnkiFSRS.Parameters(parameters.weights.map(Float.init))
        return try NeoAnkiFSRS.FSRS(parameters: native).evaluate(examples).logLoss
    }

    private static func examples(from logs: [ReviewLog]) -> [TrainingExample] {
        let indexed = logs.enumerated().filter { index, log in
            log.reviewedAt.timeIntervalSinceReferenceDate.isFinite
                && log.durationMs >= 0
                && log.elapsedDays.isFinite
                && log.scheduledDays.isFinite
        }
        let grouped = Dictionary(grouping: indexed, by: \.element.cardID)
        return grouped.keys.sorted { $0.uuidString < $1.uuidString }.flatMap { cardID -> [TrainingExample] in
            let history = grouped[cardID]!.sorted { lhs, rhs in
                if lhs.element.reviewedAt != rhs.element.reviewedAt {
                    return lhs.element.reviewedAt < rhs.element.reviewedAt
                }
                switch (lhs.element.sequence, rhs.element.sequence) {
                case let (left?, right?) where left != right: return left < right
                default: return lhs.offset < rhs.offset
                }
            }.map(\.element)
            guard history.count >= minimumReviewsPerCardForOutcome,
                  history.first?.phaseBefore == .new
            else { return [] }
            var previous: Date?
            var targetOrders: [Int64] = []
            let reviews = history.map { log -> NeoAnkiFSRS.Review in
                let days = FSRSScheduler.elapsedModelDays(from: previous, to: log.reviewedAt)
                previous = log.reviewedAt
                if days > 0 {
                    targetOrders.append(log.sequence ?? Int64(
                        (log.reviewedAt.timeIntervalSinceReferenceDate * 1_000_000).rounded()
                    ))
                }
                return NeoAnkiFSRS.Review(
                    rating: .init(rawValue: UInt32(log.rating.rawValue))!,
                    deltaT: days
                )
            }
            return zip(
                DatasetBuilder.examples(cardID: cardID.uuidString, history: reviews),
                targetOrders
            ).map { example, order in
                TrainingExample(cardID: example.cardID, item: example.item, order: order)
            }
        }
    }
}
