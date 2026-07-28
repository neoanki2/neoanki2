import Foundation
import Testing
@testable import NeoAnkiCore

private let w = FSRSScheduler.Parameters.defaultWeights

@Test func firstReviewGoodInitializesFromWeights() {
    let now = Date(timeIntervalSince1970: 1_000_000)

    let state = FSRSScheduler().schedule(.new(due: now), rating: .good, now: now)

    #expect(state.reps == 1)
    #expect(state.phase == .review)
    #expect(abs(state.stability - w[2]) < 1e-9)   // initial S for "good"
    #expect(state.difficulty >= 1 && state.difficulty <= 10)
    #expect(state.lastReview == now)
    #expect(state.lapses == 0)
}

@Test func firstReviewAgainIsShortAndRelearning() {
    let now = Date(timeIntervalSince1970: 2_000_000)

    let state = FSRSScheduler().schedule(.new(due: now), rating: .again, now: now)

    #expect(abs(state.stability - w[0]) < 1e-9)   // initial S for "again"
    #expect(state.phase == .relearning)
    #expect(state.lapses == 0)                    // first-ever review isn't a lapse
    #expect(abs(state.due.timeIntervalSince(now) - w[0] * 86_400) < 1e-6)
}

@Test func higherGradeYieldsLongerInterval() {
    let now = Date(timeIntervalSince1970: 3_000_000)
    let sched = FSRSScheduler()
    let reviewed = MemoryState(
        stability: 10,
        difficulty: 5,
        due: now,
        lastReview: now.addingTimeInterval(-10 * 86_400),  // ~90% retrievability
        reps: 3,
        lapses: 0,
        phase: .review
    )

    let hard = sched.schedule(reviewed, rating: .hard, now: now)
    let good = sched.schedule(reviewed, rating: .good, now: now)
    let easy = sched.schedule(reviewed, rating: .easy, now: now)

    #expect(hard.stability < good.stability)
    #expect(good.stability < easy.stability)
    #expect(easy.due > good.due)
    #expect(good.due >= hard.due)
}

@Test func lapseCountsAndDoesNotGrowStability() {
    let now = Date(timeIntervalSince1970: 4_000_000)
    let sched = FSRSScheduler()
    let reviewed = MemoryState(
        stability: 20,
        difficulty: 5,
        due: now,
        lastReview: now.addingTimeInterval(-20 * 86_400),
        reps: 5,
        lapses: 1,
        phase: .review
    )

    let lapsed = sched.schedule(reviewed, rating: .again, now: now)

    #expect(lapsed.phase == .relearning)
    #expect(lapsed.lapses == 2)
    #expect(lapsed.stability <= reviewed.stability)
    #expect(lapsed.difficulty > reviewed.difficulty)  // failing raises difficulty
}

@Test func retrievabilityIsNinetyPercentAtOneStabilityLife() {
    let now = Date(timeIntervalSince1970: 5_000_000)
    let sched = FSRSScheduler()
    let state = MemoryState(
        stability: 15,
        difficulty: 5,
        due: now,
        lastReview: now.addingTimeInterval(-15 * 86_400),  // elapsed == stability
        reps: 2,
        lapses: 0,
        phase: .review
    )

    #expect(abs(sched.retrievability(of: state, asOf: now) - 0.9) < 1e-6)
}

@Test func retrievabilityIsOneForNewCard() {
    #expect(FSRSScheduler().retrievability(of: .new()) == 1)
}

@Test func fsrs6PinnedMemoryStateOracleMatches() {
    // Oracle from swift-fsrs commit a3dcee0599e4925380e1fca960cf46efbdac43cb,
    // itself modeled on ts-fsrs's FSRS-6 test vectors.
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let scheduler = FSRSScheduler(parameters: .init(enableFuzz: false))
    let ratings: [ReviewRating] = [.again, .good, .good, .good, .good, .good]
    let elapsed: [Double] = [0, 0, 1, 3, 8, 21]
    var state = MemoryState.new(due: start)
    var now = start

    for (rating, days) in zip(ratings, elapsed) {
        now = now.addingTimeInterval(days * 86_400)
        state = scheduler.schedule(state, rating: rating, now: now)
    }

    #expect(abs(state.stability - 53.62691) < 1e-4)
    #expect(abs(state.difficulty - 6.3574867) < 1e-4)
}

