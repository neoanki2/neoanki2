import Foundation

public extension ItemStore {
    func schedulingHealthSnapshot() async throws -> SchedulingHealthSnapshot {
        try await database.schedulerHealthSnapshot()
    }

    func schedulerPreset() async throws -> SchedulerPreset {
        guard let preset = try await database.fetchSchedulerPreset(
            id: SchedulerPersistenceConstants.sharedPresetID
        ) else {
            throw DatabaseError.decodingFailed
        }
        return preset
    }

    func saveSchedulerPreset(_ preset: SchedulerPreset) async throws {
        try await database.saveSchedulerPreset(preset)
    }

    func saveFSRSParameterSet(_ parameterSet: FSRSParameterSet) async throws {
        try await database.insertFSRSParameterSet(parameterSet)
    }

    func fsrsParameterSets() async throws -> [FSRSParameterSet] {
        try await database.fetchFSRSParameterSets()
    }

    func saveFSRSOptimizationRun(_ run: FSRSOptimizationRun) async throws {
        try await database.insertFSRSOptimizationRun(run)
    }

    func fsrsOptimizationRuns(limit: Int? = nil) async throws -> [FSRSOptimizationRun] {
        try await database.fetchFSRSOptimizationRuns(limit: limit)
    }

    /// Selects the newest immutable population-default record. Scheduling
    /// integration is responsible for inserting that pinned upstream record
    /// during engine bootstrap.
    func restoreDefaultScheduling(now: Date = .now) async throws {
        guard let defaults = try await database.fetchFSRSParameterSets().first(where: {
            $0.source == .populationDefault
        }) else {
            throw DatabaseError.executeFailed(
                "No versioned population-default FSRS parameter set is installed."
            )
        }
        try await database.activateFSRSParameterSet(
            defaults.id,
            presetID: SchedulerPersistenceConstants.sharedPresetID,
            now: now
        )
        fsrsParameters = FSRSScheduler.Parameters(
            weights: defaults.weights,
            requestRetention: (try await schedulerPreset()).desiredRetention,
            maximumInterval: (try await schedulerPreset()).maximumIntervalDays
        )
    }

    /// Moves only the preset's active pointer. Existing due dates are kept;
    /// callers replay a card lazily before its next model update.
    func rollbackScheduling(to parameterSetID: UUID, now: Date = .now) async throws {
        try await database.activateFSRSParameterSet(
            parameterSetID,
            presetID: SchedulerPersistenceConstants.sharedPresetID,
            now: now
        )
        guard let selected = try await database.fetchFSRSParameterSet(id: parameterSetID) else {
            throw DatabaseError.decodingFailed
        }
        let preset = try await schedulerPreset()
        fsrsParameters = FSRSScheduler.Parameters(
            weights: selected.weights,
            requestRetention: preset.desiredRetention,
            maximumInterval: preset.maximumIntervalDays
        )
    }

    func beginSchedulerMigration(
        fromModelVersion: String,
        toModelVersion: String,
        now: Date = .now
    ) async throws -> UUID {
        try await database.beginSchedulerMigration(
            fromModelVersion: fromModelVersion,
            toModelVersion: toModelVersion,
            now: now
        )
    }

    func completeSchedulerMigration(
        id: UUID,
        replayedCards: [CardSchedulingSnapshot],
        resetCardIDs: [UUID],
        activeParameterSetID: UUID,
        now: Date = .now
    ) async throws {
        try await database.completeSchedulerMigration(
            id: id,
            replayedCards: replayedCards,
            resetCardIDs: resetCardIDs,
            activeParameterSetID: activeParameterSetID,
            now: now
        )
    }

    func rollbackSchedulerMigration(id: UUID, now: Date = .now) async throws {
        try await database.rollbackSchedulerMigration(id: id, now: now)
    }
}

extension ItemStore {
    struct ActiveSchedulingContext {
        let preset: SchedulerPreset
        let parameterSet: FSRSParameterSet
        let parameters: FSRSScheduler.Parameters
    }

    struct PreparedSchedulingReview {
        let card: Card
        let memoryBefore: MemoryState
        let memoryAfter: MemoryState
        let audit: ReviewSchedulingAudit?
    }

