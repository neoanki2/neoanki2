import Foundation

/// One held-out recall target and the competing predictions for it. Intraday
/// answers remain in the sequence used to produce these predictions, but are
/// deliberately absent here because `elapsedDays` must be positive.
public struct FSRSPromotionObservation: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let cardID: UUID
    public let reviewedAt: Date
    public let sequence: Int64?
    public let studyDay: Int
    public let elapsedDays: UInt32
    public let recalled: Bool
    public let activeProbability: Double
    public let defaultProbability: Double
    public let candidateProbability: Double

    public init(
        id: UUID = UUID(),
        cardID: UUID,
        reviewedAt: Date,
        sequence: Int64? = nil,
        studyDay: Int? = nil,
        elapsedDays: UInt32,
        recalled: Bool,
        activeProbability: Double,
        defaultProbability: Double,
        candidateProbability: Double
    ) {
        self.id = id
        self.cardID = cardID
        self.reviewedAt = reviewedAt
        self.sequence = sequence
        self.studyDay = studyDay ?? Int(floor(reviewedAt.timeIntervalSince1970 / 86_400))
        self.elapsedDays = elapsedDays
        self.recalled = recalled
        self.activeProbability = activeProbability
        self.defaultProbability = defaultProbability
        self.candidateProbability = candidateProbability
    }
}

public struct FSRSPromotionThresholds: Sendable, Equatable {
    public var minimumTargets = 400
    public var minimumCards = 100
    public var minimumFailures = 30
    public var minimumStudyDays = 30
    public var minimumTargetsPerPopulatedBucket = 20
    public var minimumPopulatedBuckets = 2
    public var minimumValidationTargets = 150
    public var minimumValidationFailures = 15
    public var bootstrapSamples = 2_000

    public init() {}
}

public enum FSRSElapsedBucket: String, CaseIterable, Sendable, Equatable {
    case underThreeDays
    case threeThroughThirtyDays
    case overThirtyDays

    init(days: UInt32) {
        if days < 3 { self = .underThreeDays }
        else if days <= 30 { self = .threeThroughThirtyDays }
        else { self = .overThirtyDays }
    }
}

public struct FSRSPromotionEligibility: Sendable, Equatable {
    public let eligible: Bool
    public let targetCount: Int
    public let distinctCardCount: Int
    public let failureCount: Int
    public let studyDayCount: Int
    public let bucketCounts: [FSRSElapsedBucket: Int]
    public let validationTargetCount: Int
    public let validationFailureCount: Int
    public let unmetRequirements: [String]
}

public enum FSRSRefitTrigger: String, Sendable, Equatable {
    case initial
    case standard
    case dataBurst
    case maximumStale
    case calibrationDrift
}

public struct FSRSRefitContext: Sendable, Equatable {
    public let lastCompletedAt: Date?
    public let newTargetCount: Int
    public let newFailureCount: Int
    public let newDistinctCardCount: Int
    public let rollingCalibrationError: Double
    public let relativeLogLossRegression: Double

    public init(
        lastCompletedAt: Date?,
        newTargetCount: Int,
        newFailureCount: Int,
        newDistinctCardCount: Int,
        rollingCalibrationError: Double = 0,
        relativeLogLossRegression: Double = 0
    ) {
        self.lastCompletedAt = lastCompletedAt
        self.newTargetCount = newTargetCount
        self.newFailureCount = newFailureCount
        self.newDistinctCardCount = newDistinctCardCount
        self.rollingCalibrationError = rollingCalibrationError
        self.relativeLogLossRegression = relativeLogLossRegression
    }
}

public struct FSRSChronologicalFold: Sendable, Equatable {
    public let trainingIndices: [Int]
    public let validationIndices: [Int]
}

public struct FSRSPredictiveMetrics: Sendable, Equatable {
    public let logLoss: Double
    public let brierScore: Double
    public let rmseBins: Double
    public let nearTargetCalibrationError: Double
    public let sliceLogLoss: [FSRSElapsedBucket: Double]

    public static let invalid = FSRSPredictiveMetrics(
        logLoss: .infinity,
        brierScore: .infinity,
        rmseBins: .infinity,
        nearTargetCalibrationError: .infinity,
        sliceLogLoss: [:]
    )
}

public struct FSRSPromotionMetrics: Sendable, Equatable {
    public let active: FSRSPredictiveMetrics
    public let defaults: FSRSPredictiveMetrics
    public let empiricalBaseRate: FSRSPredictiveMetrics
    public let candidate: FSRSPredictiveMetrics
    /// 95th percentile of bootstrapped candidate-minus-active log loss.
    public let logLossRegressionUpper95: Double
}

