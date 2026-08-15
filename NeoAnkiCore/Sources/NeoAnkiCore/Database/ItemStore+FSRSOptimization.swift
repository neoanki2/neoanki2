import CryptoKit
import Foundation

extension ItemStore {
    func runAutomaticFSRSOptimization(
        minimumObservations: Int,
        now: Date,
        enforceCadence: Bool = true,
        optimizerParityVerified: Bool = SchedulerPersistenceConstants.optimizerParityVerified,
        probationEvidenceOverride: FSRSProbationEvidence? = nil
    ) async throws -> FSRSOptimizationResult? {
        let policy = FSRSPromotionPolicy()
        let logs = try await database.fetchActiveReviewLogs()
        let context = try await activeSchedulingContext()
        if enforceCadence,
           try await evaluateActiveFSRSProbation(
               policy: policy,
               logs: logs,
               context: context,
               now: now,
               evidenceOverride: probationEvidenceOverride
           ) {
            return nil
        }
        let defaults = FSRSScheduler.Parameters(
            requestRetention: context.preset.desiredRetention,
            maximumInterval: context.preset.maximumIntervalDays
        )
        let baselineObservations = promotionObservations(
            logs: logs,
            active: context.parameters,
            defaults: defaults,
            candidate: context.parameters
        )
        let eligibility = policy.eligibility(observations: baselineObservations)
        let previousRun = try await database.fetchFSRSOptimizationRuns(limit: 1).first
        let newObservations = previousRun.map { run in
            baselineObservations.filter { $0.reviewedAt > run.trainingCutoff }
        } ?? baselineObservations
        let trigger = policy.refitTrigger(
            context: FSRSRefitContext(
                lastCompletedAt: previousRun?.completedAt,
                newTargetCount: newObservations.count,
                newFailureCount: newObservations.lazy.filter { !$0.recalled }.count,
                newDistinctCardCount: Set(newObservations.map { $0.cardID }).count
            ),
            now: now,
            isInitiallyEligible: eligibility.eligible
        )
        guard eligibility.eligible, !enforceCadence || trigger != nil else { return nil }

        let startedAt = now
        let fingerprint = optimizationInputFingerprint(logs)
        try await recordOptimizationAttempt(reviewLogCount: logs.count, at: now)
        guard optimizerParityVerified else {
            let error = FSRSOptimizationError.optimizerParityNotVerified
            try await database.insertFSRSOptimizationRun(policy.failedRun(
                eligibility: eligibility,
                startedAt: startedAt,
                completedAt: now,
                trainingCutoff: logs.map(\.reviewedAt).max() ?? now,
                inputFingerprint: fingerprint,
                error: error
            ))
            throw error
        }

        let folds = policy.chronologicalFolds(observations: baselineObservations)
        guard !folds.isEmpty else {
            let error = FSRSOptimizationError.insufficientData(
                required: policy.thresholds.minimumValidationTargets,
                available: baselineObservations.count
            )
            try await database.insertFSRSOptimizationRun(heldOptimizationRun(
                eligibility: eligibility,
                startedAt: startedAt,
                completedAt: now,
                logs: logs,
                fingerprint: fingerprint,
                foldCount: folds.count,
                reason: "chronologicalValidationUnavailable.\(error.localizedDescription)"
            ))
            throw error
        }

        // Fit each expanding training prefix independently. Candidate
        // probabilities are copied only from that fold's held-out suffix, so
        // no target is ever scored by parameters trained on itself or later
        // answers.
        var heldOut: [FSRSPromotionObservation] = []
        do {
            for fold in folds {
                guard let lastTrainingIndex = fold.trainingIndices.last else {
                    throw FSRSOptimizationError.insufficientData(required: 1, available: 0)
                }
                let target = baselineObservations[lastTrainingIndex]
                let prefix = optimizationLogPrefix(logs, throughTargetID: target.id)
                let foldOptimizer = FSRSOptimizer(
                    minimumObservations: min(minimumObservations, fold.trainingIndices.count)
                )
                let foldResult = try foldOptimizer.optimize(
                    logs: prefix,
                    startingAt: context.parameters
                )
                let foldPredictions = Dictionary(uniqueKeysWithValues: promotionObservations(
                    logs: logs,
                    active: context.parameters,
                    defaults: defaults,
                    candidate: foldResult.parameters
                ).map { ($0.id, $0) })
                for index in fold.validationIndices {
                    guard let prediction = foldPredictions[baselineObservations[index].id] else {
                        throw FSRSOptimizationError.invalidParameters
                    }
                    heldOut.append(prediction)
                }
            }
        } catch let error as FSRSOptimizationError {
            try await database.insertFSRSOptimizationRun(heldOptimizationRun(
                eligibility: eligibility,
                startedAt: startedAt,
                completedAt: now,
                logs: logs,
                fingerprint: fingerprint,
                foldCount: folds.count,
                reason: "chronologicalFoldFitFailed.\(error.localizedDescription)"
            ))
            throw error
        }

        let optimizer = FSRSOptimizer(minimumObservations: minimumObservations)
        let result: FSRSOptimizationResult
        do {
            result = try optimizer.optimize(logs: logs, startingAt: context.parameters)
        } catch let error as FSRSOptimizationError {
            let run = policy.failedRun(
                eligibility: eligibility,
                startedAt: startedAt,
                completedAt: now,
                trainingCutoff: logs.map(\.reviewedAt).max() ?? now,
                inputFingerprint: fingerprint,
                error: error
            )
            try await database.insertFSRSOptimizationRun(run)
            throw error
        }

        let candidateID = UUID()
        let candidateSet = FSRSParameterSet(
            id: candidateID,
            weights: result.parameters.weights,
            modelVersion: SchedulerPersistenceConstants.memoryModelVersion,
            upstreamCommit: SchedulerPersistenceConstants.upstreamCommit,
            sourceChecksum: SchedulerPersistenceConstants.sourceChecksum,
            fixtureChecksum: SchedulerPersistenceConstants.fixtureChecksum,
            source: .optimized,
            inputFingerprint: fingerprint,
            trainingCutoff: logs.map(\.reviewedAt).max() ?? now,
            metrics: [
                "training.previousLogLoss": result.previousLoss,
                "training.candidateLogLoss": result.optimizedLoss,
            ],
            previousParameterSetID: context.parameterSet.id,
            createdAt: now
        )
        let allObservations = promotionObservations(
            logs: logs,
            active: context.parameters,
            defaults: defaults,
            candidate: result.parameters
        ).sorted(by: promotionChronological)
        let metrics = policy.metrics(
            observations: heldOut,
            desiredRetention: context.preset.desiredRetention
        )
        let invariants = candidateInvariants(
            parameters: result.parameters,
            logs: logs,
            candidateObservations: allObservations
        )
        let workload = workloadProjection(
            logs: logs,
            active: context.parameters,
            candidate: result.parameters
        )
        let disposition = policy.disposition(
            eligibility: eligibility,
            metrics: metrics,
            invariants: invariants,
            workload: workload,
            optimizerParityVerified: optimizerParityVerified
        )
        let decision: FSRSOptimizationDecision
        let reason: String?
        switch disposition {
        case .promote:
            decision = .promoted
            reason = nil
        case let .hold(value):
            decision = .held
            reason = value
        case let .reject(value):
            decision = .rejected
            reason = value
        }
        let run = FSRSOptimizationRun(
            presetID: context.preset.id,
            startedAt: startedAt,
            completedAt: now,
            trainingCutoff: logs.map(\.reviewedAt).max() ?? now,
            inputFingerprint: fingerprint,
            eligibleTargetCount: eligibility.targetCount,
            distinctCardCount: eligibility.distinctCardCount,
            failureCount: eligibility.failureCount,
            studyDayCount: eligibility.studyDayCount,
            foldCount: folds.count,
            metrics: persistedPromotionMetrics(metrics),
            decision: decision,
            reason: reason,
            candidateParameterSetID: candidateID
        )
        try await database.persistFSRSOptimizationOutcome(
            parameterSet: candidateSet,
            run: run,
            activate: disposition.allowsActivation,
            now: now
        )
        if disposition.allowsActivation {
            fsrsParameters = result.parameters
        }
        return result
    }

