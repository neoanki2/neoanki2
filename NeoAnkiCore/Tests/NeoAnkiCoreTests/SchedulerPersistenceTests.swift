import Foundation
import Testing
@testable import NeoAnkiCore

private func schedulerPersistenceStore() async throws -> ItemStore {
    let fixture = try await schedulerPersistenceStoreWithURL()
    return fixture.store
}

private func schedulerPersistenceStoreWithURL() async throws -> (store: ItemStore, url: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-scheduler-persistence-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("test.sqlite")
    let store = try ItemStore(databaseURL: url)
    try await store.bootstrap()
    return (store, url)
}

private func createSchedulerPersistenceCard(
    in store: ItemStore,
    now: Date
) async throws -> Card {
    let itemType = try await store.defaultItemType()
    let item = Item(
        itemTypeID: itemType.id,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Q")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("A")),
        ]
    )
    try await store.createItem(item, now: now)
    return try #require(try await store.fetchDueCards(asOf: now).first?.card)
}

private func parameterSet(
    id: UUID = UUID(),
    source: FSRSParameterSource,
    previous: UUID? = nil,
    createdAt: Date
) -> FSRSParameterSet {
    FSRSParameterSet(
        id: id,
        weights: Array(repeating: source == .populationDefault ? 1 : 2, count: 21),
        modelVersion: SchedulerPersistenceConstants.memoryModelVersion,
        upstreamCommit: "6f5498f8dd1a95c781fcdd4448f28f16dd9e377d",
        sourceChecksum: String(repeating: "a", count: 64),
        fixtureChecksum: String(repeating: "b", count: 64),
        source: source,
        previousParameterSetID: previous,
        createdAt: createdAt
    )
}

private func seedEligibleOptimizationHistory(
    in store: ItemStore,
    start: Date
) async throws -> Date {
    let template = try await createSchedulerPersistenceCard(in: store, now: start)
    let deltas = [1, 5, 40, 2]
    var latest = start
    for cardIndex in 0 ..< 100 {
        let cardID = cardIndex == 0 ? template.id : UUID()
        if cardIndex != 0 {
            try await store.applySynchronizedCard(Card(
                id: cardID,
                itemID: template.itemID,
                templateID: template.templateID,
                skill: template.skill,
                memory: .new(due: start)
            ))
        }
        var reviewedAt = start.addingTimeInterval(Double(cardIndex % 40) * 86_400)
        try await store.applySynchronizedReview(ReviewLog(
            cardID: cardID,
            reviewedAt: reviewedAt,
            rating: .good,
            elapsedDays: 0,
            scheduledDays: 0,
            phaseBefore: .new,
            durationMs: 500
        ))
        for (targetIndex, delta) in deltas.enumerated() {
            reviewedAt = reviewedAt.addingTimeInterval(Double(delta) * 86_400)
            latest = max(latest, reviewedAt)
            try await store.applySynchronizedReview(ReviewLog(
                cardID: cardID,
                reviewedAt: reviewedAt,
                rating: targetIndex.isMultiple(of: 3) ? .again : .good,
                elapsedDays: Double(delta),
                scheduledDays: Double(delta),
                phaseBefore: .review,
                durationMs: 500
            ))
        }
    }
    return latest
}

@Test func versionedSchedulerRecordsDriveHealthAndRecovery() async throws {
    let store = try await schedulerPersistenceStore()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let defaults = parameterSet(source: .populationDefault, createdAt: now)
    let optimized = parameterSet(
        source: .optimized,
        previous: defaults.id,
        createdAt: now.addingTimeInterval(1)
    )
    try await store.saveFSRSParameterSet(defaults)
    try await store.saveFSRSParameterSet(optimized)
    try await store.rollbackScheduling(to: optimized.id, now: now)

    let run = FSRSOptimizationRun(
        presetID: SchedulerPersistenceConstants.sharedPresetID,
        startedAt: now,
        completedAt: now.addingTimeInterval(2),
        trainingCutoff: now,
        inputFingerprint: "history-v1",
        eligibleTargetCount: 400,
        distinctCardCount: 100,
        failureCount: 30,
        studyDayCount: 30,
        foldCount: 3,
        metrics: ["logLoss": 0.4],
        decision: .promoted,
        candidateParameterSetID: optimized.id
    )
    try await store.saveFSRSOptimizationRun(run)

    var health = try await store.schedulingHealthSnapshot()
    #expect(health.activeParameterSet?.id == optimized.id)
    #expect(health.lastOptimizationRun?.id == run.id)
    #expect(health.rollbackParameterSetIDs.contains(defaults.id))
    #expect(health.desiredRetention == 0.9)
    #expect(health.optimizerParityVerified == SchedulerPersistenceConstants.optimizerParityVerified)

    try await store.restoreDefaultScheduling(now: now.addingTimeInterval(3))
    health = try await store.schedulingHealthSnapshot()
    #expect(health.activeParameterSet?.id == defaults.id)
    #expect(health.activeSource == .populationDefault)

    await #expect(throws: DatabaseError.self) {
        try await store.saveFSRSParameterSet(defaults)
    }
}

