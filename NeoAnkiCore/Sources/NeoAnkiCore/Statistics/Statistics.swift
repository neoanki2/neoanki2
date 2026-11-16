import Foundation

public enum StatisticsSection: String, CaseIterable, Sendable, Identifiable {
    case overview = "Overview"
    case activity = "Activity"
    case memory = "Memory"
    case workload = "Workload"
    public var id: Self { self }
}

public enum StatisticsPeriod: String, CaseIterable, Sendable, Identifiable {
    case today = "Today"
    case week = "7 Days"
    case month = "30 Days"
    case quarter = "90 Days"
    case year = "Year"
    case all = "All Time"
    case custom = "Custom"
    public var id: Self { self }
    public var days: Int? {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .year: 365
        default: nil
        }
    }
}

public struct StatisticsQuery: Sendable, Equatable {
    public var scope: DeckScope = .allDecks
    public var period: StatisticsPeriod = .month
    public var customStart = Date.now.addingTimeInterval(-30 * 86_400)
    public var customEnd = Date.now
    public var itemTypeID: UUID?
    public var templateID: UUID?
    public var skill: String?
    public var interaction: String?
    public var sessionID: UUID?
    public var studyTimeAttribution = false
    public var heatmapYear: Int?
    public init(scope: DeckScope = .allDecks, sessionID: UUID? = nil) {
        self.scope = scope
        self.sessionID = sessionID
        if sessionID != nil { period = .all }
    }
    public static func == (a: Self, b: Self) -> Bool {
        a.scope == b.scope && a.period == b.period
            && (a.period != .custom || (a.customStart == b.customStart && a.customEnd == b.customEnd))
            && a.itemTypeID == b.itemTypeID && a.templateID == b.templateID && a.skill == b.skill
            && a.interaction == b.interaction && a.sessionID == b.sessionID
            && a.studyTimeAttribution == b.studyTimeAttribution && a.heatmapYear == b.heatmapYear
    }
    public func range(now: Date, rollover: Int, calendar: Calendar) -> DateInterval {
        if period == .custom {
            let first = min(customStart, customEnd)
            let last = max(customStart, customEnd)
            let start = StudyDay.start(
                for: calendar.startOfDay(for: first).addingTimeInterval(12 * 3600), rolloverMinutes: rollover,
                calendar: calendar)
            let finalDay = StudyDay.start(
                for: calendar.startOfDay(for: last).addingTimeInterval(12 * 3600), rolloverMinutes: rollover,
                calendar: calendar)
            return DateInterval(
                start: min(start, now),
                end: min(
                    StudyDay.nextRollover(after: finalDay, rolloverMinutes: rollover, calendar: calendar), now
                ))
        }
        let start = StudyDay.start(for: now, rolloverMinutes: rollover, calendar: calendar)
        return DateInterval(
            start: period.days.flatMap { calendar.date(byAdding: .day, value: 1 - $0, to: start) }
                ?? Date(timeIntervalSince1970: 0), end: now)
    }
}