public struct FSRSCandidateInvariants: Sendable, Equatable {
    public let finiteParameters: Bool
    public let withinCanonicalBounds: Bool
    public let coupledConstraintsSatisfied: Bool
    public let monotonicInitialStability: Bool
    public let orderedPassingIntervals: Bool
    public let deterministicReplay: Bool

    public init(
        finiteParameters: Bool,
        withinCanonicalBounds: Bool,
        coupledConstraintsSatisfied: Bool,
        monotonicInitialStability: Bool,
        orderedPassingIntervals: Bool,
        deterministicReplay: Bool
    ) {
        self.finiteParameters = finiteParameters
        self.withinCanonicalBounds = withinCanonicalBounds
        self.coupledConstraintsSatisfied = coupledConstraintsSatisfied
        self.monotonicInitialStability = monotonicInitialStability
        self.orderedPassingIntervals = orderedPassingIntervals
        self.deterministicReplay = deterministicReplay
    }

    public var allSatisfied: Bool {
        finiteParameters && withinCanonicalBounds && coupledConstraintsSatisfied
            && monotonicInitialStability && orderedPassingIntervals && deterministicReplay
    }
}

public struct FSRSWorkloadProjection: Sendable, Equatable {
    public let p95GoodIntervalRatio: Double
    public let projectedThirtyDayWorkloadChange: Double

    public init(p95GoodIntervalRatio: Double, projectedThirtyDayWorkloadChange: Double) {
        self.p95GoodIntervalRatio = p95GoodIntervalRatio
        self.projectedThirtyDayWorkloadChange = projectedThirtyDayWorkloadChange
    }

    public var requiresManualApproval: Bool {
        !p95GoodIntervalRatio.isFinite
            || p95GoodIntervalRatio < 0.5 || p95GoodIntervalRatio > 2
            || abs(projectedThirtyDayWorkloadChange) > 0.25
    }
}

public enum FSRSPromotionDisposition: Sendable, Equatable {
    case promote
    case hold(reason: String)
    case reject(reason: String)

    public var allowsActivation: Bool {
        if case .promote = self { true } else { false }
    }
}

public enum FSRSProbationDisposition: Sendable, Equatable {
    case continueProbation
    case complete
    case rollback(reason: String)
}

public struct FSRSProbationEvidence: Sendable, Equatable {
    public let elapsedDays: Int
    public let observedTargets: Int
    public let studyDays: Int
    public let candidateMinusPreviousLogLoss: Double
    public let onTimeRecallRate: Double
    public let desiredRetention: Double
    public let reviewTimeRatio: Double
    public let lapseImproved: Bool
    public let invariantOrReplayFailure: Bool

    public init(
        elapsedDays: Int,
        observedTargets: Int,
        studyDays: Int,
        candidateMinusPreviousLogLoss: Double,
        onTimeRecallRate: Double,
        desiredRetention: Double,
        reviewTimeRatio: Double,
        lapseImproved: Bool,
        invariantOrReplayFailure: Bool
    ) {
        self.elapsedDays = elapsedDays
        self.observedTargets = observedTargets
        self.studyDays = studyDays
        self.candidateMinusPreviousLogLoss = candidateMinusPreviousLogLoss
        self.onTimeRecallRate = onTimeRecallRate
        self.desiredRetention = desiredRetention
        self.reviewTimeRatio = reviewTimeRatio
        self.lapseImproved = lapseImproved
        self.invariantOrReplayFailure = invariantOrReplayFailure
    }
}

/// Pure validation/orchestration policy. It cannot persist or activate a model.
public struct FSRSPromotionPolicy: Sendable {
    public let thresholds: FSRSPromotionThresholds
    public let bootstrapSeed: UInt64

    public init(
        thresholds: FSRSPromotionThresholds = FSRSPromotionThresholds(),
        bootstrapSeed: UInt64 = 2_023
    ) {
        self.thresholds = thresholds
        self.bootstrapSeed = bootstrapSeed
    }

