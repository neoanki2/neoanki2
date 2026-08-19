import Foundation

public struct TrainingExample: Equatable, Sendable {
    public let cardID: String
    public let item: Item
    /// Global chronological order of the supervised target.
    public let order: Int64

    public init(cardID: String, item: Item, order: Int64 = 0) {
        self.cardID = cardID
        self.item = item
        self.order = order
    }
}

public struct PreparedDataset: Equatable, Sendable {
    public let initialization: [TrainingExample]
    public let training: [TrainingExample]
    public let excludedOutliers: Int

    public var supervisedTargetCount: Int { training.count }
    public var distinctCardCount: Int { Set(training.map(\.cardID)).count }
}

/// Builds expanding-prefix targets from complete card histories. Every review
/// after positive elapsed time becomes a supervised outcome; only a truly
/// immediate review remains sequence context without its own target.
public enum DatasetBuilder {
    public static func examples(cardID: String, history: [Review]) -> [TrainingExample] {
        guard history.first?.deltaT == 0 else { return [] }
        return history.indices.dropFirst().compactMap { index in
            guard history[index].deltaT > 0 else { return nil }
            return TrainingExample(
                cardID: cardID,
                item: Item(reviews: Array(history[...index])),
                order: Int64(index)
            )
        }
    }

    public static func prepare(_ examples: [TrainingExample]) -> PreparedDataset {
        let valid = examples.filter { example in
            guard example.item.reviews.count >= 2,
                  example.item.reviews.first?.deltaT == 0,
                  example.item.reviews.last?.deltaT ?? 0 > 0
            else { return false }
            return example.item.reviews.allSatisfy {
                (1...4).contains($0.rating.rawValue) && $0.deltaT.isFinite && $0.deltaT >= 0
            }
        }

        typealias Pair = PairKey
        var groups: [UInt32: [UInt32: [Int]]] = [:]
        for (index, example) in valid.enumerated() where example.item.longTermReviewCount == 1 {
            let first = example.item.reviews[0].rating.rawValue
            guard let delta = example.item.reviews.first(where: { $0.deltaT > 0 })?.deltaT else { continue }
            groups[first, default: [:]][initialIntervalBucket(delta), default: []].append(index)
        }

        var removed = Set<Pair>()
        var keptInitialization = Set<Int>()
        for rating in groups.keys.sorted() {
            let sorted = groups[rating, default: [:]].map { ($0.key, $0.value) }.sorted {
                $0.1.count != $1.1.count ? $0.1.count > $1.1.count : $0.0 > $1.0
            }
            let total = sorted.reduce(0) { $0 + $1.1.count }
            var removedCount = 0
            for (delta, indices) in sorted.reversed() {
                if removedCount + indices.count >= max(20, total / 20) {
                    let maximum: UInt32 = rating == Rating.easy.rawValue ? 365 : 100
                    if indices.count >= 6, delta <= maximum {
                        keptInitialization.formUnion(indices)
                    } else {
                        removed.insert(Pair(rating: rating, deltaT: delta))
                    }
                } else {
                    removedCount += indices.count
                    removed.insert(Pair(rating: rating, deltaT: delta))
                }
            }
        }

        let training = valid.filter { example in
            guard let first = example.item.reviews.first?.rating.rawValue,
                  let delta = example.item.reviews.first(where: { $0.deltaT > 0 })?.deltaT
            else { return false }
            return !removed.contains(Pair(rating: first, deltaT: initialIntervalBucket(delta)))
        }
        let initialization = keptInitialization.sorted().map { valid[$0] }
        return PreparedDataset(
            initialization: initialization,
            training: training,
            excludedOutliers: valid.count - training.count
        )
    }

    private struct PairKey: Hashable {
        let rating: UInt32
        let deltaT: UInt32
    }

    /// The outlier filter needs populated cohorts, while training itself keeps
    /// the exact elapsed value. Whole-day buckets preserve the reference
    /// behavior for integral histories and group sub-day observations safely.
    private static func initialIntervalBucket(_ delta: Float) -> UInt32 {
        guard delta.isFinite, delta > 0 else { return 0 }
        return UInt32(min(Double(UInt32.max), max(1, Double(delta).rounded())))
    }
}

public struct DatasetEligibility: Equatable, Sendable {
    public let targetCount: Int
    public let distinctCardCount: Int
    public let failureCount: Int
    public let eligibleForFullOptimization: Bool

    public init(dataset: PreparedDataset) {
        targetCount = dataset.training.count
        distinctCardCount = dataset.distinctCardCount
        failureCount = dataset.training.count { $0.item.reviews.last?.rating == .again }
        eligibleForFullOptimization = targetCount >= 64
    }
}
