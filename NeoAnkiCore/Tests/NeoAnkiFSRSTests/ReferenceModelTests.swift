import Foundation
import Testing
@testable import NeoAnkiFSRS

@Suite("Pinned fsrs-rs reference model")
struct ReferenceModelTests {
    @Test func upstreamIdentityIsPinned() {
        #expect(FSRSReference.upstreamCommit == "6f5498f8dd1a95c781fcdd4448f28f16dd9e377d")
        #expect(FSRSReference.upstreamVersion == "6.6.2")
    }

    @Test func committedFixturesMatchVerificationManifest() throws {
        let manifest = try VerificationManifest.load()
        let optimizer = try OptimizerReferenceFixture.load()
        #expect(manifest.upstreamCommit == FSRSReference.upstreamCommit)
        #expect(manifest.githubCommitTarballSha256 == FSRSReference.githubTarballSHA256)
        #expect(manifest.gitArchiveTarSha256 == FSRSReference.gitArchiveSHA256)
        #expect(optimizer.upstreamCommit == FSRSReference.upstreamCommit)
        #expect(manifest.status == "verified")
        #expect(FSRSReference.optimizerParityVerified)
        for (name, expectedHash) in manifest.fixtures {
            let resourceName = String(name.dropLast(".json".count))
            #expect(try FixtureFiles.sha256(named: resourceName) == expectedHash)
        }
        #expect(try FixtureFiles.sha256(named: "VERIFICATION", extension: "md") == manifest.verificationReportSha256)
    }

    @Test func initialStatesMatchUpstreamDocumentation() throws {
        let states = try FSRS().nextStates(current: nil, desiredRetention: 0.9, daysElapsed: 0)
        let expected: [(ItemState, Float, Float, Float)] = [
            (states.again, 0.212, 6.4133, 0.212),
            (states.hard, 1.2931, 5.1121707, 1.2931),
            (states.good, 2.3065, 2.118104, 2.3065),
            (states.easy, 8.2956, 1.0, 8.2956),
        ]
        for (actual, stability, difficulty, interval) in expected {
            #expect(abs(actual.memory.stability - stability) < 1e-5)
            #expect(abs(actual.memory.difficulty - difficulty) < 1e-5)
            #expect(abs(actual.interval - interval) < 1e-5)
        }
    }

    @Test func intradayReviewUsesShortTermBranch() throws {
        let initial = try FSRS().nextStates(current: nil, desiredRetention: 0.9, daysElapsed: 0).good.memory
        let next = try FSRS().nextStates(current: initial, desiredRetention: 0.9, daysElapsed: 0)
        #expect(next.good.memory.stability >= initial.stability)
        #expect(next.again.memory.stability < initial.stability)
    }

    @Test func datasetRetainsIntradayContextButScoresOnlyInterday() {
        let history = [
            Review(rating: .again, deltaT: 0),
            Review(rating: .good, deltaT: 0),
            Review(rating: .hard, deltaT: 1),
            Review(rating: .good, deltaT: 0),
            Review(rating: .again, deltaT: 3),
        ]
        let examples = DatasetBuilder.examples(cardID: "card", history: history)
        #expect(examples.count == 2)
        #expect(examples[0].item.reviews.count == 3)
        #expect(examples[1].item.reviews.count == 5)
    }

    @Test func parameterClippingEnforcesCoupledAndMonotonicConstraints() throws {
        var invalid = Parameters.defaults
        invalid[17] = 2
        invalid[18] = 2
        let clipped = ParameterClipper.clip(invalid, relearningSteps: 2)
        #expect(clipped[17] <= 2)
        #expect(clipped[18] <= 2)

        let smoothed = StabilityInitializer.smoothAndFill(
            [.again: 4, .hard: 2, .good: 3, .easy: 1],
            counts: [.again: 1, .hard: 2, .good: 3, .easy: 4]
        )
        #expect(zip(smoothed, smoothed.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test func pathologicalLegacyInitialStabilityShapeIsNotPromotionSafe() {
        var pathological = Parameters.defaults
        pathological.replaceSubrange(0..<4, with: [
            0.001, 37.308839839, 9.70342603, 41.456168391,
        ])
        #expect(ParameterClipper.isValid(pathological))
        #expect(!ParameterClipper.hasMonotonicInitialStability(pathological))
    }

    @Test func evaluationReturnsFiniteMetrics() throws {
        let histories = (0..<12).flatMap { card in
            DatasetBuilder.examples(cardID: "\(card)", history: [
                Review(rating: .good, deltaT: 0),
                Review(rating: card.isMultiple(of: 4) ? .again : .good, deltaT: Float(card % 3 + 1)),
            ])
        }
        let evaluation = try FSRS().evaluate(histories)
        #expect(evaluation.observationCount == 12)
        #expect(evaluation.logLoss.isFinite)
        #expect(evaluation.brierScore.isFinite)
        #expect(evaluation.rmseBins.isFinite)
    }

