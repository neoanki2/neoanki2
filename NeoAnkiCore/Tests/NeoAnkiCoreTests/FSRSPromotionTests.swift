import Foundation
import Testing
@testable import NeoAnkiCore

@Test func promotionEligibilityEnforcesDiversityAndIgnoresExactRepeatTargets() {
    let policy = FSRSPromotionPolicy()
    var observations = promotionObservations(count: 400)
    observations.append(FSRSPromotionObservation(
        cardID: UUID(), reviewedAt: .now, elapsedDays: 0, recalled: false,
        activeProbability: 0.5, defaultProbability: 0.5, candidateProbability: 0.5
    ))

    let eligibility = policy.eligibility(observations: observations)

    #expect(eligibility.eligible)
    #expect(eligibility.targetCount == 400)
    #expect(eligibility.distinctCardCount == 100)
    #expect(eligibility.failureCount == 40)
    #expect(eligibility.validationTargetCount == 150)
    #expect(eligibility.validationFailureCount == 15)
    #expect(eligibility.bucketCounts.values.allSatisfy { $0 >= 20 })
}

@Test func promotionEligibilityReportsEveryMissingGate() {
    let eligibility = FSRSPromotionPolicy().eligibility(
        observations: Array(promotionObservations(count: 10).prefix(10))
    )
    #expect(!eligibility.eligible)
    #expect(Set(eligibility.unmetRequirements) == [
        "minimumTargets", "minimumCards", "minimumFailures", "minimumStudyDays",
        "elapsedBuckets", "validationTargets", "validationFailures",
    ])
}

@Test func refitCadenceUsesConservativeTriggers() {
    let policy = FSRSPromotionPolicy()
    let now = Date(timeIntervalSince1970: 10_000_000)
    #expect(policy.refitTrigger(
        context: .init(lastCompletedAt: nil, newTargetCount: 0, newFailureCount: 0, newDistinctCardCount: 0),
        now: now, isInitiallyEligible: true
    ) == .initial)
    #expect(policy.refitTrigger(
        context: .init(lastCompletedAt: now.addingTimeInterval(-7 * 86_400), newTargetCount: 1_000, newFailureCount: 25, newDistinctCardCount: 100),
        now: now, isInitiallyEligible: true
    ) == .dataBurst)
    #expect(policy.refitTrigger(
        context: .init(lastCompletedAt: now.addingTimeInterval(-30 * 86_400), newTargetCount: 200, newFailureCount: 10, newDistinctCardCount: 50),
        now: now, isInitiallyEligible: true
    ) == .standard)
    #expect(policy.refitTrigger(
        context: .init(lastCompletedAt: now.addingTimeInterval(-90 * 86_400), newTargetCount: 100, newFailureCount: 5, newDistinctCardCount: 25),
        now: now, isInitiallyEligible: true
    ) == .maximumStale)
    #expect(policy.refitTrigger(
        context: .init(lastCompletedAt: now.addingTimeInterval(-7 * 86_400), newTargetCount: 100, newFailureCount: 1, newDistinctCardCount: 1, rollingCalibrationError: 0.071),
        now: now, isInitiallyEligible: true
    ) == .calibrationDrift)
}

@Test func chronologicalFoldsExpandTrainingAndCoverHeldOutTail() {
    let folds = FSRSPromotionPolicy().chronologicalFolds(
        observations: promotionObservations(count: 400)
    )
    #expect(folds.count == 3)
    #expect(folds[0].trainingIndices.count == 250)
    #expect(folds[0].validationIndices.count == 50)
    #expect(folds[1].trainingIndices.count == 300)
    #expect(folds[2].trainingIndices.count == 350)
    #expect(folds.flatMap(\.validationIndices) == Array(250 ..< 400))
}

