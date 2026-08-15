import Testing
@testable import NeoAnkiFSRS

@Suite("Analytic optimizer primitives")
struct AnalyticTests {
    @Test func analyticPrefixGradientMatchesIndependentFiniteDifference() {
        let weights = Parameters.defaults
        let sequenceLength = 3
        let batchSize = 2
        let times: [Float] = [0, 0, 3, 2, 5, 6]
        let ratings: [Float] = [4, 1, 3, 2, 1, 3]
        let deltas: [Float] = [7, 9]
        let labels: [Float] = [1, 0]
        let exampleWeights: [Float] = [1, 0.7]
        let lengths = [sequenceLength, sequenceLength]
        var analytic = [Double](repeating: 0, count: 21)
        _ = Analytic.prefixLossAndGradient(
            weights: weights, timeHistory: times, ratingHistory: ratings,
            sequenceLength: sequenceLength, batchSize: batchSize,
            sequenceLengths: lengths, deltaTimes: deltas, labels: labels,
            exampleWeights: exampleWeights, gradient: &analytic
        )

        for index in weights.indices {
            let epsilon = max(Float(1e-3), abs(weights[index]) * 1e-3)
            var upper = weights, lower = weights
            upper[index] += epsilon
            lower[index] -= epsilon
            let upperLoss = loss(upper, times, ratings, lengths, deltas, labels, exampleWeights)
            let lowerLoss = loss(lower, times, ratings, lengths, deltas, labels, exampleWeights)
            let numeric = (upperLoss - lowerLoss) / Double(2 * epsilon)
            let difference = abs(numeric - analytic[index])
            let scale = max(1, abs(numeric), abs(analytic[index]))
            #expect(difference / scale < 0.02, "parameter \(index): analytic \(analytic[index]), numeric \(numeric)")
        }
    }

    @Test func randChaCha12MatchesUpstreamSeedVector() {
        let bytes: [UInt8] = [
            1, 0, 0, 0, 23, 0, 0, 0, 200, 1, 0, 0, 210, 30, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        ]
        var random = RandCompatibleRandom(seedBytes: bytes)
        #expect(random.nextUInt64() == 10_719_222_850_664_546_238)
    }

    @Test func randChaCha12MatchesZeroKeyCipherVector() {
        var random = RandCompatibleRandom(seedBytes: [UInt8](repeating: 0, count: 32))
        #expect(random.nextUInt64() == 0x53f9_5507_6a9a_f49b)
        #expect(random.nextUInt64() == 0xd583_265f_12ce_1f81)
    }

    @Test func seed2023ShuffleMatchesRandZeroPointTen() throws {
        let fixture = try OptimizerReferenceFixture.load()
        var random = RandCompatibleRandom(seed: 2023)
        var first = Array(0..<17)
        var second = Array(0..<17)
        random.shuffle(&first)
        random.shuffle(&second)
        #expect(fixture.trainingConfiguration.seed == 2023)
        #expect(first == fixture.permutations[0])
        #expect(second == fixture.permutations[1])
    }

    @Test func analyticBranchesMatchPinnedRustOracle() throws {
        let fixture = try OptimizerReferenceFixture.load()
        for reference in fixture.gradientCases {
            var gradient = [Double](repeating: 0, count: 21)
            let loss = Analytic.prefixLossAndGradient(
                weights: Parameters.defaults, timeHistory: reference.times,
                ratingHistory: reference.ratings, sequenceLength: 3, batchSize: 1,
                sequenceLengths: [3], deltaTimes: [reference.delta], labels: [reference.label],
                exampleWeights: [1], gradient: &gradient
            )
            #expect(abs(loss - reference.loss) < 1e-12)
            for (actual, expected) in zip(gradient, reference.gradient) {
                #expect(abs(actual - expected) < 1e-10)
            }
        }
    }

    @Test func adamAndCosineMatchPinnedRustOracle() throws {
        let fixture = try OptimizerReferenceFixture.load()
        var cosine = CosineAnnealing(maximum: 5, initialRate: 0.04)
        let rates = (0..<11).map { _ in cosine.step() }
        for (actual, expected) in zip(rates, fixture.cosineRates) {
            #expect(abs(actual - expected) < 1e-15)
        }

        var adam = Adam()
        var values = Parameters.defaults
        let firstGradient = (1...21).map { Double($0) / 10 }
        adam.step(&values, firstGradient, 0.04)
        #expect(values == fixture.adamSteps[0])
        adam.step(&values, firstGradient.map { -$0 * 0.5 }, 0.03618033988749895)
        #expect(values == fixture.adamSteps[1])
    }

    private func loss(
        _ weights: [Float], _ times: [Float], _ ratings: [Float], _ lengths: [Int],
        _ deltas: [Float], _ labels: [Float], _ exampleWeights: [Float]
    ) -> Double {
        var ignored = [Double](repeating: 0, count: 21)
        return Analytic.prefixLossAndGradient(
            weights: weights, timeHistory: times, ratingHistory: ratings,
            sequenceLength: 3, batchSize: 2, sequenceLengths: lengths,
            deltaTimes: deltas, labels: labels, exampleWeights: exampleWeights,
            gradient: &ignored
        )
    }
}