    /// Installs the pinned population defaults exactly once and never reads the
    /// mutable legacy scheduler row. Legacy data remains quarantined solely for
    /// diagnostics and rollback evidence.
    func ensureVersionedSchedulingBootstrap(now: Date) async throws {
        try await database.quarantineLegacySchedulerParameters(now: now)
        let defaultID = SchedulerPersistenceConstants.populationDefaultParameterSetID
        if try await database.fetchFSRSParameterSet(id: defaultID) == nil {
            try await database.insertFSRSParameterSet(FSRSParameterSet(
                id: defaultID,
                weights: FSRSScheduler.Parameters.defaultWeights,
                modelVersion: SchedulerPersistenceConstants.memoryModelVersion,
                upstreamCommit: SchedulerPersistenceConstants.upstreamCommit,
                sourceChecksum: SchedulerPersistenceConstants.sourceChecksum,
                fixtureChecksum: SchedulerPersistenceConstants.fixtureChecksum,
                source: .populationDefault,
                createdAt: now
            ))
        }
        guard let preset = try await database.fetchSchedulerPreset(
            id: SchedulerPersistenceConstants.sharedPresetID
        ) else {
            throw DatabaseError.decodingFailed
        }
        let activeSet: FSRSParameterSet?
        if let activeID = preset.activeParameterSetID {
            activeSet = try await database.fetchFSRSParameterSet(id: activeID)
        } else {
            activeSet = nil
        }
        if activeSet == nil {
            try await database.activateFSRSParameterSet(
                defaultID,
                presetID: preset.id,
                now: now
            )
        }
        let context = try await activeSchedulingContext()
        fsrsParameters = context.parameters
    }

    func activeSchedulingContext() async throws -> ActiveSchedulingContext {
        guard let preset = try await database.fetchSchedulerPreset(
            id: SchedulerPersistenceConstants.sharedPresetID
        ), let parameterSetID = preset.activeParameterSetID,
              let parameterSet = try await database.fetchFSRSParameterSet(id: parameterSetID)
        else {
            throw DatabaseError.decodingFailed
        }
        return ActiveSchedulingContext(
            preset: preset,
            parameterSet: parameterSet,
            parameters: FSRSScheduler.Parameters(
                weights: parameterSet.weights,
                requestRetention: preset.desiredRetention,
                maximumInterval: preset.maximumIntervalDays
            )
        )
    }

    /// One-time exact migration for cards whose memory predates versioned
    /// provenance. Future model changes use lazy replay instead.
    func migrateLegacyCardSchedulingIfNeeded(now: Date) async throws {
        guard schedulerOverride == nil else { return }
        guard try await database.supportsVersionedCardReplay() else { return }
        let cards = try await database.fetchAllCards().filter {
            $0.memoryModelVersion == nil
        }
        guard !cards.isEmpty else { return }
        let context = try await activeSchedulingContext()
        let migrationID = try await database.beginSchedulerMigration(
            fromModelVersion: "legacy-homegrown-fsrs",
            toModelVersion: context.parameterSet.modelVersion,
            now: now
        )
        var replayed: [CardSchedulingSnapshot] = []
        var reset: [UUID] = []
        for card in cards {
            let logs = try await database.fetchActiveReviewLogs(cardID: card.id)
            if let memory = replayMemory(card: card, logs: logs, parameters: context.parameters) {
                replayed.append(CardSchedulingSnapshot(
                    cardID: card.id,
                    memory: memory,
                    memoryModelVersion: context.parameterSet.modelVersion,
                    memoryParameterSetID: context.parameterSet.id,
                    schedulingHistoryOrigin: card.schedulingHistoryOrigin
                ))
            } else {
                reset.append(card.id)
            }
        }
        try await database.completeSchedulerMigration(
            id: migrationID,
            replayedCards: replayed,
            resetCardIDs: reset,
            activeParameterSetID: context.parameterSet.id,
            now: now
        )
    }