@Test func promotionRequiresParityAndHoldsLargeWorkloadChanges() {
    let policy = FSRSPromotionPolicy()
    let observations = promotionObservations(count: 400)
    let eligibility = policy.eligibility(observations: observations)
    let metrics = policy.metrics(observations: observations, desiredRetention: 0.9)
    let invariants = FSRSCandidateInvariants(
        finiteParameters: true, withinCanonicalBounds: true,
        coupledConstraintsSatisfied: true, monotonicInitialStability: true,
        orderedPassingIntervals: true, deterministicReplay: true
    )
    #expect(policy.disposition(
        eligibility: eligibility, metrics: metrics, invariants: invariants,
        workload: .init(p95GoodIntervalRatio: 1, projectedThirtyDayWorkloadChange: 0),
        optimizerParityVerified: false
    ) == .hold(reason: "optimizerParityNotVerified"))
    #expect(policy.disposition(
        eligibility: eligibility, metrics: metrics, invariants: invariants,
        workload: .init(p95GoodIntervalRatio: 1, projectedThirtyDayWorkloadChange: 0),
        optimizerParityVerified: true
    ) == .promote)
    #expect(policy.disposition(
        eligibility: eligibility, metrics: metrics, invariants: invariants,
        workload: .init(p95GoodIntervalRatio: 2.1, projectedThirtyDayWorkloadChange: 0),
        optimizerParityVerified: true
    ) == .hold(reason: "workloadChange"))
}

@Test func bootstrapConfidenceIsDeterministic() {
    let observations = promotionObservations(count: 400)
    let first = FSRSPromotionPolicy(bootstrapSeed: 42).metrics(
        observations: observations, desiredRetention: 0.9
    )
    let second = FSRSPromotionPolicy(bootstrapSeed: 42).metrics(
        observations: observations, desiredRetention: 0.9
    )
    #expect(first == second)
    #expect(first.logLossRegressionUpper95 < 0)
}

@Test func parityFailureProducesHeldImmutableRunWithoutCandidate() {
    let policy = FSRSPromotionPolicy()
    let eligibility = policy.eligibility(observations: promotionObservations(count: 400))
    let now = Date(timeIntervalSince1970: 20_000_000)
    let run = policy.failedRun(
        eligibility: eligibility,
        startedAt: now.addingTimeInterval(-1),
        completedAt: now,
        trainingCutoff: now,
        inputFingerprint: "abc",
        error: .optimizerParityNotVerified
    )
    #expect(run.decision == .held)
    #expect(run.candidateParameterSetID == nil)
    #expect(run.foldCount == 3)
}

@Test func probationRollsBackUnsafeModelsAndCompletesOnlyAfterBothGates() {
    let policy = FSRSPromotionPolicy()
    #expect(policy.probationDisposition(evidence: .init(
        elapsedDays: 1, observedTargets: 10, studyDays: 1,
        candidateMinusPreviousLogLoss: 0, onTimeRecallRate: 0.9,
        desiredRetention: 0.9, reviewTimeRatio: 1, lapseImproved: false,
        invariantOrReplayFailure: true
    )) == .rollback(reason: "invariantOrReplayFailure"))
    #expect(policy.probationDisposition(evidence: .init(
        elapsedDays: 30, observedTargets: 100, studyDays: 20,
        candidateMinusPreviousLogLoss: 0, onTimeRecallRate: 0.9,
        desiredRetention: 0.9, reviewTimeRatio: 1, lapseImproved: false,
        invariantOrReplayFailure: false
    )) == .complete)
    #expect(policy.probationDisposition(evidence: .init(
        elapsedDays: 30, observedTargets: 99, studyDays: 20,
        candidateMinusPreviousLogLoss: 0, onTimeRecallRate: 0.9,
        desiredRetention: 0.9, reviewTimeRatio: 1, lapseImproved: false,
        invariantOrReplayFailure: false
    )) == .continueProbation)
}

private func promotionObservations(count: Int) -> [FSRSPromotionObservation] {
    let cards = (0 ..< 100).map { index in
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!
    }
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    return (0 ..< count).map { index in
        let recalled = index % 10 != 0
        let elapsed: UInt32 = switch index % 3 {
        case 0: 1
        case 1: 10
        default: 45
        }
        return FSRSPromotionObservation(
            id: UUID(uuidString: String(format: "10000000-0000-4000-8000-%012d", index))!,
            cardID: cards[index % cards.count],
            reviewedAt: start.addingTimeInterval(Double(index) * 86_400),
            studyDay: index % 40,
            elapsedDays: Double(elapsed),
            recalled: recalled,
            activeProbability: recalled ? 0.82 : 0.55,
            defaultProbability: recalled ? 0.78 : 0.60,
            candidateProbability: index < 100 ? 0.90 : (recalled ? 0.95 : 0.20)
        )
    }
}