@Test func cardModelProvenanceSurvivesPersistenceAndSync() async throws {
    let store = try await schedulerPersistenceStore()
    var card = try await createSchedulerPersistenceCard(
        in: store,
        now: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let parameterID = UUID()
    card.memoryModelVersion = SchedulerPersistenceConstants.memoryModelVersion
    card.memoryParameterSetID = parameterID
    try await store.applySynchronizedCard(card)

    let loaded = try await store.card(id: card.id)
    #expect(loaded.memoryModelVersion == SchedulerPersistenceConstants.memoryModelVersion)
    #expect(loaded.memoryParameterSetID == parameterID)
}

@Test func bootstrapActivatesPinnedDefaultsAndGradeWritesCompleteAudit() async throws {
    let store = try await schedulerPersistenceStore()
    let health = try await store.schedulingHealthSnapshot()
    #expect(health.activeParameterSet?.id == SchedulerPersistenceConstants.populationDefaultParameterSetID)
    #expect(health.activeSource == .populationDefault)
    #expect(health.activeParameterSet?.weights == FSRSScheduler.Parameters.defaultWeights)
    #expect(health.activeParameterSet?.fixtureChecksum == SchedulerPersistenceConstants.fixtureChecksum)

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let card = try await createSchedulerPersistenceCard(in: store, now: now)
    let receipt = try await store.submitReviewWithReceipt(
        cardID: card.id,
        rating: .good,
        now: now,
        durationMs: 750
    )
    let log = try await store.reviewLog(id: receipt.reviewLogID)
    let audit = try #require(log.schedulingAudit)
    #expect(audit.presetID == SchedulerPersistenceConstants.sharedPresetID)
    #expect(audit.parameterSetID == SchedulerPersistenceConstants.populationDefaultParameterSetID)
    #expect(audit.elapsedSeconds == 0)
    #expect(audit.elapsedModelDays == 0)
    #expect(audit.memoryAfter == receipt.memory)
    #expect(audit.rawIntervalDays != nil)
    #expect(audit.operationalIntervalSeconds > 0)
    #expect(audit.modelVersion == SchedulerPersistenceConstants.memoryModelVersion)
    #expect(audit.timingPolicyVersion == FSRSScheduler.elapsedPolicyIdentifier)
    #expect(audit.intervalPolicyVersion == FSRSScheduler.intervalPolicyIdentifier)
    #expect(audit.finalDueAt == receipt.memory.due)

    let persisted = try await store.card(id: card.id)
    #expect(persisted.memoryModelVersion == SchedulerPersistenceConstants.memoryModelVersion)
    #expect(persisted.memoryParameterSetID == SchedulerPersistenceConstants.populationDefaultParameterSetID)
}

@Test func parameterChangeLazilyReplaysHistoryBeforeNextGrade() async throws {
    let store = try await schedulerPersistenceStore()
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let original = try await createSchedulerPersistenceCard(in: store, now: start)
    _ = try await store.submitReview(cardID: original.id, rating: .good, now: start)
    _ = try await store.submitReview(
        cardID: original.id,
        rating: .hard,
        now: start.addingTimeInterval(2 * 86_400)
    )
    let before = try await store.card(id: original.id)

    let candidate = parameterSet(
        source: .optimized,
        previous: SchedulerPersistenceConstants.populationDefaultParameterSetID,
        createdAt: start.addingTimeInterval(3 * 86_400)
    )
    try await store.saveFSRSParameterSet(candidate)
    try await store.rollbackScheduling(to: candidate.id, now: candidate.createdAt)
    #expect((try await store.card(id: original.id)).memoryParameterSetID != candidate.id)

    let receipt = try await store.submitReviewWithReceipt(
        cardID: original.id,
        rating: .good,
        now: start.addingTimeInterval(4 * 86_400)
    )
    let after = try await store.card(id: original.id)
    let log = try await store.reviewLog(id: receipt.reviewLogID)
    #expect(after.memory.reps == before.memory.reps + 1)
    #expect(after.memoryParameterSetID == candidate.id)
    #expect(log.schedulingAudit?.parameterSetID == candidate.id)
}

@Test func elapsedPolicyChangeLazilyReplaysLegacyHistoryBeforeNextGrade() async throws {
    let store = try await schedulerPersistenceStore()
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var card = try await createSchedulerPersistenceCard(in: store, now: start)
    let scheduler = LearningScheduler()
    let first = scheduler.schedule(.new(due: start), rating: .good, now: start)
    let secondAt = start.addingTimeInterval(21.5 * 3_600)

    var zeroElapsedInput = first
    zeroElapsedInput.lastReview = secondAt
    let legacyMemory = scheduler.schedule(zeroElapsedInput, rating: .good, now: secondAt)
    let continuousMemory = scheduler.schedule(first, rating: .good, now: secondAt)
    #expect(legacyMemory.stability != continuousMemory.stability)

    card.memory = legacyMemory
    card.memoryModelVersion = SchedulerPersistenceConstants.memoryModelVersion
    card.memoryParameterSetID = SchedulerPersistenceConstants.populationDefaultParameterSetID
    try await store.applySynchronizedCard(card)
    try await store.applySynchronizedReview(ReviewLog(
        cardID: card.id,
        reviewedAt: start,
        rating: .good,
        elapsedDays: 0,
        scheduledDays: 0,
        phaseBefore: .new,
        durationMs: 500
    ))
    try await store.applySynchronizedReview(ReviewLog(
        cardID: card.id,
        reviewedAt: secondAt,
        rating: .good,
        elapsedDays: 21.5 / 24,
        scheduledDays: 21.5 / 24,
        phaseBefore: .review,
        durationMs: 500
    ))

    let thirdAt = secondAt.addingTimeInterval(86_400)
    let expected = scheduler.schedule(continuousMemory, rating: .good, now: thirdAt)
    let actual = try await store.submitReview(
        cardID: card.id,
        rating: .good,
        now: thirdAt
    )

    #expect(actual == expected)
    #expect((try await store.card(id: card.id)).memory == expected)
}

@Test func migrationResetPreservesEvidenceAndRollbackRestoresHistoryOrigin() async throws {
    let store = try await schedulerPersistenceStore()
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let card = try await createSchedulerPersistenceCard(in: store, now: start)
    _ = try await store.submitReview(cardID: card.id, rating: .good, now: start)
    let before = try await store.card(id: card.id)
    #expect(before.schedulingHistoryOrigin == nil)
    #expect(try await store.rawReviewLogCount(for: card.id) == 1)
    #expect(try await store.activeReviewLogCount(for: card.id) == 1)

    let resetAt = start.addingTimeInterval(10 * 86_400)
    let migrationID = try await store.beginSchedulerMigration(
        fromModelVersion: SchedulerPersistenceConstants.memoryModelVersion,
        toModelVersion: "test-reset",
        now: resetAt
    )
    try await store.completeSchedulerMigration(
        id: migrationID,
        replayedCards: [],
        resetCardIDs: [card.id],
        activeParameterSetID: SchedulerPersistenceConstants.populationDefaultParameterSetID,
        now: resetAt
    )
    let reset = try await store.card(id: card.id)
    #expect(reset.memory.reps == 0)
    #expect(reset.schedulingHistoryOrigin == resetAt)
    #expect(try await store.rawReviewLogCount(for: card.id) == 1)
    #expect(try await store.activeReviewLogCount(for: card.id) == 0)
    #expect(try await store.schedulingHealthSnapshot().latestMigration?.status == .completed)

    try await store.rollbackSchedulerMigration(id: migrationID, now: resetAt.addingTimeInterval(1))
    let restored = try await store.card(id: card.id)
    #expect(restored.memory == before.memory)
    #expect(restored.schedulingHistoryOrigin == before.schedulingHistoryOrigin)
    #expect(try await store.rawReviewLogCount(for: card.id) == 1)
    #expect(try await store.activeReviewLogCount(for: card.id) == 1)
    #expect(try await store.schedulingHealthSnapshot().latestMigration?.status == .rolledBack)
}

@Test func previewAfterParameterChangeIsReadOnlyAndMatchesSubmission() async throws {
    let store = try await schedulerPersistenceStore()
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let original = try await createSchedulerPersistenceCard(in: store, now: start)
    _ = try await store.submitReview(cardID: original.id, rating: .good, now: start)
    _ = try await store.submitReview(
        cardID: original.id,
        rating: .hard,
        now: start.addingTimeInterval(2 * 86_400)
    )
    let candidate = parameterSet(
        source: .optimized,
        previous: SchedulerPersistenceConstants.populationDefaultParameterSetID,
        createdAt: start.addingTimeInterval(3 * 86_400)
    )
    try await store.saveFSRSParameterSet(candidate)
    try await store.rollbackScheduling(to: candidate.id, now: candidate.createdAt)
    let beforePreview = try await store.card(id: original.id)
    let reviewAt = start.addingTimeInterval(4 * 86_400)

    let previews = try await store.reviewPreviews(cardID: original.id, now: reviewAt)
    let details = try await store.reviewPreviewDetails(cardID: original.id, now: reviewAt)
    let goodDetail = try #require(details[.good])
    let afterPreview = try await store.card(id: original.id)
    #expect(afterPreview == beforePreview)
    #expect(goodDetail.memoryAfter == previews[.good])
    #expect(goodDetail.desiredRetention == 0.9)
    #expect(goodDetail.maximumIntervalDays == 36_500)
    #expect(goodDetail.parameterSetID == candidate.id)
    #expect(goodDetail.rawIntervalDays == FSRSScheduler(
        parameters: FSRSScheduler.Parameters(
            weights: candidate.weights,
            requestRetention: 0.9,
            maximumInterval: 36_500
        )
    ).rawIntervalDays(forStability: goodDetail.memoryAfter.stability))
    #expect(goodDetail.operationalIntervalSeconds == Int(ceil(
        goodDetail.finalDueAt.timeIntervalSince(reviewAt)
    )))

    let submitted = try await store.submitReview(
        cardID: original.id,
        rating: .good,
        now: reviewAt
    )
    #expect(submitted == previews[.good])
}