    public func eligibility(
        observations input: [FSRSPromotionObservation]
    ) -> FSRSPromotionEligibility {
        let observations = Self.interday(input)
        let failures = observations.lazy.filter { !$0.recalled }.count
        let cards = Set(observations.map(\.cardID)).count
        let days = Set(observations.map(\.studyDay)).count
        let buckets = Dictionary(grouping: observations, by: { FSRSElapsedBucket(days: $0.elapsedDays) })
            .mapValues(\.count)
        let populated = buckets.values.filter { $0 >= thresholds.minimumTargetsPerPopulatedBucket }.count
        let validationCount = min(observations.count, thresholds.minimumValidationTargets)
        let validation = observations.sorted(by: Self.chronological).suffix(validationCount)
        let validationFailures = validation.lazy.filter { !$0.recalled }.count
        var unmet: [String] = []
        if observations.count < thresholds.minimumTargets { unmet.append("minimumTargets") }
        if cards < thresholds.minimumCards { unmet.append("minimumCards") }
        if failures < thresholds.minimumFailures { unmet.append("minimumFailures") }
        if days < thresholds.minimumStudyDays { unmet.append("minimumStudyDays") }
        if populated < thresholds.minimumPopulatedBuckets { unmet.append("elapsedBuckets") }
        if validation.count < thresholds.minimumValidationTargets { unmet.append("validationTargets") }
        if validationFailures < thresholds.minimumValidationFailures { unmet.append("validationFailures") }
        return FSRSPromotionEligibility(
            eligible: unmet.isEmpty,
            targetCount: observations.count,
            distinctCardCount: cards,
            failureCount: failures,
            studyDayCount: days,
            bucketCounts: buckets,
            validationTargetCount: validation.count,
            validationFailureCount: validationFailures,
            unmetRequirements: unmet
        )
    }

    public func refitTrigger(
        context: FSRSRefitContext,
        now: Date,
        isInitiallyEligible: Bool
    ) -> FSRSRefitTrigger? {
        guard let last = context.lastCompletedAt else {
            return isInitiallyEligible ? .initial : nil
        }
        let days = max(0, now.timeIntervalSince(last) / 86_400)
        guard days >= 7 else { return nil }
        if context.newTargetCount >= 1_000,
           context.newFailureCount >= 25,
           context.newDistinctCardCount >= 100 { return .dataBurst }
        if context.newTargetCount >= 100,
           (context.rollingCalibrationError > 0.07
               || context.relativeLogLossRegression >= 0.10) { return .calibrationDrift }
        if days >= 30,
           context.newTargetCount >= 200,
           context.newFailureCount >= 10,
           context.newDistinctCardCount >= 50 { return .standard }
        if days >= 90,
           context.newTargetCount >= 100,
           context.newFailureCount >= 5,
           context.newDistinctCardCount >= 25 { return .maximumStale }
        return nil
    }

    public func chronologicalFolds(
        observations input: [FSRSPromotionObservation]
    ) -> [FSRSChronologicalFold] {
        let count = Self.interday(input).count
        guard count >= thresholds.minimumTargets else { return [] }
        let foldCount = count < 700 ? 3 : 5
        let validationTotal = max(thresholds.minimumValidationTargets, count / 4)
        guard validationTotal < count else { return [] }
        let initialTrainingCount = count - validationTotal
        var result: [FSRSChronologicalFold] = []
        var validationStart = initialTrainingCount
        for fold in 0 ..< foldCount {
            let remaining = count - validationStart
            let remainingFolds = foldCount - fold
            let size = Int(ceil(Double(remaining) / Double(remainingFolds)))
            let end = min(count, validationStart + size)
            guard validationStart < end else { break }
            result.append(FSRSChronologicalFold(
                trainingIndices: Array(0 ..< validationStart),
                validationIndices: Array(validationStart ..< end)
            ))
            validationStart = end
        }
        return result
    }

    public func metrics(
        observations input: [FSRSPromotionObservation],
        desiredRetention: Double
    ) -> FSRSPromotionMetrics {
        let observations = Self.interday(input).sorted(by: Self.chronological)
        guard !observations.isEmpty else {
            return FSRSPromotionMetrics(
                active: .invalid, defaults: .invalid, empiricalBaseRate: .invalid,
                candidate: .invalid, logLossRegressionUpper95: .infinity
            )
        }
        let base = Double(observations.lazy.filter(\.recalled).count) / Double(observations.count)
        let active = Self.predictiveMetrics(observations, desiredRetention: desiredRetention) { $0.activeProbability }
        let defaults = Self.predictiveMetrics(observations, desiredRetention: desiredRetention) { $0.defaultProbability }
        let candidate = Self.predictiveMetrics(observations, desiredRetention: desiredRetention) { $0.candidateProbability }
        let baseMetrics = Self.predictiveMetrics(observations, desiredRetention: desiredRetention) { _ in base }
        return FSRSPromotionMetrics(
            active: active,
            defaults: defaults,
            empiricalBaseRate: baseMetrics,
            candidate: candidate,
            logLossRegressionUpper95: bootstrapUpper95(observations)
        )
    }