/// Immutable evidence has no foreign keys to live content. Deleting a card must
/// not erase the work already done. Context is a separate event, never a rewrite.
public struct StatisticsEvent: Codable, Sendable, Equatable, Identifiable {
    private struct Payload: Codable, Sendable, Equatable {
        var id: String
        var kind: String
        var occurredAt: Date
        var cardID: UUID
        var sourceLibraryID: UUID?
        var itemID: UUID?
        var deckID: UUID?
        var itemTypeID: UUID?
        var templateID: UUID?
        var skill: String?
        var interaction: String?
        var log: ReviewLog?
        var memoryBefore: MemoryState?
        var memoryAfter: MemoryState?
        var suspended: Bool
        var sessionID: UUID?
        var deviceID: UUID?
        var promptMilliseconds: Int64?
        var answerMilliseconds: Int64?
        var checkedCorrect: Bool?
    }
    // A history can contain millions of facts. Copy-on-write keeps sorting,
    // filtering and snapshots from repeatedly copying the entire audit payload.
    // Mutations always detach before writing, preserving value semantics across tasks.
    private final class Storage: @unchecked Sendable {
        var payload: Payload
        init(_ payload: Payload) { self.payload = payload }
    }
    private var storage: Storage
    private mutating func update<T>(_ key: WritableKeyPath<Payload, T>, _ value: T) {
        if !isKnownUniquelyReferenced(&storage) { storage = Storage(storage.payload) }
        storage.payload[keyPath: key] = value
    }
    public var id: String {
        get { storage.payload.id }
        set { update(\.id, newValue) }
    }
    public var kind: String {
        get { storage.payload.kind }
        set { update(\.kind, newValue) }
    }
    public var occurredAt: Date {
        get { storage.payload.occurredAt }
        set { update(\.occurredAt, newValue) }
    }
    public var cardID: UUID {
        get { storage.payload.cardID }
        set { update(\.cardID, newValue) }
    }
    public var sourceLibraryID: UUID? {
        get { storage.payload.sourceLibraryID }
        set { update(\.sourceLibraryID, newValue) }
    }
    public var itemID: UUID? {
        get { storage.payload.itemID }
        set { update(\.itemID, newValue) }
    }
    public var deckID: UUID? {
        get { storage.payload.deckID }
        set { update(\.deckID, newValue) }
    }
    public var itemTypeID: UUID? {
        get { storage.payload.itemTypeID }
        set { update(\.itemTypeID, newValue) }
    }
    public var templateID: UUID? {
        get { storage.payload.templateID }
        set { update(\.templateID, newValue) }
    }
    public var skill: String? {
        get { storage.payload.skill }
        set { update(\.skill, newValue) }
    }
    public var interaction: String? {
        get { storage.payload.interaction }
        set { update(\.interaction, newValue) }
    }
    public var log: ReviewLog? {
        get { storage.payload.log }
        set { update(\.log, newValue) }
    }
    public var memoryBefore: MemoryState? {
        get { storage.payload.memoryBefore }
        set { update(\.memoryBefore, newValue) }
    }
    public var memoryAfter: MemoryState? {
        get { storage.payload.memoryAfter }
        set { update(\.memoryAfter, newValue) }
    }
    public var suspended: Bool {
        get { storage.payload.suspended }
        set { update(\.suspended, newValue) }
    }
    public var sessionID: UUID? {
        get { storage.payload.sessionID }
        set { update(\.sessionID, newValue) }
    }
    public var deviceID: UUID? {
        get { storage.payload.deviceID }
        set { update(\.deviceID, newValue) }
    }
    public var promptMilliseconds: Int64? {
        get { storage.payload.promptMilliseconds }
        set { update(\.promptMilliseconds, newValue) }
    }
    public var answerMilliseconds: Int64? {
        get { storage.payload.answerMilliseconds }
        set { update(\.answerMilliseconds, newValue) }
    }
    public var checkedCorrect: Bool? {
        get { storage.payload.checkedCorrect }
        set { update(\.checkedCorrect, newValue) }
    }
    public init(
        id: String, kind: String, occurredAt: Date, cardID: UUID, itemID: UUID? = nil, deckID: UUID? = nil,
        itemTypeID: UUID? = nil, templateID: UUID? = nil, skill: String? = nil, interaction: String? = nil,
        log: ReviewLog? = nil, memoryBefore: MemoryState? = nil, memoryAfter: MemoryState? = nil,
        suspended: Bool = false, sourceLibraryID: UUID? = nil, sessionID: UUID? = nil, deviceID: UUID? = nil,
        promptMilliseconds: Int64? = nil, answerMilliseconds: Int64? = nil, checkedCorrect: Bool? = nil
    ) {
        storage = Storage(
            Payload(
                id: id, kind: kind, occurredAt: occurredAt, cardID: cardID, sourceLibraryID: sourceLibraryID,
                itemID: itemID, deckID: deckID, itemTypeID: itemTypeID, templateID: templateID, skill: skill,
                interaction: interaction, log: log, memoryBefore: memoryBefore, memoryAfter: memoryAfter,
                suspended: suspended, sessionID: sessionID, deviceID: deviceID,
                promptMilliseconds: promptMilliseconds, answerMilliseconds: answerMilliseconds,
                checkedCorrect: checkedCorrect))
    }
    public init(from decoder: Decoder) throws { storage = Storage(try Payload(from: decoder)) }
    public func encode(to encoder: Encoder) throws { try storage.payload.encode(to: encoder) }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.storage.payload == rhs.storage.payload }
}
public struct StatisticsStoredEvent: Sendable {
    public let sequence: Int64
    public let event: StatisticsEvent
}
public struct StatisticsCard: Sendable {
    public let card: Card
    public let itemTypeID: UUID
    public let interaction: String
    public let maintaining: Bool
    public let parameters: FSRSScheduler.Parameters
    public let newCardsPerDay: Int?
    public var forecastParameters: FSRSScheduler.Parameters? = nil
    public var forecastMemory: MemoryState? = nil
    public var orderedWork = false
}
public struct StatisticsIntroduction: Sendable {
    public let cardID: UUID
    public let deckID: UUID?
    public let studyDay: String
}
public struct StatisticsSource: Sendable {
    public var introductions: [StatisticsIntroduction] = []
    public var events: [StatisticsEvent]
    public var segments: [LearningTimeSegment]
    public var cards: [StatisticsCard]
    public var decks: [Deck]
    public var itemDecks: [UUID: UUID]
    public var liveItems: Set<UUID>
    public var deletedItems: Set<UUID>
    public var aliases: [LearningTimeItemAlias]
    public var trackingStartedAt: Date?
    public var rollover: Int
    public var itemTypeNames: [UUID: String]
    public var templateNames: [UUID: String]
}
public struct StatisticsCoverage: Sendable {
    public let historyStartedAt: Date?
    public let progressStartedAt: Date?
    public let timeStartedAt: Date?
    public let unknownReviewCount: Int
    public let pendingMilliseconds: Int64
}
public struct StatisticsPoint: Sendable, Identifiable {
    public let id: String
    public let date: Date
    public let intervalEnd: Date?
    public let series: String
    public var value: Double
    public var count: Int
    public init(date: Date, series: String, value: Double, count: Int = 0, intervalEnd: Date? = nil) {
        id = "\(date.timeIntervalSince1970):\(series)"
        self.date = date
        self.intervalEnd = intervalEnd
        self.series = series
        self.value = value
        self.count = count
    }
}
public struct StatisticsBin: Sendable, Identifiable {
    public var id: String { label }
    public let label: String
    public let value: Double
    public let count: Int
    public let cardIDs: [UUID]
    public init(_ label: String, _ value: Double, count: Int = 0, cardIDs: [UUID] = []) {
        self.label = label
        self.value = value
        self.count = count
        self.cardIDs = cardIDs
    }
}
public final class StatisticsReview: Sendable, Identifiable {
    public var id: UUID { log.id }
    public let log: ReviewLog
    public let itemID: UUID?
    public let deckName: String
    public let skill: String
    public let interaction: String
    public let sessionID: UUID?
    public let before: MemoryState?
    public let after: MemoryState?
    public let promptMilliseconds: Int64?
    public let answerMilliseconds: Int64?
    public let checkedCorrect: Bool?
    public init(
        log: ReviewLog, itemID: UUID?, deckName: String, skill: String, interaction: String, sessionID: UUID?,
        before: MemoryState?, after: MemoryState?, promptMilliseconds: Int64?, answerMilliseconds: Int64?,
        checkedCorrect: Bool?
    ) {
        self.log = log
        self.itemID = itemID
        self.deckName = deckName
        self.skill = skill
        self.interaction = interaction
        self.sessionID = sessionID
        self.before = before
        self.after = after
        self.promptMilliseconds = promptMilliseconds
        self.answerMilliseconds = answerMilliseconds
        self.checkedCorrect = checkedCorrect
    }
}
public struct StatisticsSession: Sendable, Identifiable {
    public let id: UUID
    public let date: Date
    public let milliseconds: Int64
    public let reviews: Int
    public let cards: Int
    public let items: Int
    public let submissions: Int
}
public struct StatisticsSnapshot: Sendable {
    public let todayIntroductions: [StatisticsIntroduction]
    public let range: DateInterval
    public let asOf: Date
    public let reviews: [StatisticsReview]
    public let attentionReviews: [StatisticsReview]
    public let reviewCount: Int
    public let distinctCards: Int
    public let distinctItems: Int
    public let activeMilliseconds: Int64
    public let previousReviews: Int
    public let previousMilliseconds: Int64
    public let currentStreak: Int
    public let longestStreak: Int
    public let activeDays: Int
    public let recallPassed: Int
    public let recallTotal: Int
    public let recallLower: Double?
    public let recallUpper: Double?
    public let durationMedian: Double?
    public let durationP90: Double?
    public let excludedDurations: Int
    public let estimatedRemembered: Double
    public let daily: [StatisticsPoint]
    public let heatmap: [StatisticsPoint]
    public let timeHeatmap: [StatisticsPoint]
    public let recall: [StatisticsPoint]
    public let progress: [StatisticsPoint]
    public let cohorts: [StatisticsPoint]
    public let hours: [StatisticsPoint]
    public let phases: [StatisticsBin]
    public let grades: [StatisticsBin]
    public let stability: [StatisticsBin]
    public let difficulty: [StatisticsBin]
    public let retrievability: [StatisticsBin]
    public let intervals: [StatisticsBin]
    public let lapses: [StatisticsBin]
    public let durations: [StatisticsBin]
    public let backlog: [StatisticsBin]
    public let calibration: [StatisticsBin]
    public let latenessRecall: [StatisticsBin]
    public let intervalRecall: [StatisticsBin]
    public let skillComparisons: [StatisticsBin]
    public let methodComparisons: [StatisticsBin]
    public let milestoneDurations: [StatisticsBin]
    public let comparisons: [StatisticsBin]
    public let due: [StatisticsPoint]
    public let sessions: [StatisticsSession]
    public let cards: [StatisticsCard]
    public let coverage: StatisticsCoverage
    public let itemTypeNames: [UUID: String]
    public let templateNames: [UUID: String]
    public let decks: [Deck]
    public let skills: [String]
    public let interactions: [String]
    public var observedRecall: Double? { recallTotal == 0 ? nil : Double(recallPassed) / Double(recallTotal) }
    public var csv: String {
        let pointRows =
            daily + recall + progress + due
            + heatmap.map { StatisticsPoint(date: $0.date, series: "Calendar reviews", value: $0.value) }
            + timeHeatmap.map { StatisticsPoint(date: $0.date, series: "Calendar minutes", value: $0.value) }
            + cohorts.map {
                StatisticsPoint(
                    date: $0.date, series: "Cohort month \($0.series)", value: $0.value, count: $0.count)
            }
        var result = StatisticsExport.points(pointRows)
        let groups: [(String, [StatisticsBin])] = [
            ("Card progress", phases), ("Grades", grades), ("Stability", stability),
            ("Difficulty", difficulty), ("Retrievability", retrievability), ("Intervals", intervals),
            ("Lapses", lapses), ("Durations", durations), ("Backlog", backlog), ("Calibration", calibration),
            ("Lateness recall", latenessRecall), ("Interval recall", intervalRecall), ("Decks", comparisons),
            ("Skills", skillComparisons), ("Answer methods", methodComparisons),
            ("Milestones", milestoneDurations),
        ]
        for (name, bins) in groups { result += StatisticsExport.bins(bins, title: name, header: false) }
        for session in sessions {
            for (label, value) in [
                ("Active milliseconds", Double(session.milliseconds)), ("Reviews", Double(session.reviews)),
                ("Cards", Double(session.cards)), ("Items", Double(session.items)),
                ("Responses", Double(session.submissions)),
            ] {
                result +=
                    "\n\(session.date.ISO8601Format()),\(StatisticsExport.escape("Session \(session.id): \(label)")),\(value),1"
            }
        }
        return result
    }
}

