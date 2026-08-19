import Foundation

public struct TrainingConfiguration: Equatable, Sendable {
    public var epochs = 5
    public var batchSize = 512
    public var seed: UInt64 = 2023
    public var learningRate = 0.04
    public var maximumSequenceLength = 256
    public var regularizationGamma = 1.0
    public init() {}
}

public enum OptimizationStage: Equatable, Sendable {
    case populationDefaults
    case initializedStability
    case fullyOptimized
}

public struct OptimizationResult: Equatable, Sendable {
    public let parameters: Parameters
    public let stage: OptimizationStage
    public let dataset: PreparedDataset
    public let evaluation: ModelEvaluation
}

public struct Optimizer: Sendable {
    public let configuration: TrainingConfiguration
    public init(configuration: TrainingConfiguration = .init()) { self.configuration = configuration }

    public func computeParameters(examples: [TrainingExample]) throws -> OptimizationResult {
        guard !examples.isEmpty else { throw FSRSError.notEnoughData }
        let dataset = DatasetBuilder.prepare(examples.sorted { $0.order < $1.order })
        if dataset.training.count < 8 {
            let evaluationData = dataset.training.isEmpty ? Array(examples.prefix(1)) : dataset.training
            return try makeResult(.population, .populationDefaults, dataset, evaluationData)
        }
        let averageRecall = Float(dataset.training.count { $0.item.reviews.last?.rating != .again })
            / Float(dataset.training.count)
        let initialStability = try StabilityInitializer.initialize(
            from: dataset.initialization, averageRecall: averageRecall
        )
        var initialValues = Parameters.defaults
        initialValues.replaceSubrange(0..<4, with: initialStability)
        let initialized = try Parameters(initialValues)
        if dataset.training.count == dataset.initialization.count || dataset.training.count < 64 {
            return try makeResult(initialized, .initializedStability, dataset, dataset.training)
        }

        let trainSet = weighted(dataset.training.filter {
            $0.item.reviews.count <= configuration.maximumSequenceLength
        })
        guard !trainSet.isEmpty else { throw FSRSError.notEnoughData }
        let batches = buildWindowedBatches(trainSet, maximumPredictions: configuration.batchSize)
        var values = initialized.values
        var adam = Adam()
        let iterationCount = (trainSet.count / configuration.batchSize + 1) * configuration.epochs
        var annealing = CosineAnnealing(
            maximum: Double(iterationCount), initialRate: configuration.learningRate
        )
        var random = RandCompatibleRandom(seed: configuration.seed)
        var order = Array(batches.indices)
        for _ in 0..<configuration.epochs {
            for index in order.indices { order[index] = index }
            random.shuffle(&order)
            for batchIndex in order {
                let batch = batches[batchIndex]
                var gradient = [Double](repeating: 0, count: 21)
                _ = Analytic.cardLossAndGradient(
                    weights: values, timeHistory: batch.times, ratingHistory: batch.ratings,
                    sequenceLength: batch.sequenceLength, batchSize: batch.batchSize,
                    sequenceLengths: batch.columnLengths, labels: batch.labels,
                    exampleWeights: batch.weights, gradient: &gradient
                )
                addRegularization(
                    &gradient, values, initialized.values,
                    batch.realBatchSize, trainSet.count, configuration.regularizationGamma
                )
                adam.step(&values, gradient, annealing.step())
                values = ParameterClipper.clip(values)
            }
        }
        let ratingCounts = Dictionary(grouping: dataset.initialization) {
            $0.item.reviews.first!.rating
        }.mapValues(\.count)
        let stabilityByRating = Dictionary(uniqueKeysWithValues: Rating.allCases.map {
            ($0, values[Int($0.rawValue - 1)])
        })
        values.replaceSubrange(
            0..<4,
            with: StabilityInitializer.smoothAndFill(stabilityByRating, counts: ratingCounts)
        )
        return try makeResult(Parameters(values), .fullyOptimized, dataset, dataset.training)
    }

    private func makeResult(
        _ parameters: Parameters, _ stage: OptimizationStage,
        _ dataset: PreparedDataset, _ evaluationData: [TrainingExample]
    ) throws -> OptimizationResult {
        OptimizationResult(
            parameters: parameters, stage: stage, dataset: dataset,
            evaluation: try FSRS(parameters: parameters).evaluate(evaluationData)
        )
    }
}

struct WeightedExample {
    let example: TrainingExample
    let weight: Float
}

struct HostBatch {
    let sequenceLength, batchSize, realBatchSize: Int
    let columnLengths: [Int]
    let times, ratings, labels, weights: [Float]
}

func weighted(_ examples: [TrainingExample]) -> [WeightedExample] {
    let sorted = examples.sorted { lhs, rhs in
        lhs.order != rhs.order ? lhs.order < rhs.order : lhs.cardID < rhs.cardID
    }
    let denominator = max(Float(sorted.count - 1), 1)
    return sorted.enumerated().map { index, example in
        WeightedExample(
            example: example,
            weight: 0.25 + 0.75 * pow(Float(index) / denominator, 3)
        )
    }
}

