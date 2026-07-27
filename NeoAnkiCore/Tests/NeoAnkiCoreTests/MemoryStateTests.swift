import Foundation
import Testing
@testable import NeoAnkiCore

@Test func memoryStateNewDefaults() {
    let due = Date(timeIntervalSince1970: 1_700_000_000)
    let state = MemoryState.new(due: due)

    #expect(state.stability == 0)
    #expect(state.difficulty == 0)
    #expect(state.due == due)
    #expect(state.lastReview == nil)
    #expect(state.reps == 0)
    #expect(state.lapses == 0)
    #expect(state.phase == .new)
    #expect(state.stepIndex == nil)
}

@Test func memoryStateIsDueWhenPastDueDate() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let past = MemoryState(due: now.addingTimeInterval(-60))
    let future = MemoryState(due: now.addingTimeInterval(60))

    #expect(past.isDue(asOf: now))
    #expect(future.isDue(asOf: now) == false)
    #expect(MemoryState(due: now).isDue(asOf: now))
}

@Test func memoryStateCodableRoundTrip() throws {
    let original = MemoryState(
        stability: 12.5,
        difficulty: 5.2,
        due: Date(timeIntervalSince1970: 1_700_000_000),
        lastReview: Date(timeIntervalSince1970: 1_699_000_000),
        reps: 4,
        lapses: 1,
        phase: .learning,
        stepIndex: 0
    )

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(MemoryState.self, from: data)

    #expect(decoded == original)
}

@Test func memoryStateDecodesBeforeStepIndexWasAdded() throws {
    let data = Data(
        """
        {
          "stability": 1.2,
          "difficulty": 5.0,
          "due": 721692800,
          "lastReview": null,
          "reps": 1,
          "lapses": 0,
          "phase": "review"
        }
        """.utf8
    )

    let decoded = try JSONDecoder().decode(MemoryState.self, from: data)

    #expect(decoded.stepIndex == nil)
    #expect(decoded.phase == .review)
}

@Test func phaseRawValuesAreStable() {
    #expect(Phase.new.rawValue == "new")
    #expect(Phase.learning.rawValue == "learning")
    #expect(Phase.review.rawValue == "review")
    #expect(Phase.relearning.rawValue == "relearning")
}
