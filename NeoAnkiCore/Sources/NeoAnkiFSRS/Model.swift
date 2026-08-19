import Foundation

public enum FSRSError: Error, Equatable, Sendable {
    case invalidInput
    case invalidParameters
    case notEnoughData
}

public enum Rating: UInt32, Codable, CaseIterable, Sendable {
    case again = 1
    case hard = 2
    case good = 3
    case easy = 4
}

public struct MemoryState: Codable, Equatable, Sendable {
    public var stability: Float
    public var difficulty: Float

    public init(stability: Float, difficulty: Float) {
        self.stability = stability
        self.difficulty = difficulty
    }
}

public struct ItemState: Equatable, Sendable {
    public let memory: MemoryState
    /// Raw, fractional FSRS interval in days.
    public let interval: Float
}

public struct NextStates: Equatable, Sendable {
    public let again: ItemState
    public let hard: ItemState
    public let good: ItemState
    public let easy: ItemState

    public subscript(_ rating: Rating) -> ItemState {
        switch rating {
        case .again: again
        case .hard: hard
        case .good: good
        case .easy: easy
        }
    }
}

public struct Review: Codable, Equatable, Sendable {
    public let rating: Rating
    /// Exact elapsed days. The first review must use zero.
    public let deltaT: Float

    public init(rating: Rating, deltaT: Float) {
        self.rating = rating
        self.deltaT = deltaT
    }
}

public struct Item: Codable, Equatable, Sendable {
    public let reviews: [Review]

    public init(reviews: [Review]) {
        self.reviews = reviews
    }

    public var longTermReviewCount: Int { reviews.count { $0.deltaT > 0 } }
}

public struct Parameters: Codable, Equatable, Sendable {
    public static let count = 21
    public static let defaults: [Float] = [
        0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194,
        0.001, 1.8722, 0.1666, 0.796, 1.4835, 0.0614, 0.2629,
        1.6483, 0.6014, 1.8729, 0.5425, 0.0912, 0.0658, 0.1542,
    ]

    public let values: [Float]

    public init(_ values: [Float] = []) throws {
        let filled: [Float]
        switch values.count {
        case 0:
            filled = Self.defaults
        case 17:
            var migrated = values
            migrated[4] = migrated[5].addingProduct(2, migrated[4])
            migrated[5] = log(migrated[5].addingProduct(3, 1)) / 3
            migrated[6] += 0.5
            migrated.append(contentsOf: [0, 0, 0, 0.5])
            filled = migrated
        case 19:
            filled = values + [0, 0.5]
        case Self.count:
            filled = values
        default:
            throw FSRSError.invalidParameters
        }
        guard filled.allSatisfy(\.isFinite) else { throw FSRSError.invalidParameters }
        self.values = ParameterClipper.clip(filled)
    }

    public static var population: Parameters { try! Parameters() }
}

public enum ParameterClipper {
    public static let stabilityMinimum: Float = 0.001
    public static let stabilityMaximum: Float = 36_500
    public static let initialStabilityMaximum: Float = 100
    public static let difficultyMinimum: Float = 1
    public static let difficultyMaximum: Float = 10

    public static func clip(
        _ input: [Float],
        relearningSteps: Int = 1,
        shortTermEnabled: Bool = true
    ) -> [Float] {
        guard input.count == Parameters.count else { return Parameters.defaults }
        var result = input
        let ceiling: Float
        if relearningSteps > 1 {
            let coupled = -(log(result[11]) + log(pow(2, result[13]) - 1) + result[14] * 0.3)
                / Float(relearningSteps)
            ceiling = min(2, sqrt(max(0.01, coupled)))
        } else {
            ceiling = 2
        }
        let bounds: [(Float, Float)] = [
            (0.001, 100), (0.001, 100), (0.001, 100), (0.001, 100),
            (1, 10), (0.001, 4), (0.001, 4), (0.001, 0.75),
            (0, 4.5), (0, 0.8), (0.001, 3.5), (0.001, 5),
            (0.001, 0.25), (0.001, 0.9), (0, 4), (0, 1), (1, 6),
            (0, ceiling), (0, ceiling), (shortTermEnabled ? 0.01 : 0, 0.8),
            (0.1, 0.8),
        ]
        for index in result.indices {
            result[index] = min(bounds[index].1, max(bounds[index].0, result[index]))
        }
        return result
    }

    public static func isValid(_ values: [Float]) -> Bool {
        guard values.count == Parameters.count, values.allSatisfy(\.isFinite) else { return false }
        return clip(values) == values
    }

    /// Initial stability must preserve the rating ordering required by FSRS.
    /// Clipping alone cannot make a pathological learned shape safe to promote.
    public static func hasMonotonicInitialStability(_ values: [Float]) -> Bool {
        guard values.count == Parameters.count, values.prefix(4).allSatisfy(\.isFinite) else {
            return false
        }
        return zip(values.prefix(4), values.dropFirst().prefix(3)).allSatisfy(<=)
    }
}

/// Scalar native Swift port of the FSRS-6 state transition in the pinned
/// `fsrs-rs` reference. All forward calculations intentionally remain Float.
public struct FSRS: Sendable {
    public let parameters: Parameters

    public init(parameters: Parameters = .population) {
        self.parameters = parameters
    }