    public func disposition(
        eligibility: FSRSPromotionEligibility,
        metrics: FSRSPromotionMetrics,
        invariants: FSRSCandidateInvariants,
        workload: FSRSWorkloadProjection,
        optimizerParityVerified: Bool
    ) -> FSRSPromotionDisposition {
        guard eligibility.eligible else { return .reject(reason: "notEnoughData") }
        guard optimizerParityVerified else { return .hold(reason: "optimizerParityNotVerified") }
        guard invariants.allSatisfied else { return .reject(reason: "candidateInvariantFailed") }
        let active = metrics.active
        let candidate = metrics.candidate
        guard candidate.logLoss.isFinite, active.logLoss.isFinite else {
            return .reject(reason: "nonFiniteMetrics")
        }
        guard candidate.logLoss <= active.logLoss * 0.99 else {
            return .reject(reason: "insufficientLogLossImprovement")
        }
        guard candidate.logLoss < metrics.defaults.logLoss,
              candidate.logLoss < metrics.empiricalBaseRate.logLoss else {
            return .reject(reason: "baselineNotBeaten")
        }
        guard metrics.logLossRegressionUpper95 <= 0.005 else {
            return .reject(reason: "logLossConfidenceRegression")
        }
        guard candidate.brierScore - active.brierScore <= 0.005 else {
            return .reject(reason: "brierRegression")
        }
        guard candidate.rmseBins - active.rmseBins <= 0.01 else {
            return .reject(reason: "rmseBinRegression")
        }
        for bucket in FSRSElapsedBucket.allCases {
            if let candidateSlice = candidate.sliceLogLoss[bucket],
               let activeSlice = active.sliceLogLoss[bucket],
               candidateSlice - activeSlice > 0.02 {
                return .reject(reason: "sliceRegression.\(bucket.rawValue)")
            }
        }
        guard candidate.nearTargetCalibrationError <= 0.05 else {
            return .reject(reason: "targetCalibration")
        }
        if workload.requiresManualApproval { return .hold(reason: "workloadChange") }
        return .promote
    }

    /// Converts an optimizer failure into an append-only terminal run. No
    /// candidate ID is accepted, so this API cannot accidentally activate it.
    public func failedRun(
        eligibility: FSRSPromotionEligibility,
        startedAt: Date,
        completedAt: Date,
        trainingCutoff: Date,
        inputFingerprint: String,
        error: FSRSOptimizationError
    ) -> FSRSOptimizationRun {
        FSRSOptimizationRun(
            presetID: SchedulerPersistenceConstants.sharedPresetID,
            startedAt: startedAt,
            completedAt: completedAt,
            trainingCutoff: trainingCutoff,
            inputFingerprint: inputFingerprint,
            eligibleTargetCount: eligibility.targetCount,
            distinctCardCount: eligibility.distinctCardCount,
            failureCount: eligibility.failureCount,
            studyDayCount: eligibility.studyDayCount,
            foldCount: chronologicalFoldCount(for: eligibility.targetCount),
            decision: error == .optimizerParityNotVerified ? .held : .failed,
            reason: error.localizedDescription,
            candidateParameterSetID: nil
        )
    }

    public func probationDisposition(
        evidence: FSRSProbationEvidence
    ) -> FSRSProbationDisposition {
        if evidence.invariantOrReplayFailure { return .rollback(reason: "invariantOrReplayFailure") }
        if evidence.candidateMinusPreviousLogLoss >= 0.02 {
            return .rollback(reason: "logLossRegression")
        }
        if evidence.onTimeRecallRate < evidence.desiredRetention - 0.07 {
            return .rollback(reason: "recallBelowTarget")
        }
        if evidence.studyDays >= 7,
           evidence.reviewTimeRatio >= 1.5,
           !evidence.lapseImproved { return .rollback(reason: "reviewTimeRegression") }
        if evidence.elapsedDays >= 30, evidence.observedTargets >= 100 { return .complete }
        return .continueProbation
    }

    private func chronologicalFoldCount(for targetCount: Int) -> Int {
        guard targetCount >= thresholds.minimumTargets else { return 0 }
        return targetCount < 700 ? 3 : 5
    }

