import Foundation
import Testing
@testable import NeoAnkiCore

@Test func optimizerRejectsSparseHistory() {
    let logs = syntheticLogs(cardCount: 3, reviewsPerCard: 4)
    let optimizer = FSRSOptimizer(minimumObservations: 20)

    #expect(throws: FSRSOptimizationError.insufficientData(required: 20, available: 9)) {
        try optimizer.optimize(logs: logs)
    }
}

@Test func optimizerRejectsHistoryMissingTheNewCardReview() {
    let cardID = UUID()
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let logs = [
        ReviewLog(
            cardID: cardID,
            reviewedAt: start,
            rating: .good,
            elapsedDays: 7,
            scheduledDays: 7,
            phaseBefore: .review,
            durationMs: 500
        ),
        ReviewLog(
            cardID: cardID,
            reviewedAt: start.addingTimeInterval(7 * 86_400),
            rating: .good,
            elapsedDays: 7,
            scheduledDays: 7,
            phaseBefore: .review,
            durationMs: 500
        ),
    ]

    #expect(throws: FSRSOptimizationError.insufficientData(required: 1, available: 0)) {
        try FSRSOptimizer(minimumObservations: 1).optimize(logs: logs)
    }
}

@Test func optimizerIgnoresMalformedAndNonFiniteHistory() throws {
    var logs = syntheticLogs(cardCount: 8, reviewsPerCard: 4)
    logs.append(
        ReviewLog(
            cardID: UUID(),
            reviewedAt: Date(timeIntervalSinceReferenceDate: .nan),
            rating: .again,
            elapsedDays: .nan,
            scheduledDays: .infinity,
            phaseBefore: .review,
            durationMs: -1
        )
    )
    let result = try FSRSOptimizer(minimumObservations: 20, passes: 2).optimize(logs: logs)

    #expect(result.observationCount == 24)
    #expect(result.parameters.weights.count == 21)
    for (weight, bound) in zip(result.parameters.weights, FSRSScheduler.Parameters.weightBounds) {
        #expect(weight.isFinite)
        #expect(weight >= bound.lower)
        #expect(weight <= bound.upper)
    }
}

@Test func optimizerImprovesHeldSyntheticLogLossWithoutDestabilizingWeights() throws {
    let logs = syntheticLogs(cardCount: 80, reviewsPerCard: 8)
    let grouped = Dictionary(grouping: logs, by: \.cardID)
        .sorted { $0.key.uuidString < $1.key.uuidString }
    let training = grouped.enumerated()
        .filter { $0.offset % 4 != 0 }
        .flatMap(\.element.value)
    let held = grouped.enumerated()
        .filter { $0.offset % 4 == 0 }
        .flatMap(\.element.value)
    let optimizer = FSRSOptimizer(minimumObservations: 300, passes: 7)
    let baseline = FSRSScheduler.Parameters()

    let result = try optimizer.optimize(logs: training, startingAt: baseline)
    let heldBefore = optimizer.logLoss(logs: held, parameters: baseline)
    let heldAfter = optimizer.logLoss(logs: held, parameters: result.parameters)

    #expect(result.improved)
    #expect(result.optimizedLoss < result.previousLoss)
    #expect(heldAfter < heldBefore)
    for (index, weight) in result.parameters.weights.enumerated() {
        let bound = FSRSScheduler.Parameters.weightBounds[index]
        #expect(weight.isFinite)
        #expect(weight >= bound.lower && weight <= bound.upper)
        #expect(abs(weight - baseline.weights[index]) <= bound.upper - bound.lower)
    }
}

@Test func fullOptimizationRunsAfterReferenceParityIsVerified() throws {
    let legacyWeights = [
        0.40255, 1.18385, 3.173, 15.69105, 7.1949, 0.5345, 1.4604, 0.0046,
        1.54575, 0.1192, 1.01925, 1.9395, 0.11, 0.29605, 2.2698, 0.2315,
        2.9898, 0.51655, 0.6621,
    ]
    let starting = FSRSScheduler.Parameters(weights: legacyWeights, enableFuzz: false)
    #expect(abs(starting.weights[19] - 0.01) < 1e-6)

    #expect(SchedulerPersistenceConstants.optimizerParityVerified)
    let result = try FSRSOptimizer(minimumObservations: 300, passes: 7).optimize(
        logs: syntheticLogs(cardCount: 80, reviewsPerCard: 8),
        startingAt: starting
    )
    #expect(result.observationCount >= 300)
    #expect(result.parameters.weights.count == 21)
    #expect(result.parameters.weights.allSatisfy { $0.isFinite })
}

