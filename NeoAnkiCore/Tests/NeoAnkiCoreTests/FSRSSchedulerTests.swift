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
    #expect(state.due == now.addingTimeInterval(86_400))  // floored to one day
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

@Test func fsrs5NumericReferenceSequenceMatches() {
    let day: TimeInterval = 86_400
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let scheduler = FSRSScheduler(parameters: .init(enableFuzz: false))

    let first = scheduler.schedule(.new(due: start), rating: .good, now: start)
    #expect(abs(first.difficulty - 5.282_434_422_319_005) < 1e-12)
    #expect(abs(first.stability - 3.173) < 1e-12)

    let secondDate = start.addingTimeInterval(3 * day)
    let second = scheduler.schedule(first, rating: .good, now: secondDate)
    #expect(abs(scheduler.retrievability(of: first, asOf: secondDate) - 0.904_698_210_889_327_2) < 1e-12)
    #expect(abs(second.difficulty - 5.272_967_931_287_446) < 1e-12)
    #expect(abs(second.stability - 10.751_452_640_655_37) < 1e-11)
    #expect(second.due == secondDate.addingTimeInterval(11 * day))
}

@Test func sameDayReviewsUseFSRS5W17W18() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let scheduler = FSRSScheduler(parameters: .init(enableFuzz: false))
    let first = scheduler.schedule(.new(due: start), rating: .good, now: start)
    let sameDay = scheduler.schedule(
        first,
        rating: .easy,
        now: start.addingTimeInterval(3_600)
    )
    let expected = first.stability * exp(w[17] * (1 + w[18]))

    #expect(abs(sameDay.stability - expected) < 1e-12)
    #expect(sameDay.stability > first.stability)
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
    #expect(FSRSScheduler(parameters: parameters).intervalDays(for: .nan) == 1)
}
