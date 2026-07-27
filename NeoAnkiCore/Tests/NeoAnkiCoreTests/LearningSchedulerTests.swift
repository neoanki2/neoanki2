import Foundation
import Testing
@testable import NeoAnkiCore

@Test func newAgainEntersImmediateLearningRepair() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let next = LearningScheduler().schedule(.new(due: now), rating: .again, now: now)

    #expect(next.phase == .learning)
    #expect(next.stepIndex == 0)
    #expect(next.due == now)
    #expect(next.lapses == 0)
}

@Test func newHardGraduatesWithFSRSDue() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let next = LearningScheduler().schedule(.new(due: now), rating: .hard, now: now)

    #expect(next.phase == .review)
    #expect(next.stepIndex == nil)
    #expect(next.due > now)
}

@Test(arguments: [ReviewRating.hard, .good, .easy])
func rememberedNewCardGraduatesToReview(rating: ReviewRating) {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let next = LearningScheduler(
        parameters: .init(enableFuzz: false)
    ).schedule(.new(due: now), rating: rating, now: now)

    #expect(next.phase == .review)
    #expect(next.stepIndex == nil)
    #expect(next.due >= now.addingTimeInterval(86_400))
}

@Test func learningAgainDoesNotCountAsLapse() {
    let now = Date(timeIntervalSince1970: 1_700_000_600)
    let learning = MemoryState(
        stability: 0.4,
        difficulty: 8,
        due: now,
        lastReview: now.addingTimeInterval(-60),
        reps: 1,
        lapses: 0,
        phase: .learning,
        stepIndex: 0
    )

    let next = LearningScheduler().schedule(learning, rating: .again, now: now)

    #expect(next.phase == .learning)
    #expect(next.stepIndex == 1)
    #expect(next.due == now)
    #expect(next.lapses == 0)
}

@Test func reviewAgainCountsOneLapseAndEntersRelearning() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let review = MemoryState(
        stability: 10,
        difficulty: 5,
        due: now,
        lastReview: now.addingTimeInterval(-10 * 86_400),
        reps: 3,
        lapses: 1,
        phase: .review
    )

    let next = LearningScheduler().schedule(review, rating: .again, now: now)

    #expect(next.phase == .relearning)
    #expect(next.stepIndex == 0)
    #expect(next.due == now)
    #expect(next.lapses == 2)
}

@Test func repeatedRelearningAgainDoesNotAddAnotherLapse() {
    let now = Date(timeIntervalSince1970: 1_700_000_600)
    let relearning = MemoryState(
        stability: 2,
        difficulty: 6,
        due: now,
        lastReview: now.addingTimeInterval(-60),
        reps: 4,
        lapses: 2,
        phase: .relearning,
        stepIndex: 0
    )

    let next = LearningScheduler().schedule(relearning, rating: .again, now: now)

    #expect(next.phase == .relearning)
    #expect(next.lapses == 2)
    #expect(next.stepIndex == 1)
    #expect(next.due == now)
}

@Test(arguments: [Phase.learning, .relearning])
func hardGraduatesWithFSRSIntradayDueWithoutAddingLapse(phase: Phase) {
    let now = Date(timeIntervalSince1970: 1_700_000_060)
    let state = MemoryState(
        stability: 0.2,
        difficulty: 6,
        due: now,
        lastReview: now.addingTimeInterval(-60),
        reps: 2,
        lapses: phase == .relearning ? 1 : 0,
        phase: phase,
        stepIndex: 2
    )

    let next = LearningScheduler().schedule(state, rating: .hard, now: now)

    #expect(next.phase == .review)
    #expect(next.stepIndex == nil)
    #expect(next.due > now.addingTimeInterval(4 * 3_600))
    #expect(next.due < now.addingTimeInterval(6 * 3_600))
    #expect(next.lapses == state.lapses)
}

@Test(arguments: [Phase.learning, .relearning])
func goodGraduatesIntradayStep(phase: Phase) {
    let now = Date(timeIntervalSince1970: 1_700_000_600)
    let state = MemoryState(
        stability: 1,
        difficulty: 6,
        due: now,
        lastReview: now.addingTimeInterval(-60),
        reps: 1,
        lapses: phase == .relearning ? 1 : 0,
        phase: phase,
        stepIndex: 0
    )

    let next = LearningScheduler(
        parameters: .init(enableFuzz: false)
    ).schedule(state, rating: .good, now: now)

    #expect(next.phase == .review)
    #expect(next.stepIndex == nil)
    #expect(next.due >= now.addingTimeInterval(86_400))
}

@Test func everyPhaseAndRatingHonorsExplicitContract() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let scheduler = LearningScheduler(parameters: .init(enableFuzz: false))

    for phase in [Phase.new, .learning, .review, .relearning] {
        for rating in ReviewRating.allCases {
            let state = MemoryState(
                stability: phase == .new ? 0 : 0.2,
                difficulty: phase == .new ? 0 : 6,
                due: now,
                lastReview: phase == .new ? nil : now.addingTimeInterval(-3_600),
                reps: phase == .new ? 0 : 2,
                lapses: phase == .relearning ? 1 : 0,
                phase: phase,
                stepIndex: phase == .learning || phase == .relearning ? 0 : nil
            )
            let next = scheduler.schedule(state, rating: rating, now: now)
            let failedAcquisition = phase != .review && rating == .again
            let reviewLapse = phase == .review && rating == .again

            if failedAcquisition || reviewLapse {
                #expect(next.due == now)
                #expect(next.phase == (phase == .new ? .learning : reviewLapse ? .relearning : phase))
                #expect(next.stepIndex != nil)
            } else {
                #expect(next.phase == .review)
                #expect(next.stepIndex == nil)
                #expect(next.due > now)
            }
        }
    }
}

@Test func successfulRepairGraduationPreservesFSRSIntradayDue() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let state = MemoryState(
        stability: 0.2,
        difficulty: 6,
        due: now,
        lastReview: now.addingTimeInterval(-3_600),
        reps: 2,
        lapses: 0,
        phase: .learning,
        stepIndex: 1
    )
    let next = LearningScheduler(
        parameters: .init(enableFuzz: false)
    ).schedule(state, rating: .good, now: now)

    #expect(next.phase == .review)
    #expect(next.due > now)
    #expect(next.due < now.addingTimeInterval(86_400))
}