@Test func optimizerRecoversTowardGeneratingWeightsOnHeldOutData() throws {
    let logs = syntheticLogs(cardCount: 80, reviewsPerCard: 8)
    let grouped = Dictionary(grouping: logs, by: \.cardID)
        .sorted { $0.key.uuidString < $1.key.uuidString }
    let training = grouped.enumerated()
        .filter { $0.offset % 4 != 0 }
        .flatMap(\.element.value)
    let held = grouped.enumerated()
        .filter { $0.offset % 4 == 0 }
        .flatMap(\.element.value)

    let optimizer = FSRSOptimizer(minimumObservations: 300, passes: 7)
    let baseline = FSRSScheduler.Parameters()
    let truth = FSRSScheduler.Parameters(weights: syntheticTrueWeights())

    let result = try optimizer.optimize(logs: training, startingAt: baseline)

    let heldBaseline = optimizer.logLoss(logs: held, parameters: baseline)
    let heldOptimized = optimizer.logLoss(logs: held, parameters: result.parameters)
    let heldTruth = optimizer.logLoss(logs: held, parameters: truth)

    // The generating weights define the irreducible held-out loss. Fitting must
    // move the default weights toward that floor, not just wobble.
    #expect(heldTruth <= heldBaseline)
    #expect(heldOptimized < heldBaseline)
    #expect(heldOptimized <= heldTruth * 1.2 + 1e-3)
}

@Test func equalTimestampReviewsUsePersistedAppendSequenceNotUUID() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-review-order-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try ItemStore(databaseURL: root.appendingPathComponent("test.sqlite"))
    try await store.bootstrap()
    let itemType = try await store.defaultItemType()
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    try await store.createItem(Item(
        itemTypeID: itemType.id,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Front")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Back")),
        ]
    ), now: timestamp)
    let cardID = try #require(try await store.fetchDueCards(asOf: timestamp).first?.id)
    let database = await store.database
    let first = ReviewLog(
        id: UUID(uuidString: "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF")!,
        cardID: cardID,
        reviewedAt: timestamp,
        rating: .good,
        elapsedDays: 0,
        scheduledDays: 0,
        phaseBefore: .new,
        durationMs: 1
    )
    let second = ReviewLog(
        id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
        cardID: cardID,
        reviewedAt: timestamp,
        rating: .again,
        elapsedDays: 1,
        scheduledDays: 1,
        phaseBefore: .review,
        durationMs: 1
    )
    try await database.insertReviewLog(first, memoryBefore: .new(due: timestamp))
    try await database.insertReviewLog(second, memoryBefore: .new(due: timestamp))

    let fetched = try await database.fetchActiveReviewLogs()
    #expect(fetched.map(\.id) == [first.id, second.id])
    #expect(fetched.map(\.sequence) == [1, 2])

    let optimizer = FSRSOptimizer(minimumObservations: 1)
    let orderedLoss = optimizer.logLoss(logs: fetched)
    let shuffledLoss = optimizer.logLoss(logs: Array(fetched.reversed()))
    #expect(orderedLoss == shuffledLoss)
}

@Test func optimizerDoesNotScoreIntradayAnswersAsIndependentTargets() throws {
    let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    let scheduler = LearningScheduler(
        parameters: .init(enableFuzz: false)
    )
    var logs: [ReviewLog] = []

    for cardIndex in 0..<60 {
        let cardID = stableUUID(50_000 + cardIndex)
        var state = MemoryState.new(due: epoch)
        var now = epoch
        for (reviewIndex, rating) in [ReviewRating.again, .good, .good].enumerated() {
            let elapsed = state.lastReview.map {
                now.timeIntervalSince($0) / 86_400
            } ?? 0
            let scheduled = state.lastReview.map {
                max(state.due.timeIntervalSince($0) / 86_400, 0)
            } ?? 0
            logs.append(
                ReviewLog(
                    id: stableUUID(60_000 + cardIndex * 10 + reviewIndex),
                    cardID: cardID,
                    reviewedAt: now,
                    rating: rating,
                    elapsedDays: elapsed,
                    scheduledDays: scheduled,
                    phaseBefore: state.phase,
                    durationMs: 500
                )
            )
            state = scheduler.schedule(state, rating: rating, now: now)
            now = state.due
        }
    }

    let optimizer = FSRSOptimizer(minimumObservations: 100)
    #expect(throws: FSRSOptimizationError.insufficientData(required: 100, available: 0)) {
        try optimizer.optimize(logs: logs)
    }
}

@Test func optimizationScheduleWaitsForEnoughHistoryBeforeTheFirstFit() {
    let schedule = FSRSOptimizationSchedule()
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    #expect(!schedule.needsOptimization(reviewLogCount: 0, lastAttempt: nil, now: now))
    #expect(
        !schedule.needsOptimization(
            reviewLogCount: FSRSOptimizationSchedule.defaultMinimumReviewLogs - 1,
            lastAttempt: nil,
            now: now
        )
    )
    #expect(
        schedule.needsOptimization(
            reviewLogCount: FSRSOptimizationSchedule.defaultMinimumReviewLogs,
            lastAttempt: nil,
            now: now
        )
    )
}