    func cardReplayedForActiveScheduling(_ card: Card, now: Date) async throws -> Card {
        guard schedulerOverride == nil else { return card }
        let context = try await activeSchedulingContext()
        guard try await cardRequiresReplay(card, context: context) else {
            return card
        }
        let logs = try await database.fetchActiveReviewLogs(cardID: card.id)
        if let memory = replayMemory(card: card, logs: logs, parameters: context.parameters) {
            try await database.updateCardSchedulingMemory(
                card.id,
                memory: memory,
                modelVersion: context.parameterSet.modelVersion,
                parameterSetID: context.parameterSet.id
            )
        } else {
            try await database.resetCardSchedulingMemory(
                card.id,
                modelVersion: context.parameterSet.modelVersion,
                parameterSetID: context.parameterSet.id,
                historyOrigin: now
            )
        }
        guard let result = try await database.fetchCard(id: card.id) else {
            throw DatabaseError.cardNotFound(card.id)
        }
        return result
    }

    private func cardRequiresReplay(
        _ card: Card,
        context: ActiveSchedulingContext
    ) async throws -> Bool {
        if card.memoryModelVersion != context.parameterSet.modelVersion
            || card.memoryParameterSetID != context.parameterSet.id {
            return true
        }
        guard card.memory.reps > 0 else { return false }
        let policy = try await database.fetchLatestActiveReviewTimingPolicy(cardID: card.id)
        return policy.hasReview && policy.version != FSRSScheduler.elapsedPolicyIdentifier
    }

    func prepareSchedulingReview(
        card originalCard: Card,
        rating: ReviewRating,
        now: Date
    ) async throws -> PreparedSchedulingReview {
        if let schedulerOverride {
            let next = schedulerOverride.schedule(originalCard.memory, rating: rating, now: now)
            return PreparedSchedulingReview(
                card: originalCard,
                memoryBefore: originalCard.memory,
                memoryAfter: next,
                audit: nil
            )
        }
        let card = try await cardReplayedForActiveScheduling(originalCard, now: now)
        let context = try await activeSchedulingContext()
        fsrsParameters = context.parameters
        let fsrs = FSRSScheduler(parameters: context.parameters)
        let memoryBefore = card.memory
        let elapsedSeconds = max(
            0,
            memoryBefore.lastReview.map { now.timeIntervalSince($0) } ?? 0
        )
        let predicted = fsrs.retrievability(of: memoryBefore, asOf: now)
        let next = LearningScheduler(parameters: context.parameters).schedule(
            memoryBefore,
            rating: rating,
            now: now
        )
        let rawIntervalDays = fsrs.rawIntervalDays(forStability: next.stability)
        let operationalSeconds = max(0, Int(ceil(next.due.timeIntervalSince(now))))
        let constraintReason: String?
        if rating == .again {
            constraintReason = "immediate-repair-v1"
        } else if rawIntervalDays >= Double(context.preset.maximumIntervalDays) {
            constraintReason = "maximum-interval"
        } else {
            constraintReason = nil
        }
        let audit = ReviewSchedulingAudit(
            presetID: context.preset.id,
            deckIDAtReview: card.deckID,
            elapsedSeconds: elapsedSeconds,
            elapsedModelDays: FSRSScheduler.elapsedModelDays(
                from: memoryBefore.lastReview,
                to: now
            ),
            parameterSetID: context.parameterSet.id,
            memoryAfter: next,
            predictedRetrievability: predicted,
            rawIntervalDays: rawIntervalDays,
            operationalIntervalSeconds: operationalSeconds,
            modelVersion: context.parameterSet.modelVersion,
            timingPolicyVersion: FSRSScheduler.elapsedPolicyIdentifier,
            intervalPolicyVersion: FSRSScheduler.intervalPolicyIdentifier,
            finalDueAt: next.due,
            constraintReason: constraintReason
        )
        return PreparedSchedulingReview(
            card: card,
            memoryBefore: memoryBefore,
            memoryAfter: next,
            audit: audit
        )
    }