@Test func fsrs6PinnedSwiftOracleFirstReviewMatches() {
    let day: TimeInterval = 86_400
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let scheduler = FSRSScheduler(parameters: .init(enableFuzz: false))

    let results = ReviewRating.allCases.map {
        scheduler.schedule(.new(due: start), rating: $0, now: start)
    }
    #expect(results.map(\.stability) == [0.212, 1.2931, 2.3065, 8.2956])
    let expectedDifficulty = [6.4133, 5.11217071, 2.11810397, 1.0]
    for (actual, expected) in zip(results.map(\.difficulty), expectedDifficulty) {
        #expect(abs(actual - expected) < 1e-7)
    }
    #expect(abs(results[2].due.timeIntervalSince(start) - 2.3065 * day) < 1e-6)
}

@Test func legacyNineteenWeightsMigrateToFiniteTwentyOneWeightProfile() throws {
    let legacy = [
        0.40255, 1.18385, 3.173, 15.69105, 7.1949, 0.5345, 1.4604, 0.0046,
        1.54575, 0.1192, 1.01925, 1.9395, 0.11, 0.29605, 2.2698, 0.2315,
        2.9898, 0.51655, 0.6621,
    ]
    let data = try JSONSerialization.data(withJSONObject: [
        "weights": legacy,
        "requestRetention": 0.9,
        "maximumInterval": 36_500,
        "enableFuzz": false,
    ])
    let migrated = try JSONDecoder().decode(FSRSScheduler.Parameters.self, from: data)

    #expect(migrated.weights.count == 21)
    #expect(Array(migrated.weights.prefix(19)) == legacy)
    #expect(migrated.weights[19] == 0)
    #expect(migrated.weights[20] == 0.5)
    #expect(migrated.weights.allSatisfy { $0.isFinite })
    #expect(FSRSScheduler.Parameters.weightBounds[19].lower == 0.01)
}

@Test func fsrs6InitialStabilityHasAuthoritativePointOneFloor() {
    var weights = w
    weights[0] = 0.001
    let scheduler = FSRSScheduler(parameters: .init(weights: weights, enableFuzz: false))
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    let next = scheduler.schedule(.new(due: now), rating: .again, now: now)

    #expect(next.stability == 0.1)
}

@Test func bareFSRSReviewAgainCanScheduleOneDayOutWithoutLearningPolicy() {
    let now = Date(timeIntervalSinceReferenceDate: 806_926_474.635_533)
    let state = MemoryState(
        stability: 0.006940758044349528,
        difficulty: 9.955935509193166,
        due: Date(timeIntervalSinceReferenceDate: 806_923_269.169_737),
        lastReview: Date(timeIntervalSinceReferenceDate: 806_922_669.488_242),
        reps: 7,
        lapses: 0,
        phase: .review
    )

    let next = FSRSScheduler().schedule(state, rating: .again, now: now)

    #expect(next.phase == .relearning)
    #expect(next.due > now)
    #expect(next.due != now)
    #expect(next.lapses == 1)
}

@Test func shortTermHardAndGoodCanScheduleIntradayPrecisely() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let scheduler = FSRSScheduler(parameters: .init(enableFuzz: false))
    let state = MemoryState(
        stability: 0.2,
        difficulty: 6,
        due: now,
        lastReview: now.addingTimeInterval(-3_600),
        reps: 2,
        lapses: 0,
        phase: .review
    )

    let hard = scheduler.schedule(state, rating: .hard, now: now)
    let good = scheduler.schedule(state, rating: .good, now: now)

    #expect(hard.due > now)
    #expect(hard.due < now.addingTimeInterval(86_400))
    #expect(good.due > now)
    #expect(good.due < now.addingTimeInterval(86_400))
    #expect(good.due > hard.due)
    #expect(hard.due.timeIntervalSince(now).truncatingRemainder(dividingBy: 86_400) != 0)
}

@Test func sameDayReviewsUseFSRS6W17ThroughW19() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let scheduler = FSRSScheduler(parameters: .init(enableFuzz: false))
    let first = scheduler.schedule(.new(due: start), rating: .good, now: start)
    let sameDay = scheduler.schedule(
        first,
        rating: .easy,
        now: start.addingTimeInterval(3_600)
    )
    let increase = pow(first.stability, -w[19]) * exp(w[17] * (1 + w[18]))
    let expected = first.stability * max(1, increase)

    #expect(abs(sameDay.stability - expected) < 1e-12)
    #expect(sameDay.stability > first.stability)
}