@Test func optimizationScheduleRequiresProportionalGrowthAfterAnAttempt() {
    let schedule = FSRSOptimizationSchedule()
    let attemptedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let attempt = FSRSOptimizationSchedule.Attempt(
        reviewLogCount: 1_000,
        attemptedAt: attemptedAt
    )
    let soon = attemptedAt.addingTimeInterval(86_400)

    // 50 new reviews is the flat floor, but against a 1,000-review history it is
    // noise: 25% growth is what can move the weights.
    #expect(!schedule.needsOptimization(reviewLogCount: 1_100, lastAttempt: attempt, now: soon))
    #expect(schedule.needsOptimization(reviewLogCount: 1_250, lastAttempt: attempt, now: soon))

    // The flat floor governs while the history is small.
    let small = FSRSOptimizationSchedule.Attempt(reviewLogCount: 120, attemptedAt: attemptedAt)
    #expect(!schedule.needsOptimization(reviewLogCount: 160, lastAttempt: small, now: soon))
    #expect(!schedule.needsOptimization(reviewLogCount: 170, lastAttempt: small, now: soon))
    #expect(schedule.needsOptimization(reviewLogCount: 400, lastAttempt: small, now: soon))
}

@Test func optimizationScheduleRefitsStaleParametersOnceHistoryHasMovedAtAll() {
    let schedule = FSRSOptimizationSchedule()
    let attemptedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let attempt = FSRSOptimizationSchedule.Attempt(
        reviewLogCount: 1_000,
        attemptedAt: attemptedAt
    )
    let later = attemptedAt.addingTimeInterval(
        FSRSOptimizationSchedule.defaultStaleInterval + 1
    )

    #expect(schedule.needsOptimization(reviewLogCount: 1_001, lastAttempt: attempt, now: later))
    // Staleness alone is not a reason: unchanged history cannot produce a
    // different fit however long ago it was read.
    #expect(!schedule.needsOptimization(reviewLogCount: 1_000, lastAttempt: attempt, now: later))
    // Reverted reviews can shrink the count; that is not new history either.
    #expect(!schedule.needsOptimization(reviewLogCount: 980, lastAttempt: attempt, now: later))
}

private func syntheticTrueWeights() -> [Double] {
    var trueWeights = FSRSScheduler.Parameters.defaultWeights
    trueWeights[0] = 0.9
    trueWeights[1] = 2.0
    trueWeights[2] = 5.0
    trueWeights[3] = 20.0
    trueWeights[8] = 2.2
    trueWeights[10] = 1.4
    return trueWeights
}

private func syntheticLogs(cardCount: Int, reviewsPerCard: Int) -> [ReviewLog] {
    let trueWeights = syntheticTrueWeights()
    let scheduler = FSRSScheduler(
        parameters: .init(weights: trueWeights, enableFuzz: false)
    )
    let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    var logs: [ReviewLog] = []

    for cardIndex in 0..<cardCount {
        let cardID = stableUUID(cardIndex)
        var state = MemoryState.new(due: epoch)
        var now = epoch.addingTimeInterval(Double(cardIndex) * 60)

        for reviewIndex in 0..<reviewsPerCard {
            let elapsed: Double
            let rating: ReviewRating
            if reviewIndex == 0 {
                elapsed = 0
                rating = ReviewRating(rawValue: cardIndex % 4 + 1) ?? .good
            } else {
                let multiplier = [0.55, 0.85, 1.0, 1.25, 1.6][(cardIndex + reviewIndex) % 5]
                elapsed = max(1, (state.stability * multiplier).rounded())
                now = now.addingTimeInterval(elapsed * 86_400)
                let probability = scheduler.retrievability(
                    elapsedDays: elapsed,
                    stability: state.stability
                )
                let unit = deterministicUnit(card: cardIndex, review: reviewIndex)
                if unit >= probability {
                    rating = .again
                } else if (cardIndex + reviewIndex) % 7 == 0 {
                    rating = .easy
                } else if (cardIndex + reviewIndex) % 5 == 0 {
                    rating = .hard
                } else {
                    rating = .good
                }
            }

            logs.append(
                ReviewLog(
                    id: stableUUID(cardIndex * 100 + reviewIndex + 10_000),
                    cardID: cardID,
                    reviewedAt: now,
                    rating: rating,
                    elapsedDays: elapsed,
                    scheduledDays: elapsed,
                    phaseBefore: state.phase,
                    durationMs: 1_000
                )
            )
            state = scheduler.schedule(state, rating: rating, now: now)
        }
    }
    return logs
}

private func deterministicUnit(card: Int, review: Int) -> Double {
    var value = UInt64(card + 1) &* 0x9E37_79B9_7F4A_7C15
    value ^= UInt64(review + 1) &* 0xBF58_476D_1CE4_E5B9
    value ^= value >> 30
    value &*= 0xBF58_476D_1CE4_E5B9
    value ^= value >> 27
    return Double(value % 10_000) / 10_000
}

private func stableUUID(_ value: Int) -> UUID {
    let suffix = String(format: "%012llx", UInt64(value))
    return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
}