    /// Returns true when probation produced a terminal state and this
    /// automatic pass should stop before considering another fit.
    private func evaluateActiveFSRSProbation(
        policy: FSRSPromotionPolicy,
        logs: [ReviewLog],
        context: ActiveSchedulingContext,
        now: Date,
        evidenceOverride: FSRSProbationEvidence?
    ) async throws -> Bool {
        let activeSet = context.parameterSet
        guard activeSet.source == .optimized,
              let previousID = activeSet.previousParameterSetID,
              let previousSet = try await database.fetchFSRSParameterSet(id: previousID)
        else { return false }

        let runs = try await database.fetchFSRSOptimizationRuns(limit: nil)
        if runs.contains(where: {
            $0.candidateParameterSetID == activeSet.id
                && ($0.decision == .probationCompleted || $0.decision == .rolledBack)
        }) {
            return false
        }

        let previous = FSRSScheduler.Parameters(
            weights: previousSet.weights,
            requestRetention: context.preset.desiredRetention,
            maximumInterval: context.preset.maximumIntervalDays
        )
        let probationStartedAt = max(activeSet.createdAt, context.preset.updatedAt)
        let allComparison = promotionObservations(
            logs: logs,
            active: context.parameters,
            defaults: previous,
            candidate: previous
        )
        let probation = allComparison.filter { $0.reviewedAt > probationStartedAt }
        let elapsedDays = max(0, Int(now.timeIntervalSince(probationStartedAt) / 86_400))
        guard evidenceOverride != nil || probation.count >= 100 || elapsedDays >= 30 else {
            return false
        }

        let comparison = policy.metrics(
            observations: probation,
            desiredRetention: context.preset.desiredRetention
        )
        let replay = promotionObservations(
            logs: logs,
            active: context.parameters,
            defaults: context.parameters,
            candidate: context.parameters
        )
        let invariants = candidateInvariants(
            parameters: context.parameters,
            logs: logs,
            candidateObservations: replay
        )
        let recalled = probation.lazy.filter(\.recalled).count
        let probationIDs = Set(probation.map(\.id))
        let prior = allComparison.filter { $0.reviewedAt <= probationStartedAt }
        let priorIDs = Set(prior.map(\.id))
        let onTimeLogs = logs.filter {
            probationIDs.contains($0.id)
                && $0.scheduledDays > 0
                && $0.elapsedDays <= $0.scheduledDays + (1 / 86_400)
        }
        let onTimeRecalled = onTimeLogs.lazy.filter { $0.rating != .again }.count
        let probationDays = max(1, Set(probation.map(\.studyDay)).count)
        let priorDays = max(1, Set(prior.map(\.studyDay)).count)
        let probationSecondsPerDay = Double(logs.lazy.filter {
            probationIDs.contains($0.id)
        }.reduce(0) { $0 + max(0, $1.durationMs) }) / 1_000 / Double(probationDays)
        let priorSecondsPerDay = Double(logs.lazy.filter {
            priorIDs.contains($0.id)
        }.reduce(0) { $0 + max(0, $1.durationMs) }) / 1_000 / Double(priorDays)
        let reviewTimeRatio = priorSecondsPerDay > 0
            ? probationSecondsPerDay / priorSecondsPerDay
            : 1
        let probationLapseRate = Double(probation.count - recalled) / Double(max(1, probation.count))
        let priorLapseRate = Double(prior.lazy.filter { !$0.recalled }.count)
            / Double(max(1, prior.count))
        let computedEvidence = FSRSProbationEvidence(
            elapsedDays: elapsedDays,
            observedTargets: probation.count,
            studyDays: probationDays,
            candidateMinusPreviousLogLoss: comparison.active.logLoss
                - comparison.candidate.logLoss,
            onTimeRecallRate: onTimeLogs.isEmpty
                ? 1
                : Double(onTimeRecalled) / Double(onTimeLogs.count),
            desiredRetention: context.preset.desiredRetention,
            reviewTimeRatio: reviewTimeRatio,
            lapseImproved: probationLapseRate < priorLapseRate,
            invariantOrReplayFailure: !invariants.allSatisfied
        )
        let evidence = evidenceOverride ?? computedEvidence
        let disposition = policy.probationDisposition(evidence: evidence)
        guard disposition != .continueProbation else { return false }

        let reason: String
        let decision: FSRSOptimizationDecision
        switch disposition {
        case .continueProbation:
            return false
        case .complete:
            reason = "probationCompleted"
            decision = .probationCompleted
        case let .rollback(value):
            reason = "probationRollback.\(value)"
            decision = .rolledBack
        }
        var probationMetrics = [
            "probation.logLossDelta": evidence.candidateMinusPreviousLogLoss,
            "probation.recallRate": evidence.onTimeRecallRate,
        ]
        if comparison.active.logLoss.isFinite {
            probationMetrics["probation.activeLogLoss"] = comparison.active.logLoss
        }
        if comparison.candidate.logLoss.isFinite {
            probationMetrics["probation.previousLogLoss"] = comparison.candidate.logLoss
        }
        let run = FSRSOptimizationRun(
            presetID: context.preset.id,
            startedAt: now,
            completedAt: now,
            trainingCutoff: logs.map(\.reviewedAt).max() ?? now,
            inputFingerprint: optimizationInputFingerprint(logs),
            eligibleTargetCount: probation.count,
            distinctCardCount: Set(probation.map(\.cardID)).count,
            failureCount: probation.count - recalled,
            studyDayCount: evidence.studyDays,
            foldCount: 0,
            metrics: probationMetrics.filter { $0.value.isFinite },
            decision: decision,
            reason: reason,
            candidateParameterSetID: activeSet.id
        )
        switch disposition {
        case .complete:
            try await database.insertFSRSOptimizationRun(run)
        case .rollback:
            try await database.persistFSRSProbationRollback(
                run: run,
                previousParameterSetID: previousID,
                now: now
            )
            fsrsParameters = previous
        case .continueProbation:
            break
        }
        return true
    }