@Test func parityFailureIsHeldWithoutActivationAndPersistsAcrossCadence() async throws {
    let fixture = try await schedulerPersistenceStoreWithURL()
    let store = fixture.store
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let now = try await seedEligibleOptimizationHistory(in: store, start: start)
    let activeBefore = try #require(
        try await store.schedulingHealthSnapshot().activeParameterSet?.id
    )

    await #expect(throws: FSRSOptimizationError.optimizerParityNotVerified) {
        try await store.runAutomaticFSRSOptimization(
            minimumObservations: 400,
            now: now,
            optimizerParityVerified: false
        )
    }
    var health = try await store.schedulingHealthSnapshot()
    #expect(health.activeParameterSet?.id == activeBefore)
    #expect(health.lastOptimizationRun?.decision == .held)
    #expect(health.lastOptimizationRun?.candidateParameterSetID == nil)
    #expect(try await store.fsrsParameterSets().count == 1)

    let skipped = try await store.runAutomaticFSRSOptimization(
        minimumObservations: 400,
        now: now.addingTimeInterval(86_400),
        optimizerParityVerified: false
    )
    #expect(skipped == nil)
    #expect(try await store.fsrsOptimizationRuns().count == 1)

    let reopened = try ItemStore(databaseURL: fixture.url)
    try await reopened.bootstrap()
    health = try await reopened.schedulingHealthSnapshot()
    #expect(health.activeParameterSet?.id == activeBefore)
    #expect(health.lastOptimizationRun?.decision == .held)
}