    @Test func fullOptimizerProducesFiniteClippedWeights() throws {
        var examples = (0..<64).map { card in
            TrainingExample(cardID: "\(card)", item: Item(reviews: [
                Review(rating: .good, deltaT: 0),
                Review(rating: .good, deltaT: 2),
            ]))
        }
        examples.append(TrainingExample(cardID: "long", item: Item(reviews: [
            Review(rating: .good, deltaT: 0),
            Review(rating: .good, deltaT: 2),
            Review(rating: .hard, deltaT: 5),
        ])))
        let result = try Optimizer().computeParameters(examples: examples)
        #expect(result.stage == .fullyOptimized)
        #expect(result.parameters.values.allSatisfy { $0.isFinite })
        #expect(ParameterClipper.isValid(result.parameters.values))
    }

    @Test func fiveEpochOptimizerMatchesPinnedRustOracle() throws {
        let fixture = try OptimizerReferenceFixture.load()
        let examples = optimizerFixtureExamples()
        let result = try Optimizer().computeParameters(examples: examples)
        #expect(result.stage == .fullyOptimized)
        for (actual, reference) in zip(result.parameters.values, fixture.finalParameters) {
            #expect(abs(actual - reference) <= 1e-4)
        }
        #expect(abs(result.evaluation.logLoss - fixture.evaluation.logLoss) <= 1e-6)
        #expect(abs(result.evaluation.rmseBins - fixture.evaluation.rmseBins) <= 1e-6)
    }

    @Test func optimizerBatchStructureMatchesPinnedRustOracle() throws {
        let fixture = try OptimizerReferenceFixture.load().batchStructure
        let batches = buildWindowedBatches(
            weighted(optimizerFixtureExamples()), maximumPredictions: 512
        )
        #expect(batches.count == 1)
        let batch = batches[0]
        #expect(batch.sequenceLength == fixture.sequenceLength)
        #expect(batch.batchSize == fixture.batchSize)
        #expect(batch.realBatchSize == fixture.realBatchSize)
        #expect(batch.columnLengths == [Int](repeating: fixture.columnLength, count: fixture.batchSize))

        for row in 0..<fixture.sequenceLength {
            let range = row * fixture.batchSize..<(row + 1) * fixture.batchSize
            #expect(Array(batch.times[range]) == [Float](repeating: fixture.timeRows[row], count: fixture.batchSize))
        }
        let expectedRatings = (0..<fixture.batchSize).map {
            fixture.firstRatingCycle[$0 % fixture.firstRatingCycle.count]
        } + (0..<fixture.batchSize).map {
            $0.isMultiple(of: fixture.secondRatingAgainStride) ? Float(Rating.again.rawValue) : Float(Rating.good.rawValue)
        } + (0..<fixture.batchSize).map {
            $0.isMultiple(of: fixture.thirdRatingHardStride) ? Float(Rating.hard.rawValue) : Float(Rating.good.rawValue)
        }
        #expect(batch.ratings == expectedRatings)
        for row in 0..<fixture.sequenceLength {
            let range = row * fixture.batchSize..<(row + 1) * fixture.batchSize
            #expect(batch.labels[range].count { $0 == 1 } == fixture.labelRowSuccessCounts[row])
        }
        for reference in fixture.weightRows {
            let range = reference.row * fixture.batchSize..<(reference.row + 1) * fixture.batchSize
            let values = batch.weights[range].filter { $0 != 0 }
            #expect(values.count == reference.nonzeroCount)
            #expect(values.first == reference.first)
            #expect(values.last == reference.last)
        }
    }

    private func optimizerFixtureExamples() -> [TrainingExample] {
        var examples: [TrainingExample] = []
        for card in 0..<80 {
            let history = [
                Review(rating: Rating.allCases[card % Rating.allCases.count], deltaT: 0),
                Review(rating: card.isMultiple(of: 5) ? .again : .good, deltaT: 2),
                Review(rating: card.isMultiple(of: 7) ? .hard : .good, deltaT: 5),
            ]
            let cardID = String(format: "%03d", card)
            examples.append(TrainingExample(
                cardID: cardID, item: Item(reviews: Array(history.prefix(2))),
                order: Int64(card * 2)
            ))
            examples.append(TrainingExample(
                cardID: cardID, item: Item(reviews: history),
                order: Int64(card * 2 + 1)
            ))
        }
        return examples
    }
}
