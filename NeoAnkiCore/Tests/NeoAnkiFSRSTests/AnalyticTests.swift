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
        for (caseIndex, reference) in fixture.gradientCases.enumerated() {
            var gradient = [Double](repeating: 0, count: 21)
            let loss = Analytic.prefixLossAndGradient(
                weights: Parameters.defaults, timeHistory: reference.times,
                ratingHistory: reference.ratings, sequenceLength: 3, batchSize: 1,
                sequenceLengths: [3], deltaTimes: [reference.delta], labels: [reference.label],
                exampleWeights: [1], gradient: &gradient
            )
            let context = "case \(caseIndex), times \(reference.times), ratings \(reference.ratings), delta \(reference.delta), label \(reference.label)"
            #expect(abs(loss - reference.loss) < 1e-12, "\(context): loss \(loss), oracle \(reference.loss)")
            try #require(gradient.count == reference.gradient.count, "\(context): gradient shape differs")
            for (parameter, expected) in reference.gradient.enumerated() {
                let actual = gradient[parameter]
                let parameterContext = "\(context), parameter \(parameter): actual \(actual), oracle \(expected)"
                try #require(actual.isFinite && expected.isFinite, "\(parameterContext): nonfinite derivative")
                if expected == 0 {
                    // Inactive/clamped branches must remain exactly inactive.
                    #expect(actual == 0, "\(parameterContext): an inactive derivative became active")
                    continue
                }

                // The pinned Rust analytic.rs and Swift both cache Float
                // forward states before Double backpropagation. Promoting a
                // cache does not recover the precision lost in exp/pow/log;
                // their Float results can differ across platform math libraries.
                // Compare these three-step fixtures to two Float ULPs at each
                // derivative's magnitude, retaining the original 1e-10 bound
                // for tiny derivatives. This is a fixture precision contract,
                // not a general error bound for arbitrary-length histories.
                // Intel's observed maximum was 1.14 Float ULPs; exact zero and
                // sign, strict loss parity, and independent finite differences
                // remain separate requirements.
                // https://doc.rust-lang.org/std/primitive.f32.html#method.powf
                let floatMagnitude = Float(abs(expected))
                try #require(floatMagnitude.isFinite && floatMagnitude > 0, "\(parameterContext): oracle exceeds Float range")
                let floatULP = Double(floatMagnitude.ulp)
                let allowedDifference = max(1e-10, 2 * floatULP)
                let difference = abs(actual - expected)
                #expect(actual.sign == expected.sign, "\(parameterContext): derivative sign changed")
                #expect(difference <= allowedDifference,
                        "\(parameterContext): absolute difference \(difference), Float ULPs \(difference / floatULP), allowed \(allowedDifference)")
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
