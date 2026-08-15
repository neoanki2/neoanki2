import Foundation

public struct ModelEvaluation: Equatable, Sendable {
    public let logLoss: Double
    public let brierScore: Double
    public let rmseBins: Double
    public let observationCount: Int
}

extension FSRS {
    public func evaluate(_ examples: [TrainingExample]) throws -> ModelEvaluation {
        guard !examples.isEmpty else { throw FSRSError.notEnoughData }
        let count = max(Float(examples.count - 1), 1)
        var loss = 0.0
        var brier = 0.0
        var weightSum = 0.0
        struct Bin: Hashable { let delta: UInt32; let length: UInt32; let lapses: UInt32 }
        var bins: [Bin: (prediction: Double, actual: Double, count: Double, weight: Double)] = [:]

        for (index, example) in examples.enumerated() {
            let reviews = example.item.reviews
            guard reviews.count >= 2, let current = reviews.last else { continue }
            let state = try memoryState(item: Item(reviews: Array(reviews.dropLast())))
            let prediction = min(1 - 1e-7, max(1e-7, retrievability(state: state, daysElapsed: current.deltaT)))
            let label: Float = current.rating == .again ? 0 : 1
            let weight = 0.25 + 0.75 * pow(Float(index) / count, 3)
            loss -= Double((label * log(prediction) + (1 - label) * log(1 - prediction)) * weight)
            brier += Double((prediction - label) * (prediction - label) * weight)
            weightSum += Double(weight)

            let deltaBin = Self.geometricBin(Double(current.deltaT), scale: 2.48, base: 3.62)
            let lengthBin = Self.geometricBin(Double(example.item.longTermReviewCount) + 1, scale: 1.99, base: 1.89)
            let lapseCount = reviews.dropLast().count { $0.deltaT > 0 && $0.rating == .again }
            let lapseBin = lapseCount == 0 ? 0 : Self.geometricBin(Double(lapseCount), scale: 1.65, base: 1.73)
            let key = Bin(delta: deltaBin, length: lengthBin, lapses: lapseBin)
            let previous = bins[key] ?? (0, 0, 0, 0)
            bins[key] = (
                previous.prediction + Double(prediction),
                previous.actual + Double(label),
                previous.count + 1,
                previous.weight + Double(weight)
            )
        }
        guard weightSum > 0 else { throw FSRSError.notEnoughData }
        let rmseNumerator = bins.values.reduce(0.0) { partial, bin in
            let predicted = bin.prediction / bin.count
            let actual = bin.actual / bin.count
            return partial + (predicted - actual) * (predicted - actual) * bin.weight
        }
        let rmseDenominator = bins.values.reduce(0.0) { $0 + $1.weight }
        return ModelEvaluation(
            logLoss: loss / weightSum,
            brierScore: brier / weightSum,
            rmseBins: sqrt(rmseNumerator / rmseDenominator),
            observationCount: examples.count
        )
    }

    private static func geometricBin(_ value: Double, scale: Double, base: Double) -> UInt32 {
        guard value > 0 else { return 0 }
        return UInt32(max(0, (scale * pow(base, floor(log(value) / log(base)))).rounded()))
    }
}
