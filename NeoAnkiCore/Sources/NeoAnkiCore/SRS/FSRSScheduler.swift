import Foundation
import NeoAnkiFSRS

/// Application adapter around the pinned native `NeoAnkiFSRS` reference
/// model. FSRS updates memory; NeoAnki converts timestamps and assigns an exact
/// operational due instant. Immediate Again repair belongs exclusively to
/// `LearningScheduler`.
public struct FSRSScheduler: Scheduler {
    public static let memoryModelIdentifier = FSRSReference.modelIdentifier
    public static let elapsedPolicyIdentifier = "neo-continuous-elapsed-v2"
    public static let intervalPolicyIdentifier = "continuous-due-v1"

    public struct Parameters: Codable, Equatable, Sendable {
        public static let modelVersion = 6
        public static let defaultRequestRetention = 0.9
        public static let defaultMaximumInterval = 36_500
        public static let minimumInterval = 0

        public struct WeightBound: Equatable, Sendable {
            public let lower: Double
            public let upper: Double
            public init(_ lower: Double, _ upper: Double) {
                self.lower = lower
                self.upper = upper
            }
        }

        public var weights: [Double]
        public var requestRetention: Double
        public var maximumInterval: Int
        /// Retained only for decoding old settings. Scheduling never fuzzes.
        public var enableFuzz: Bool

        public init(
            weights: [Double] = Parameters.defaultWeights,
            requestRetention: Double = Parameters.defaultRequestRetention,
            maximumInterval: Int = Parameters.defaultMaximumInterval,
            enableFuzz: Bool = false
        ) {
            self.weights = Parameters.sanitizedWeights(weights)
            self.requestRetention = requestRetention.isFinite
                ? min(0.99, max(0.01, requestRetention))
                : Parameters.defaultRequestRetention
            self.maximumInterval = min(Parameters.defaultMaximumInterval, max(1, maximumInterval))
            self.enableFuzz = false
        }

        public static let defaultWeights = NeoAnkiFSRS.Parameters.defaults.map(Double.init)

        public static let weightBounds: [WeightBound] = [
            .init(0.001, 100), .init(0.001, 100), .init(0.001, 100), .init(0.001, 100),
            .init(1, 10), .init(0.001, 4), .init(0.001, 4), .init(0.001, 0.75),
            .init(0, 4.5), .init(0, 0.8), .init(0.001, 3.5), .init(0.001, 5),
            .init(0.001, 0.25), .init(0.001, 0.9), .init(0, 4), .init(0, 1),
            .init(1, 6), .init(0, 2), .init(0, 2), .init(0.01, 0.8), .init(0.1, 0.8),
        ]

        public static func sanitizedWeights(_ weights: [Double]) -> [Double] {
            let floats = weights.map(Float.init)
            guard let parameters = try? NeoAnkiFSRS.Parameters(floats) else { return defaultWeights }
            return parameters.values.map(Double.init)
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
                enableFuzz: false
            )
        }
    }

    private let params: Parameters
    private let engine: NeoAnkiFSRS.FSRS

    public init(parameters: Parameters = Parameters()) {
        params = parameters
        let native = (try? NeoAnkiFSRS.Parameters(parameters.weights.map(Float.init))) ?? .population
        engine = NeoAnkiFSRS.FSRS(parameters: native)
    }

    public func schedule(
        _ state: MemoryState,
        rating: ReviewRating,
        now: Date = .now
    ) -> MemoryState {
        let isFirstReview = state.reps == 0 || state.phase == .new
        let current: NeoAnkiFSRS.MemoryState? = isFirstReview ? nil : .init(
            stability: Float(state.stability),
            difficulty: Float(state.difficulty)
        )
        let elapsed = isFirstReview ? 0 : Self.elapsedModelDays(from: state.lastReview, to: now)
        let nativeRating: NeoAnkiFSRS.Rating = switch rating {
        case .again: .again
        case .hard: .hard
        case .good: .good
        case .easy: .easy
        }
        guard let result = try? engine.nextStates(
            current: current,
            desiredRetention: Float(params.requestRetention),
            daysElapsed: Float(elapsed)
        )[nativeRating] else {
            return state
        }

        var next = state
        next.stability = Double(result.memory.stability)
        next.difficulty = Double(result.memory.difficulty)
        next.lastReview = now
        next.reps += 1
        next.stepIndex = nil
        if rating == .again {
            next.phase = .relearning
            if !isFirstReview { next.lapses += 1 }
        } else {
            next.phase = .review
        }

        let cappedDays = min(Float(params.maximumInterval), max(0, result.interval))
        let seconds = max(1, ceil(Double(cappedDays) * 86_400))
        next.due = now.addingTimeInterval(seconds)
        return next
    }

    public func retrievability(of state: MemoryState, asOf now: Date = .now) -> Double {
        guard state.reps > 0, state.stability > 0 else { return 1 }
        let native = NeoAnkiFSRS.MemoryState(
            stability: Float(state.stability),
            difficulty: Float(state.difficulty)
        )
        return Double(engine.retrievability(
            state: native,
            daysElapsed: Float(Self.elapsedModelDays(from: state.lastReview, to: now))
        ))
    }

    public func intervalDays(for stability: Double) -> Double {
        guard stability.isFinite, stability > 0 else { return 1.0 / 86_400.0 }
        return min(
            Double(params.maximumInterval),
            max(1.0 / 86_400.0, rawIntervalDays(forStability: stability))
        )
    }

    /// The model's raw fractional interval before maximum-interval or
    /// operational one-second policy is applied.
    public func rawIntervalDays(forStability stability: Double) -> Double {
        guard stability.isFinite, stability > 0 else { return 1.0 / 86_400.0 }
        let raw = engine.nextInterval(
            stability: Float(stability),
            desiredRetention: Float(params.requestRetention)
        )
        return raw.isFinite && raw > 0 ? Double(raw) : 1.0 / 86_400.0
    }

    public func retrievability(elapsedDays: Double, stability: Double) -> Double {
        guard elapsedDays.isFinite, stability.isFinite, stability > 0 else { return 0 }
        return Double(engine.retrievability(
            state: .init(stability: Float(stability), difficulty: 1),
            daysElapsed: Float(max(0, elapsedDays))
        ))
    }

    public static func elapsedModelDays(from last: Date?, to now: Date) -> Double {
        guard let last else { return 0 }
        let seconds = max(0, now.timeIntervalSince(last))
        guard seconds.isFinite else { return 0 }
        return seconds / 86_400
    }

    /// Legacy diagnostic helper; the active interval policy never calls it.
    @available(*, deprecated, message: "Fuzz is disabled by continuous-due-v1")
    public func fuzz(interval: Int, unit: Double) -> Int {
        max(1, min(params.maximumInterval, interval))
    }
}