@Test func probationRegressionAtomicallyRollsBackAndPersistsReason() async throws {
    let store = try await schedulerPersistenceStore()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let previousID = try #require(
        try await store.schedulingHealthSnapshot().activeParameterSet?.id
    )
    let candidate = parameterSet(
        source: .optimized,
        previous: previousID,
        createdAt: now.addingTimeInterval(-31 * 86_400)
    )
    try await store.saveFSRSParameterSet(candidate)
    try await store.rollbackScheduling(to: candidate.id, now: candidate.createdAt)

    let result = try await store.runAutomaticFSRSOptimization(
        minimumObservations: 400,
        now: now,
        probationEvidenceOverride: FSRSProbationEvidence(
            elapsedDays: 31,
            observedTargets: 100,
            studyDays: 10,
            candidateMinusPreviousLogLoss: 0.02,
            onTimeRecallRate: 0.9,
            desiredRetention: 0.9,
            reviewTimeRatio: 1,
            lapseImproved: true,
            invariantOrReplayFailure: false
        )
    )
    #expect(result == nil)
    let health = try await store.schedulingHealthSnapshot()
    #expect(health.activeParameterSet?.id == previousID)
    #expect(health.lastOptimizationRun?.decision == .rolledBack)
    #expect(health.lastOptimizationRun?.reason == "probationRollback.logLossRegression")
    #expect(health.lastOptimizationRun?.candidateParameterSetID == candidate.id)
}

@Test func legacyReviewLogJSONDecodesWithoutSchedulingAudit() throws {
    struct LegacyReviewLog: Codable {
        let id: UUID
        let cardID: UUID
        let reviewedAt: Date
        let rating: ReviewRating
        let elapsedDays: Double
        let scheduledDays: Double
        let phaseBefore: Phase
        let durationMs: Int
        let sequence: Int64?
    }
    let legacy = LegacyReviewLog(
        id: UUID(), cardID: UUID(), reviewedAt: .now, rating: .good,
        elapsedDays: 1, scheduledDays: 1, phaseBefore: .review,
        durationMs: 500, sequence: 9
    )
    let decoded = try JSONDecoder().decode(
        ReviewLog.self,
        from: JSONEncoder().encode(legacy)
    )
    #expect(decoded.id == legacy.id)
    #expect(decoded.schedulingAudit == nil)
}
