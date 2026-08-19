import Foundation

public enum StabilityInitializer {
    public static func initialize(
        from examples: [TrainingExample],
        averageRecall: Float
    ) throws -> [Float] {
        var grouped: [Rating: [Float: Aggregate]] = [:]
        for example in examples where example.item.longTermReviewCount == 1 {
            guard let first = example.item.reviews.first?.rating,
                  let target = example.item.reviews.first(where: { $0.deltaT > 0 })
            else { continue }
            var aggregate = grouped[first, default: [:]][target.deltaT] ?? Aggregate()
            aggregate.count += 1
            aggregate.successes += target.rating == .again ? 0 : 1
            grouped[first, default: [:]][target.deltaT] = aggregate
        }
        guard !grouped.isEmpty else { throw FSRSError.notEnoughData }
        var estimates: [Rating: Float] = [:]
        var counts: [Rating: Int] = [:]
        for (rating, values) in grouped {
            counts[rating] = values.values.reduce(0) { $0 + $1.count }
            let defaultS = Parameters.defaults[Int(rating.rawValue - 1)]
            var low = Double(ParameterClipper.stabilityMinimum)
            var high = Double(ParameterClipper.initialStabilityMaximum)
            for _ in 0..<1_000 where high - low > Double.ulpOfOne {
                let first = low + (high - low) / 3
                let second = high - (high - low) / 3
                if loss(first, values: values, averageRecall: averageRecall, defaultS: defaultS)
                    < loss(second, values: values, averageRecall: averageRecall, defaultS: defaultS) {
                    high = second
                } else {
                    low = first
                }
            }
            estimates[rating] = Float((low + high) / 2)
        }
        return smoothAndFill(estimates, counts: counts)
    }

    public static func smoothAndFill(_ input: [Rating: Float], counts: [Rating: Int]) -> [Float] {
        var known = input
        let orderedPairs: [(Rating, Rating)] = [
            (.again, .hard), (.hard, .good), (.good, .easy),
            (.again, .good), (.hard, .easy), (.again, .easy),
        ]
        for (lower, upper) in orderedPairs {
            if let low = known[lower], let high = known[upper], low > high {
                if counts[lower, default: 0] > counts[upper, default: 0] {
                    known[upper] = low
                } else {
                    known[lower] = high
                }
            }
        }
        guard !known.isEmpty else { return Parameters.defaults.prefix(4).map { $0 } }
        if known.count == 1, let (rating, value) = known.first {
            let factor = value / Parameters.defaults[Int(rating.rawValue - 1)]
            return Parameters.defaults.prefix(4).map { min(100, max(0.001, $0 * factor)) }
        }

        // Upstream uses geometric interpolation with these empirically fitted
        // positions. Log-linear interpolation gives the identical adjacent
        // formulas while also safely filling arbitrary missing combinations.
        let positions: [Float] = [0, 0.41, 0.41 + (1 - 0.41) * (1 - 0.54), 1]
        var output = [Float?](repeating: nil, count: 4)
        for (rating, value) in known { output[Int(rating.rawValue - 1)] = value }
        for index in output.indices where output[index] == nil {
            let lower = stride(from: index - 1, through: 0, by: -1).first { output[$0] != nil }
            let upper = (index + 1..<4).first { output[$0] != nil }
            switch (lower, upper) {
            case let (lower?, upper?):
                let fraction = (positions[index] - positions[lower]) / (positions[upper] - positions[lower])
                output[index] = exp(log(output[lower]!) * (1 - fraction) + log(output[upper]!) * fraction)
            case let (lower?, nil):
                let ratio = Parameters.defaults[index] / Parameters.defaults[lower]
                output[index] = output[lower]! * ratio
            case let (nil, upper?):
                let ratio = Parameters.defaults[index] / Parameters.defaults[upper]
                output[index] = output[upper]! * ratio
            default:
                output[index] = Parameters.defaults[index]
            }
        }
        var values = output.map { min(100, max(0.001, $0!)) }
        for index in 1..<values.count { values[index] = max(values[index], values[index - 1]) }
        return values
    }

    private static func loss(
        _ stability: Double,
        values: [Float: Aggregate],
        averageRecall: Float,
        defaultS: Float
    ) -> Double {
        let decay = -Double(Parameters.defaults[20])
        let factor = pow(0.9, 1 / decay) - 1
        var total = 0.0
        for (delta, aggregate) in values {
            let recall = (Double(aggregate.successes) + Double(averageRecall)) / Double(aggregate.count + 1)
            let prediction = pow(Double(delta) / stability * factor + 1, decay)
            total -= (recall * log(prediction) + (1 - recall) * log(1 - prediction)) * Double(aggregate.count)
        }
        return total + abs(stability - Double(defaultS)) / 16
    }

    private struct Aggregate { var successes = 0; var count = 0 }
}