    /// Computes all four choices against the active model without changing
    /// card state. This intentionally mirrors lazy replay used by submission.
    func detailedReviewPreviews(
        card: Card,
        now: Date
    ) async throws -> [ReviewRating: ReviewSchedulePreviewDetail] {
        if let schedulerOverride {
            return Dictionary(uniqueKeysWithValues: ReviewRating.allCases.map {
                let next = schedulerOverride.schedule(card.memory, rating: $0, now: now)
                return ($0, ReviewSchedulePreviewDetail(
                    rating: $0,
                    memoryBefore: card.memory,
                    memoryAfter: next,
                    predictedRetrievability: 1,
                    rawIntervalDays: max(0, next.due.timeIntervalSince(now) / 86_400),
                    operationalIntervalSeconds: max(0, Int(ceil(next.due.timeIntervalSince(now)))),
                    desiredRetention: FSRSScheduler.Parameters.defaultRequestRetention,
                    maximumIntervalDays: FSRSScheduler.Parameters.defaultMaximumInterval,
                    presetID: nil,
                    parameterSetID: nil,
                    modelVersion: "scheduler-override",
                    timingPolicyVersion: FSRSScheduler.elapsedPolicyIdentifier,
                    intervalPolicyVersion: FSRSScheduler.intervalPolicyIdentifier,
                    finalDueAt: next.due,
                    constraintReason: $0 == .again ? "immediate-repair-v1" : nil
                ))
            })
        }
        let context = try await activeSchedulingContext()
        let memory: MemoryState
        let requiresReplay = try await cardRequiresReplay(card, context: context)
        if !requiresReplay {
            memory = card.memory
        } else {
            let logs = try await database.fetchActiveReviewLogs(cardID: card.id)
            memory = replayMemory(card: card, logs: logs, parameters: context.parameters)
                ?? .new(due: now)
        }
        let scheduler = LearningScheduler(parameters: context.parameters)
        let fsrs = FSRSScheduler(parameters: context.parameters)
        let retrievability = fsrs.retrievability(of: memory, asOf: now)
        return Dictionary(uniqueKeysWithValues: ReviewRating.allCases.map {
            let next = scheduler.schedule(memory, rating: $0, now: now)
            let raw = fsrs.rawIntervalDays(forStability: next.stability)
            let constraint: String? = if $0 == .again {
                "immediate-repair-v1"
            } else if raw > Double(context.preset.maximumIntervalDays) {
                "maximum-interval"
            } else {
                nil
            }
            return ($0, ReviewSchedulePreviewDetail(
                rating: $0,
                memoryBefore: memory,
                memoryAfter: next,
                predictedRetrievability: retrievability,
                rawIntervalDays: raw,
                operationalIntervalSeconds: max(0, Int(ceil(next.due.timeIntervalSince(now)))),
                desiredRetention: context.preset.desiredRetention,
                maximumIntervalDays: context.preset.maximumIntervalDays,
                presetID: context.preset.id,
                parameterSetID: context.parameterSet.id,
                modelVersion: context.parameterSet.modelVersion,
                timingPolicyVersion: FSRSScheduler.elapsedPolicyIdentifier,
                intervalPolicyVersion: FSRSScheduler.intervalPolicyIdentifier,
                finalDueAt: next.due,
                constraintReason: constraint
            ))
        })
    }

    func previewSchedulingContext(
        card: Card,
        now: Date
    ) async throws -> [ReviewRating: MemoryState] {
        try await detailedReviewPreviews(card: card, now: now).mapValues(\.memoryAfter)
    }

    private func replayMemory(
        card: Card,
        logs: [ReviewLog],
        parameters: FSRSScheduler.Parameters
    ) -> MemoryState? {
        if logs.isEmpty {
            return card.memory.reps == 0 && card.memory.phase == .new ? card.memory : nil
        }
        guard logs.first?.phaseBefore == .new,
              logs.allSatisfy({ $0.cardID == card.id }),
              logs.count == card.memory.reps else { return nil }
        let scheduler = LearningScheduler(parameters: parameters)
        var memory = MemoryState.new(due: logs[0].reviewedAt)
        for log in logs {
            memory = scheduler.schedule(memory, rating: log.rating, now: log.reviewedAt)
        }
        return memory
    }
}