    private func bootstrapUpper95(_ observations: [FSRSPromotionObservation]) -> Double {
        let grouped = Dictionary(grouping: observations, by: \.cardID)
        let cards = grouped.keys.sorted { $0.uuidString < $1.uuidString }
        guard !cards.isEmpty else { return .infinity }
        var generator = PromotionRNG(state: bootstrapSeed)
        var deltas: [Double] = []
        deltas.reserveCapacity(thresholds.bootstrapSamples)
        for _ in 0 ..< thresholds.bootstrapSamples {
            var activeLoss = 0.0
            var candidateLoss = 0.0
            var count = 0
            for _ in cards.indices {
                let card = cards[Int(generator.next() % UInt64(cards.count))]
                for observation in grouped[card] ?? [] {
                    activeLoss += Self.logLoss(observation.recalled, observation.activeProbability)
                    candidateLoss += Self.logLoss(observation.recalled, observation.candidateProbability)
                    count += 1
                }
            }
            if count > 0 { deltas.append((candidateLoss - activeLoss) / Double(count)) }
        }
        guard !deltas.isEmpty else { return .infinity }
        deltas.sort()
        return deltas[min(deltas.count - 1, Int(floor(Double(deltas.count - 1) * 0.95)))]
    }

    private static func interday(
        _ observations: [FSRSPromotionObservation]
    ) -> [FSRSPromotionObservation] {
        observations.filter { $0.elapsedDays > 0 }
    }

    private static func chronological(
        _ lhs: FSRSPromotionObservation,
        _ rhs: FSRSPromotionObservation
    ) -> Bool {
        if lhs.reviewedAt != rhs.reviewedAt { return lhs.reviewedAt < rhs.reviewedAt }
        if let left = lhs.sequence, let right = rhs.sequence, left != right {
            return left < right
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func predictiveMetrics(
        _ observations: [FSRSPromotionObservation],
        desiredRetention: Double,
        prediction: (FSRSPromotionObservation) -> Double
    ) -> FSRSPredictiveMetrics {
        guard !observations.isEmpty else { return .invalid }
        var loss = 0.0
        var brier = 0.0
        var bins: [[(Double, Double)]] = Array(repeating: [], count: 10)
        var nearTarget: [(Double, Double)] = []
        var slices: [FSRSElapsedBucket: (loss: Double, count: Int)] = [:]
        for observation in observations {
            let probability = prediction(observation)
            guard probability.isFinite else { return .invalid }
            let p = min(1 - 1e-7, max(1e-7, probability))
            let y = observation.recalled ? 1.0 : 0.0
            let itemLoss = logLoss(observation.recalled, p)
            loss += itemLoss
            brier += (p - y) * (p - y)
            bins[min(9, Int(p * 10))].append((p, y))
            if abs(p - desiredRetention) <= 0.05 { nearTarget.append((p, y)) }
            let bucket = FSRSElapsedBucket(days: observation.elapsedDays)
            let prior = slices[bucket] ?? (0, 0)
            slices[bucket] = (prior.loss + itemLoss, prior.count + 1)
        }
        let populated = bins.filter { !$0.isEmpty }
        let binError = populated.reduce(0.0) { partial, bin in
            let predicted = bin.reduce(0.0) { $0 + $1.0 } / Double(bin.count)
            let observed = bin.reduce(0.0) { $0 + $1.1 } / Double(bin.count)
            return partial + (predicted - observed) * (predicted - observed)
        }
        let calibration: Double
        if nearTarget.isEmpty {
            calibration = .infinity
        } else {
            let predicted = nearTarget.reduce(0.0) { $0 + $1.0 } / Double(nearTarget.count)
            let observed = nearTarget.reduce(0.0) { $0 + $1.1 } / Double(nearTarget.count)
            calibration = abs(predicted - observed)
        }
        return FSRSPredictiveMetrics(
            logLoss: loss / Double(observations.count),
            brierScore: brier / Double(observations.count),
            rmseBins: sqrt(binError / Double(max(1, populated.count))),
            nearTargetCalibrationError: calibration,
            sliceLogLoss: slices.mapValues { $0.loss / Double($0.count) }
        )
    }

    private static func logLoss(_ recalled: Bool, _ probability: Double) -> Double {
        let p = min(1 - 1e-7, max(1e-7, probability))
        return recalled ? -log(p) : -log(1 - p)
    }
}

private struct PromotionRNG {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
