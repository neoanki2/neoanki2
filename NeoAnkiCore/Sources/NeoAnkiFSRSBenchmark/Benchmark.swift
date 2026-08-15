import Foundation
import NeoAnkiFSRS

@main
enum NeoAnkiFSRSBenchmark {
    static func main() throws {
        let events = try eventCount(from: CommandLine.arguments)
        let clock = ContinuousClock()
        let start = clock.now
        let examples = makeExamples(eventCount: events)
        let result = try Optimizer().computeParameters(examples: examples)
        let elapsed = clock.now - start
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18

        guard result.stage == .fullyOptimized else {
            throw BenchmarkError.didNotRunFullOptimizer
        }
        print(
            "events=\(events) targets=\(result.dataset.supervisedTargetCount) "
                + "seconds=\(String(format: "%.9f", seconds)) "
                + "log_loss=\(String(format: "%.9f", result.evaluation.logLoss)) "
                + "weight0=\(result.parameters.values[0])"
        )
    }

    private static func eventCount(from arguments: [String]) throws -> Int {
        guard let index = arguments.firstIndex(of: "--events"),
              arguments.indices.contains(index + 1),
              let value = Int(arguments[index + 1]),
              value >= 128
        else {
            throw BenchmarkError.usage
        }
        return value
    }

    /// Produces complete histories whose total unique review-event count is
    /// exactly `eventCount`. Training inputs use the same expanding prefixes as
    /// production dataset construction, including additional intraday context
    /// when the requested size is not divisible by three.
    private static func makeExamples(eventCount: Int) -> [TrainingExample] {
        let ordinaryCardCount = (eventCount - 4) / 3
        let trailingEventCount = eventCount - ordinaryCardCount * 3
        var examples: [TrainingExample] = []
        examples.reserveCapacity(ordinaryCardCount * 2 + 3)
        var order: Int64 = 0

        for card in 0..<ordinaryCardCount {
            let history = ordinaryHistory(card: card)
            appendTargets(history, cardID: String(format: "%08d", card), order: &order, to: &examples)
        }

        let trailingCard = ordinaryCardCount
        var trailing = ordinaryHistory(card: trailingCard)
        for _ in 0..<max(0, trailingEventCount - trailing.count) {
            trailing.insert(Review(rating: .good, deltaT: 0), at: 1)
        }
        appendTargets(
            trailing, cardID: String(format: "%08d", trailingCard), order: &order, to: &examples
        )
        return examples
    }

    private static func ordinaryHistory(card: Int) -> [Review] {
        [
            Review(rating: Rating.allCases[card % Rating.allCases.count], deltaT: 0),
            Review(rating: card.isMultiple(of: 5) ? .again : .good, deltaT: 2),
            Review(rating: card.isMultiple(of: 7) ? .hard : .good, deltaT: 5),
        ]
    }

    private static func appendTargets(
        _ history: [Review], cardID: String, order: inout Int64,
        to examples: inout [TrainingExample]
    ) {
        guard history.first?.deltaT == 0 else { return }
        for index in history.indices.dropFirst() where history[index].deltaT > 0 {
            examples.append(TrainingExample(
                cardID: cardID,
                item: Item(reviews: Array(history[...index])),
                order: order
            ))
            order += 1
        }
    }

    private enum BenchmarkError: Error, LocalizedError {
        case usage
        case didNotRunFullOptimizer

        var errorDescription: String? {
            switch self {
            case .usage:
                "Usage: neoanki-fsrs-benchmark --events <integer >= 128>"
            case .didNotRunFullOptimizer:
                "The benchmark dataset did not enter the full five-epoch optimizer."
            }
        }
    }
}
