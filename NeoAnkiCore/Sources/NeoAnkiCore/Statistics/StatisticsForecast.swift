import Foundation

public struct StatisticsForecastRequest: Sendable, Equatable {
    public var days = 30
    /// Nil preserves configured limits. Zero introduces no new cards.
    public var newCardsPerDay: Int?
    /// Nil preserves each card's effective retention.
    public var desiredRetention: Double?
    public var seed: UInt64 = 0x4E_454F_414E_4B49
    public init() {}
}
public struct StatisticsForecastPoint: Sendable, Identifiable {
    public var id: Date { date }
    public let date: Date
    public let median: Double
    public let lower: Double
    public let upper: Double
    public let minutes: Double?
    public let backlog: Double
    public let remembered: Double
}
public struct StatisticsForecast: Sendable {
    public let points: [StatisticsForecastPoint]
    public let usesGradeHistory: Bool
    public let durationSamples: Int
    public let runs: Int
    public let assumptions: String
}

public enum StatisticsSimulator {
    private struct Random {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
    }
    public static func simulate(
        snapshot: StatisticsSnapshot, decks: [Deck], request: StatisticsForecastRequest,
        rollover: Int, calendar: Calendar = .autoupdatingCurrent
    ) throws -> StatisticsForecast {
        let horizon = request.days <= 30 ? 30 : 90
        // Fixed runs make cached results reproducible. Bands describe model
        // outcomes, not uncertainty about whether the model itself is correct.
        let runs = 32
        let cards = snapshot.cards.filter { !$0.card.isSuspended }.sorted {
            $0.card.id.uuidString < $1.card.id.uuidString
        }
        let durations = snapshot.reviews.map(\.log.durationMs).filter(ReviewWorkloadTimingPolicy.isUsable)
            .map(Double.init)
        let seconds = StatisticsEngine.quantile(durations, 0.5).map { $0 / 1000 }
        let successes = snapshot.reviews.filter { $0.log.phaseBefore == .review && $0.log.rating != .again }
        let useHistory = successes.count >= 50
        let hardFraction =
            useHistory
            ? Double(successes.filter { $0.log.rating == .hard }.count) / Double(successes.count) : 0
        let easyFraction =
            useHistory
            ? Double(successes.filter { $0.log.rating == .easy }.count) / Double(successes.count) : 0
        let byID = Dictionary(uniqueKeysWithValues: decks.map { ($0.id, $0) })
        func ancestors(_ id: UUID?) -> [UUID] {
            var result: [UUID] = []
            var next = id
            while let id = next, !result.contains(id) {
                result.append(id)
                next = byID[id]?.parentID
            }
            return result
        }
        let limitChains = cards.map { ancestors($0.card.deckID) }
        var reviewRuns = Array(repeating: [Double](), count: horizon)
        var backlogRuns = reviewRuns
        var rememberedRuns = reviewRuns
        let today = StudyDay.start(for: snapshot.asOf, rolloverMinutes: rollover, calendar: calendar)
        for run in 0..<runs {
            try Task.checkCancellation()
            var random = Random(state: request.seed &+ UInt64(run))
            var memories = cards.map { $0.forecastMemory ?? $0.card.memory }
            let parameters = cards.map { entry -> FSRSScheduler.Parameters in
                var value = entry.forecastParameters ?? entry.parameters
                if let retention = request.desiredRetention {
                    value.requestRetention = min(0.99, max(0.01, retention))
                }
                return value
            }
            let schedulers = parameters.map { LearningScheduler(parameters: $0) }
            let engines = parameters.map { FSRSScheduler(parameters: $0) }
            for offset in 0..<horizon {
                try Task.checkCancellation()
                let start = calendar.date(byAdding: .day, value: offset, to: today)!
                let end = StudyDay.nextRollover(after: start, rolloverMinutes: rollover, calendar: calendar)
                var introduced: [UUID: Int] = [:]
                var globalIntroduced = 0
                var reviews = 0
                if offset == 0 {
                    let selectedIDs = Set(cards.map { $0.card.id })
                    for intro in snapshot.todayIntroductions {
                        for id in ancestors(intro.deckID) { introduced[id, default: 0] += 1 }
                        if selectedIDs.contains(intro.cardID) { globalIntroduced += 1 }
                    }
                }
                for i in cards.indices {
                    if i % 256 == 0 { try Task.checkCancellation() }
                    var memory = memories[i]
                    guard memory.due < end else { continue }
                    let isNew = memory.reps == 0 || memory.phase == .new
                    if isNew {
                        if let cap = request.newCardsPerDay, globalIntroduced >= max(0, cap) { continue }
                        if limitChains[i].contains(where: { id in
                            byID[id]?.newCardsPerDay.map { introduced[id, default: 0] >= $0 } ?? false
                        }) {
                            continue
                        }
                        for id in limitChains[i] { introduced[id, default: 0] += 1 }
                        globalIntroduced += 1
                    }
                    var instant = max(memory.due, start, snapshot.asOf)
                    // Production repair is immediate; after a failed prediction
                    // the model is refreshed and the next attempt is evaluated
                    // at its new state. No independent interval math lives here.
                    while instant < end {
                        let rating: ReviewRating
                        if memory.phase != .review {
                            rating = .good
                        } else if random.next() > engines[i].retrievability(of: memory, asOf: instant) {
                            rating = .again
                        } else {
                            let grade = random.next()
                            rating = grade < hardFraction ? .hard : grade > 1 - easyFraction ? .easy : .good
                        }
                        memory = schedulers[i].schedule(memory, rating: rating, now: instant)
                        if rating != .again && !cards[i].orderedWork {
                            memory = ReviewIntervalVariation.apply(
                                to: memory, cardID: cards[i].card.id, now: instant,
                                maximumIntervalDays: parameters[i].maximumInterval)
                        }
                        reviews += 1
                        let next = max(memory.due, instant.addingTimeInterval(max(1, seconds ?? 10)))
                        guard next > instant else { break }
                        instant = next
                    }
                    memories[i] = memory
                }
                reviewRuns[offset].append(Double(reviews))
                backlogRuns[offset].append(Double(memories.filter { $0.reps > 0 && $0.due < end }.count))
                var remembered = 0.0
                for i in cards.indices where memories[i].reps > 0 {
                    remembered += engines[i].retrievability(of: memories[i], asOf: end)
                }
                rememberedRuns[offset].append(remembered)
            }
        }
        let points = (0..<horizon).map { offset in
            let median = StatisticsEngine.quantile(reviewRuns[offset], 0.5) ?? 0
            return StatisticsForecastPoint(
                date: calendar.date(byAdding: .day, value: offset, to: today)!, median: median,
                lower: StatisticsEngine.quantile(reviewRuns[offset], 0.1) ?? 0,
                upper: StatisticsEngine.quantile(reviewRuns[offset], 0.9) ?? 0,
                minutes: seconds.map { median * $0 / 60 },
                backlog: StatisticsEngine.quantile(backlogRuns[offset], 0.5) ?? 0,
                remembered: StatisticsEngine.quantile(rememberedRuns[offset], 0.5) ?? 0)
        }
        return .init(
            points: points, usesGradeHistory: useHistory, durationSamples: durations.count, runs: runs,
            assumptions:
                "All due cards are studied each day. Current due dates are retained; changed retention applies after the next review. New cards respect deck and parent limits and available inventory. Acquisition and immediate repair assume Good. "
                + (useHistory
                    ? "Successful review grades use your selected history."
                    : "Insufficient successful review history: remembered answers assume Good.")
                + " Time uses median usable attempt duration; bands show model variation, not guarantees.")
    }
}