@Test func forgetStabilityMatchesFSRS6ClosedForm() {
    let now = Date(timeIntervalSince1970: 6_000_000)
    let scheduler = FSRSScheduler(parameters: .init(enableFuzz: false))
    let reviewed = MemoryState(
        stability: 20,
        difficulty: 5,
        due: now,
        lastReview: now.addingTimeInterval(-30 * 86_400),  // overdue -> lower retrievability
        reps: 5,
        lapses: 0,
        phase: .review
    )

    let r = scheduler.retrievability(of: reviewed, asOf: now)
    let lapsed = scheduler.schedule(reviewed, rating: .again, now: now)

    // Independently recompute the FSRS-6 next difficulty for an "again" grade
    // from the weights, without reading it back from the scheduler.
    let clamp: (Double) -> Double = { min(10.0, max(1.0, $0)) }
    let deltaD = -w[6] * (Double(ReviewRating.again.rawValue) - 3.0)
    let damped = reviewed.difficulty + deltaD * (10.0 - reviewed.difficulty) / 9.0
    let easyInit = w[4] - exp(w[5] * 3.0) + 1.0
    let expectedDifficulty = clamp(w[7] * easyInit + (1.0 - w[7]) * damped)
    #expect(abs(lapsed.difficulty - expectedDifficulty) < 1e-12)

    // Independently recompute the FSRS-6 post-lapse stability from the weights.
    let sf = w[11]
        * pow(reviewed.difficulty, -w[12])
        * (pow(reviewed.stability + 1.0, w[13]) - 1.0)
        * exp(w[14] * (1.0 - r))
    let shortTermCap = reviewed.stability / exp(w[17] * w[18])
    let expected = max(0.001, min(sf, shortTermCap))

    #expect(abs(lapsed.stability - expected) < 1e-9)
    #expect(lapsed.stability <= shortTermCap)
}

@Test func updatedStabilityIsClampedToFSRSCeiling() {
    var weights = w
    weights[8] = FSRSScheduler.Parameters.weightBounds[8].upper
    weights[10] = FSRSScheduler.Parameters.weightBounds[10].upper
    weights[16] = FSRSScheduler.Parameters.weightBounds[16].upper
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let state = MemoryState(
        stability: 30_000,
        difficulty: 1,
        due: now,
        lastReview: now.addingTimeInterval(-36_500 * 86_400),
        reps: 10,
        lapses: 0,
        phase: .review
    )

    let next = FSRSScheduler(parameters: .init(weights: weights, enableFuzz: false))
        .schedule(state, rating: .easy, now: now)

    #expect(next.stability == 36_500)
}

@Test func sameDayGoodUsesFSRS6FactorAndCannotShrink() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let scheduler = FSRSScheduler(parameters: .init(enableFuzz: false))
    let first = scheduler.schedule(.new(due: start), rating: .good, now: start)
    let sameDay = scheduler.schedule(
        first,
        rating: .good,
        now: start.addingTimeInterval(3_600)
    )
    let exponent = w[17] * (Double(ReviewRating.good.rawValue) - 3.0 + w[18])
    let increase = pow(first.stability, -w[19]) * exp(exponent)
    let expected = first.stability * max(1, increase)

    #expect(abs(sameDay.stability - expected) < 1e-12)
    #expect(sameDay.stability >= first.stability)  // w17,w18 >= 0 -> non-shrinking
}

@Test func intervalFuzzIsDeterministicAndBounded() {
    let scheduler = FSRSScheduler()

    #expect(scheduler.fuzz(interval: 3, unit: 0) == 2)
    #expect(scheduler.fuzz(interval: 3, unit: 0.999_999) == 4)
    #expect(scheduler.fuzz(interval: 20, unit: 0.5) == 20)
    #expect(scheduler.fuzz(interval: 100, unit: 0) == 95)
    #expect(scheduler.fuzz(interval: 100, unit: 0.999_999) == 105)

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let state = MemoryState(
        stability: 100,
        difficulty: 5,
        due: now,
        lastReview: now.addingTimeInterval(-100 * 86_400),
        reps: 4,
        lapses: 0,
        phase: .review
    )
    #expect(
        scheduler.schedule(state, rating: .good, now: now).due
            == scheduler.schedule(state, rating: .good, now: now).due
    )
}

@Test func malformedParametersAreSanitized() {
    let parameters = FSRSScheduler.Parameters(
        weights: [.nan],
        requestRetention: .infinity,
        maximumInterval: -5
    )

    #expect(parameters.weights == FSRSScheduler.Parameters.defaultWeights)
    #expect(parameters.requestRetention == 0.9)
    #expect(parameters.maximumInterval == 1)
    #expect(FSRSScheduler(parameters: parameters).intervalDays(for: .nan) == 1.0 / 1_440.0)
}
