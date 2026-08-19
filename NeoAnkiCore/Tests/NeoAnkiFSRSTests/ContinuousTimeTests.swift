import Testing
@testable import NeoAnkiFSRS

@Suite("Continuous elapsed time")
struct ContinuousTimeTests {
    @Test func fractionalElapsedTimeChangesRetrievabilityAndState() throws {
        let fsrs = FSRS()
        let initial = try fsrs.nextStates(
            current: nil,
            desiredRetention: 0.9,
            daysElapsed: 0
        ).good.memory

        let fractional = Float(21.5 / 24.0)
        let retrievability = fsrs.retrievability(state: initial, daysElapsed: fractional)
        let continuous = try fsrs.nextStates(
            current: initial,
            desiredRetention: 0.9,
            daysElapsed: fractional
        ).good
        let immediate = try fsrs.nextStates(
            current: initial,
            desiredRetention: 0.9,
            daysElapsed: 0
        ).good

        #expect(retrievability < 1)
        #expect(continuous.memory.stability != immediate.memory.stability)
        #expect(continuous.interval != immediate.interval)
    }

    @Test func fractionalTargetsSurviveDatasetPreparation() {
        let examples = (0..<64).flatMap { index in
            DatasetBuilder.examples(cardID: "card-\(index)", history: [
                Review(rating: .good, deltaT: 0),
                Review(rating: .good, deltaT: 0.2 + Float(index) / 1_000),
            ])
        }

        let dataset = DatasetBuilder.prepare(examples)

        #expect(dataset.training.count == 64)
        #expect(dataset.initialization.count == 64)
        #expect(dataset.training.allSatisfy { ($0.item.reviews.last?.deltaT ?? 0) < 1 })
    }

    @Test func invalidFractionalElapsedTimeIsRejected() throws {
        let fsrs = FSRS()

        #expect(throws: FSRSError.invalidInput) {
            try fsrs.nextStates(current: nil, desiredRetention: 0.9, daysElapsed: .nan)
        }
        #expect(throws: FSRSError.invalidInput) {
            try fsrs.memoryState(item: Item(reviews: [
                Review(rating: .good, deltaT: -.infinity),
            ]))
        }
    }
}