    public func retrievability(state: MemoryState, daysElapsed: Float) -> Float {
        powerForgettingCurve(t: max(0, daysElapsed), stability: state.stability)
    }

    public func nextInterval(stability: Float, desiredRetention: Float) -> Float {
        let w = parameters.values
        let decay = -w[20]
        let factor = exp(log(Float(0.9)) / decay) - 1
        return stability / factor * (pow(desiredRetention, 1 / decay) - 1)
    }

    public func nextStates(
        current: MemoryState?,
        desiredRetention: Float,
        daysElapsed: Float
    ) throws -> NextStates {
        guard desiredRetention.isFinite, desiredRetention > 0, desiredRetention < 1,
              daysElapsed.isFinite, daysElapsed >= 0
        else {
            throw FSRSError.invalidInput
        }
        let state = current ?? MemoryState(stability: 0, difficulty: 0)
        let nth = current == nil ? 0 : 1
        let states = Rating.allCases.map { rating -> ItemState in
            let memory = step(deltaT: daysElapsed, rating: rating, state: state, nth: nth)
            return ItemState(
                memory: memory,
                interval: nextInterval(stability: memory.stability, desiredRetention: desiredRetention)
            )
        }
        guard states.allSatisfy({ $0.memory.stability.isFinite && $0.memory.difficulty.isFinite }) else {
            throw FSRSError.invalidInput
        }
        return NextStates(again: states[0], hard: states[1], good: states[2], easy: states[3])
    }

    public func memoryState(item: Item, startingAt start: MemoryState? = nil) throws -> MemoryState {
        guard item.reviews.allSatisfy({ $0.deltaT.isFinite && $0.deltaT >= 0 }) else {
            throw FSRSError.invalidInput
        }
        var state = start ?? MemoryState(stability: 0, difficulty: 0)
        let startIndex = start == nil ? 0 : 0
        for (index, review) in item.reviews.enumerated().dropFirst(startIndex) {
            state = step(deltaT: review.deltaT, rating: review.rating, state: state, nth: index)
        }
        guard state.stability.isFinite, state.difficulty.isFinite else { throw FSRSError.invalidInput }
        return state
    }

    public func historicalMemoryStates(
        item: Item,
        startingAt start: MemoryState? = nil
    ) throws -> [MemoryState] {
        guard item.reviews.allSatisfy({ $0.deltaT.isFinite && $0.deltaT >= 0 }) else {
            throw FSRSError.invalidInput
        }
        var result: [MemoryState] = start.map { [$0] } ?? []
        var state = start ?? MemoryState(stability: 0, difficulty: 0)
        for (index, review) in item.reviews.enumerated() {
            state = step(deltaT: review.deltaT, rating: review.rating, state: state, nth: index)
            guard state.stability.isFinite, state.difficulty.isFinite else { throw FSRSError.invalidInput }
            result.append(state)
        }
        return result
    }

    private func powerForgettingCurve(t: Float, stability: Float) -> Float {
        let w = parameters.values
        let decay = -w[20]
        let factor = exp(log(Float(0.9)) / decay) - 1
        return pow(t / stability * factor + 1, decay)
    }

    private func initialStability(rating: Rating) -> Float {
        parameters.values[Int(rating.rawValue - 1)]
    }

    private func initialDifficulty(rating: Rating) -> Float {
        let w = parameters.values
        return w[4] - exp(w[5] * Float(rating.rawValue - 1)) + 1
    }

    private func step(
        deltaT: Float,
        rating: Rating,
        state: MemoryState,
        nth: Int
    ) -> MemoryState {
        let w = parameters.values
        let lastS = min(ParameterClipper.stabilityMaximum, max(ParameterClipper.stabilityMinimum, state.stability))
        let lastD = min(ParameterClipper.difficultyMaximum, max(ParameterClipper.difficultyMinimum, state.difficulty))
        let r = powerForgettingCurve(t: deltaT, stability: lastS)

        let hardPenalty: Float = rating == .hard ? w[15] : 1
        let easyBonus: Float = rating == .easy ? w[16] : 1
        let success = lastS * (
            exp(w[8]) * (11 - lastD) * pow(lastS, -w[9])
                * (exp((1 - r) * w[10]) - 1) * hardPenalty * easyBonus + 1
        )
        let failureRaw = w[11] * pow(lastD, -w[12])
            * (pow(lastS + 1, w[13]) - 1) * exp((1 - r) * w[14])
        let failure = min(failureRaw, lastS / exp(w[17] * w[18]))
        let shortIncrease = exp(w[17] * (Float(rating.rawValue) - 3 + w[18])) * pow(lastS, -w[19])
        let shortTerm = lastS * (rating.rawValue >= 2 ? max(1, shortIncrease) : shortIncrease)

        var newS = rating == .again ? failure : success
        if deltaT == 0 { newS = shortTerm }
        let deltaD = -w[6] * (Float(rating.rawValue) - 3)
        var newD = lastD + (10 - lastD) * deltaD / 9
        let easyD = initialDifficulty(rating: .easy)
        newD = w[7] * (easyD - newD) + newD
        newD = min(10, max(1, newD))

        if nth == 0 && state.stability == 0 {
            newS = initialStability(rating: rating)
            newD = min(10, max(1, initialDifficulty(rating: rating)))
        }
        return MemoryState(
            stability: min(36_500, max(0.001, newS)),
            difficulty: newD
        )
    }
}