    private func optimizationLogPrefix(
        _ logs: [ReviewLog],
        throughTargetID targetID: UUID
    ) -> [ReviewLog] {
        let ordered = logs.sorted(by: promotionLogChronological)
        guard let targetIndex = ordered.firstIndex(where: { $0.id == targetID }) else {
            return []
        }
        return Array(ordered.prefix(through: targetIndex))
    }

    private func heldOptimizationRun(
        eligibility: FSRSPromotionEligibility,
        startedAt: Date,
        completedAt: Date,
        logs: [ReviewLog],
        fingerprint: String,
        foldCount: Int,
        reason: String
    ) -> FSRSOptimizationRun {
        FSRSOptimizationRun(
            presetID: SchedulerPersistenceConstants.sharedPresetID,
            startedAt: startedAt,
            completedAt: completedAt,
            trainingCutoff: logs.map(\.reviewedAt).max() ?? completedAt,
            inputFingerprint: fingerprint,
            eligibleTargetCount: eligibility.targetCount,
            distinctCardCount: eligibility.distinctCardCount,
            failureCount: eligibility.failureCount,
            studyDayCount: eligibility.studyDayCount,
            foldCount: foldCount,
            decision: .held,
            reason: reason,
            candidateParameterSetID: nil
        )
    }

    private func promotionObservations(
        logs: [ReviewLog],
        active: FSRSScheduler.Parameters,
        defaults: FSRSScheduler.Parameters,
        candidate: FSRSScheduler.Parameters
    ) -> [FSRSPromotionObservation] {
        let grouped = Dictionary(grouping: logs, by: \.cardID)
        var observations: [FSRSPromotionObservation] = []
        for cardID in grouped.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            let history = (grouped[cardID] ?? []).sorted(by: promotionLogChronological)
            guard history.first?.phaseBefore == .new else { continue }
            let activeScheduler = LearningScheduler(parameters: active)
            let defaultScheduler = LearningScheduler(parameters: defaults)
            let candidateScheduler = LearningScheduler(parameters: candidate)
            let activeFSRS = FSRSScheduler(parameters: active)
            let defaultFSRS = FSRSScheduler(parameters: defaults)
            let candidateFSRS = FSRSScheduler(parameters: candidate)
            var activeMemory = MemoryState.new(due: history[0].reviewedAt)
            var defaultMemory = activeMemory
            var candidateMemory = activeMemory
            var previous: Date?
            for log in history {
                let elapsed = FSRSScheduler.elapsedModelDays(from: previous, to: log.reviewedAt)
                if previous != nil, elapsed > 0 {
                    observations.append(FSRSPromotionObservation(
                        id: log.id,
                        cardID: cardID,
                        reviewedAt: log.reviewedAt,
                        sequence: log.sequence,
                        elapsedDays: elapsed,
                        recalled: log.rating != .again,
                        activeProbability: activeFSRS.retrievability(of: activeMemory, asOf: log.reviewedAt),
                        defaultProbability: defaultFSRS.retrievability(of: defaultMemory, asOf: log.reviewedAt),
                        candidateProbability: candidateFSRS.retrievability(of: candidateMemory, asOf: log.reviewedAt)
                    ))
                }
                activeMemory = activeScheduler.schedule(activeMemory, rating: log.rating, now: log.reviewedAt)
                defaultMemory = defaultScheduler.schedule(defaultMemory, rating: log.rating, now: log.reviewedAt)
                candidateMemory = candidateScheduler.schedule(candidateMemory, rating: log.rating, now: log.reviewedAt)
                previous = log.reviewedAt
            }
        }
        return observations.sorted(by: promotionChronological)
    }

    private func candidateInvariants(
        parameters: FSRSScheduler.Parameters,
        logs: [ReviewLog],
        candidateObservations: [FSRSPromotionObservation]
    ) -> FSRSCandidateInvariants {
        let finite = parameters.weights.count == 21 && parameters.weights.allSatisfy(\.isFinite)
        let withinBounds = parameters.weights.count == FSRSScheduler.Parameters.weightBounds.count
            && zip(parameters.weights, FSRSScheduler.Parameters.weightBounds).allSatisfy {
                $0.0 >= $0.1.lower && $0.0 <= $0.1.upper
            }
        let monotonic = parameters.weights.count >= 4
            && zip(parameters.weights.prefix(3), parameters.weights.dropFirst().prefix(3))
                .allSatisfy { $0 <= $1 }
        let scheduler = LearningScheduler(parameters: parameters)
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let initial = MemoryState.new(due: instant)
        let passing = [ReviewRating.hard, .good, .easy].map {
            scheduler.schedule(initial, rating: $0, now: instant).due
        }
        let ordered = passing[0] <= passing[1] && passing[1] <= passing[2]
        let replayed = promotionObservations(
            logs: logs,
            active: parameters,
            defaults: parameters,
            candidate: parameters
        )
        return FSRSCandidateInvariants(
            finiteParameters: finite,
            withinCanonicalBounds: withinBounds,
            coupledConstraintsSatisfied: FSRSScheduler.Parameters.sanitizedWeights(parameters.weights)
                == parameters.weights,
            monotonicInitialStability: monotonic,
            orderedPassingIntervals: ordered,
            deterministicReplay: replayed.map(\.candidateProbability)
                == candidateObservations.map(\.candidateProbability)
        )
    }

    private func workloadProjection(
        logs: [ReviewLog],
        active: FSRSScheduler.Parameters,
        candidate: FSRSScheduler.Parameters
    ) -> FSRSWorkloadProjection {
        let grouped = Dictionary(grouping: logs, by: \.cardID)
        var ratios: [Double] = []
        for history in grouped.values {
            let sorted = history.sorted(by: promotionLogChronological)
            guard sorted.first?.phaseBefore == .new else { continue }
            var activeMemory = MemoryState.new(due: sorted[0].reviewedAt)
            var candidateMemory = activeMemory
            let activeScheduler = LearningScheduler(parameters: active)
            let candidateScheduler = LearningScheduler(parameters: candidate)
            for log in sorted {
                activeMemory = activeScheduler.schedule(activeMemory, rating: log.rating, now: log.reviewedAt)
                candidateMemory = candidateScheduler.schedule(candidateMemory, rating: log.rating, now: log.reviewedAt)
            }
            let activeInterval = FSRSScheduler(parameters: active)
                .rawIntervalDays(forStability: activeMemory.stability)
            let candidateInterval = FSRSScheduler(parameters: candidate)
                .rawIntervalDays(forStability: candidateMemory.stability)
            if activeInterval > 0, activeInterval.isFinite, candidateInterval.isFinite {
                ratios.append(candidateInterval / activeInterval)
            }
        }
        guard !ratios.isEmpty else {
            return FSRSWorkloadProjection(
                p95GoodIntervalRatio: .infinity,
                projectedThirtyDayWorkloadChange: .infinity
            )
        }
        ratios.sort()
        let p95 = ratios[min(ratios.count - 1, Int(Double(ratios.count - 1) * 0.95))]
        let workload = ratios.reduce(0) { $0 + (1 / max($1, 1e-9)) } / Double(ratios.count) - 1
        return FSRSWorkloadProjection(
            p95GoodIntervalRatio: p95,
            projectedThirtyDayWorkloadChange: workload
        )
    }

    private func optimizationInputFingerprint(_ logs: [ReviewLog]) -> String {
        let input = logs.sorted(by: promotionLogChronological).map {
            "\($0.id.uuidString)|\($0.cardID.uuidString)|\($0.reviewedAt.timeIntervalSince1970)|\($0.rating.rawValue)|\($0.sequence ?? -1)"
        }.joined(separator: "\n")
        return SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func persistedPromotionMetrics(_ metrics: FSRSPromotionMetrics) -> [String: Double] {
        [
            "active.logLoss": metrics.active.logLoss,
            "defaults.logLoss": metrics.defaults.logLoss,
            "baseRate.logLoss": metrics.empiricalBaseRate.logLoss,
            "candidate.logLoss": metrics.candidate.logLoss,
            "candidate.brier": metrics.candidate.brierScore,
            "candidate.rmseBins": metrics.candidate.rmseBins,
            "candidate.targetCalibration": metrics.candidate.nearTargetCalibrationError,
            "candidate.logLossRegressionUpper95": metrics.logLossRegressionUpper95,
        ].filter { $0.value.isFinite }
    }

    private func promotionLogChronological(_ lhs: ReviewLog, _ rhs: ReviewLog) -> Bool {
        if lhs.reviewedAt != rhs.reviewedAt { return lhs.reviewedAt < rhs.reviewedAt }
        if let left = lhs.sequence, let right = rhs.sequence, left != right { return left < right }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func promotionChronological(
        _ lhs: FSRSPromotionObservation,
        _ rhs: FSRSPromotionObservation
    ) -> Bool {
        if lhs.reviewedAt != rhs.reviewedAt { return lhs.reviewedAt < rhs.reviewedAt }
        if let left = lhs.sequence, let right = rhs.sequence, left != right {
            return left < right
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