public struct StatisticsReviewContext: Sendable {
    public let sessionID: UUID
    public let deviceID: UUID
    public let promptMilliseconds: Int64
    public let answerMilliseconds: Int64
    public let checkedCorrect: Bool?
    public init(
        sessionID: UUID, deviceID: UUID, promptMilliseconds: Int64, answerMilliseconds: Int64,
        checkedCorrect: Bool? = nil
    ) {
        self.sessionID = sessionID
        self.deviceID = deviceID
        self.promptMilliseconds = promptMilliseconds
        self.answerMilliseconds = answerMilliseconds
        self.checkedCorrect = checkedCorrect
    }
}
public enum StatisticsCapture {
    /// Task-local context crosses actor boundaries with the grading transaction;
    /// API clients simply omit it. Recording it cannot fail after a grade commits.
    @TaskLocal public static var context: StatisticsReviewContext?
}

public enum StatisticsExport {
    public static func escape(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    public static func points(_ points: [StatisticsPoint]) -> String {
        "date,series,value,samples\n"
            + points.map { "\($0.date.ISO8601Format()),\(escape($0.series)),\($0.value),\($0.count)" }.joined(
                separator: "\n")
    }
    public static func bins(_ bins: [StatisticsBin], title: String, header: Bool = true) -> String {
        (header ? "date,series,value,samples" : "")
            + bins.map { "\n,\(escape(title+": "+$0.label)),\($0.value),\($0.count)" }.joined()
    }
    public static func forecast(_ forecast: StatisticsForecast, prefix: String = "") -> String {
        let rows = forecast.points.flatMap { point in
            [
                ("Median reviews", point.median), ("10th percentile", point.lower),
                ("90th percentile", point.upper), ("Backlog", point.backlog),
                ("Estimated remembered", point.remembered),
            ].map { StatisticsPoint(date: point.date, series: prefix + $0.0, value: $0.1) }
                + (point.minutes.map {
                    [StatisticsPoint(date: point.date, series: prefix + "Estimated minutes", value: $0)]
                } ?? [])
        }
        return points(rows)
    }
}