func buildWindowedBatches(
    _ examples: [WeightedExample], maximumPredictions: Int
) -> [HostBatch] {
    let grouped = Dictionary(grouping: examples) { $0.example.cardID }
    var cards = grouped.keys.sorted().map { key in
        grouped[key]!.sorted { $0.example.item.reviews.count < $1.example.item.reviews.count }
    }
    cards.sort { lhs, rhs in
        let leftLength = lhs.last!.example.item.reviews.count
        let rightLength = rhs.last!.example.item.reviews.count
        return leftLength != rightLength
            ? leftLength < rightLength
            : lhs[0].example.cardID < rhs[0].example.cardID
    }
    var partitions: [[[WeightedExample]]] = []
    var current: [[WeightedExample]] = []
    var predictions = 0
    for card in cards {
        if !current.isEmpty && predictions + card.count > maximumPredictions {
            partitions.append(current); current = []; predictions = 0
        }
        predictions += card.count
        current.append(card)
    }
    if !current.isEmpty { partitions.append(current) }
    return partitions.map(buildWindowedBatch)
}

private func buildWindowedBatch(_ cards: [[WeightedExample]]) -> HostBatch {
    let batchSize = cards.count
    let sequenceLength = cards.map { $0.last!.example.item.reviews.count }.max()!
    let realBatchSize = cards.reduce(0) { $0 + $1.count }
    var times = [Float](repeating: 0, count: sequenceLength * batchSize)
    var ratings = [Float](repeating: 0, count: sequenceLength * batchSize)
    var labels = [Float](repeating: 0, count: sequenceLength * batchSize)
    var weights = [Float](repeating: 0, count: sequenceLength * batchSize)
    var lengths: [Int] = []
    for (column, card) in cards.enumerated() {
        let full = card.last!.example.item.reviews
        lengths.append(full.count)
        for (time, review) in full.enumerated() {
            let index = time * batchSize + column
            times[index] = review.deltaT
            ratings[index] = Float(review.rating.rawValue)
        }
        for weighted in card {
            let currentIndex = weighted.example.item.reviews.count - 1
            let index = currentIndex * batchSize + column
            labels[index] = weighted.example.item.reviews.last!.rating == .again ? 0 : 1
            weights[index] = weighted.weight
        }
    }
    return HostBatch(
        sequenceLength: sequenceLength, batchSize: batchSize, realBatchSize: realBatchSize,
        columnLengths: lengths, times: times, ratings: ratings, labels: labels, weights: weights
    )
}

private let parameterStandardDeviations: [Float] = [
    6.43, 9.66, 17.58, 27.85, 0.57, 0.28, 0.6, 0.12, 0.39, 0.18,
    0.33, 0.3, 0.09, 0.16, 0.57, 0.25, 1.03, 0.31, 0.32, 0.14, 0.27,
]

private func addRegularization(
    _ gradient: inout [Double], _ values: [Float], _ initial: [Float],
    _ batchSize: Int, _ totalSize: Int, _ gamma: Double
) {
    let scale = gamma * Double(batchSize) / Double(totalSize)
    for index in gradient.indices {
        let difference = Double(values[index] - initial[index])
        gradient[index] += 2 * difference
            / Double(parameterStandardDeviations[index] * parameterStandardDeviations[index]) * scale
    }
}

struct Adam {
    var first = [Double](repeating: 0, count: 21)
    var second = [Double](repeating: 0, count: 21)
    var time = 0
    mutating func step(_ values: inout [Float], _ gradient: [Double], _ rate: Double) {
        time += 1
        let firstBias = 1 - pow(0.9, Double(time))
        let secondBias = 1 - pow(0.999, Double(time))
        for index in values.indices {
            first[index] = 0.9 * first[index] + 0.1 * gradient[index]
            second[index] = 0.999 * second[index] + 0.001 * gradient[index] * gradient[index]
            let update = rate * (first[index] / firstBias)
                / (sqrt(second[index] / secondBias) + 1e-8)
            values[index] -= Float(update)
        }
    }
}

struct CosineAnnealing {
    let maximum, initialRate: Double
    var stepCount = -1.0
    var currentRate: Double
    init(maximum: Double, initialRate: Double) {
        self.maximum = maximum; self.initialRate = initialRate; currentRate = initialRate
    }
    mutating func step() -> Double {
        stepCount += 1
        if stepCount == 0 { currentRate = initialRate }
        else if (stepCount - 1 - maximum).truncatingRemainder(dividingBy: 2 * maximum) == 0 {
            currentRate = initialRate * (1 - cos(.pi / maximum)) / 2
        } else {
            currentRate = (1 + cos(.pi * stepCount / maximum))
                / (1 + cos(.pi * (stepCount - 1) / maximum)) * currentRate
        }
        return currentRate
    }
}
