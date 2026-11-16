import Foundation

/// All platforms consume this projection. Calendar boundaries, denominators and
/// missing-data handling must never be duplicated in chart views.
private struct StatisticsRecallKey: Hashable {
    let cardID: UUID
    let day: Date
}

public enum StatisticsEngine {
    public static func quantile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let position = Double(values.count - 1) * min(1, max(0, fraction))
        let low = Int(position)
        let high = min(sorted.count - 1, Int(ceil(position)))
        return sorted[low] + (sorted[high] - sorted[low]) * (position - Double(low))
    }
    public static func wilson(passed: Int, total: Int) -> (Double?, Double?) {
        guard total > 0 else { return (nil, nil) }
        let n = Double(total)
        let p = Double(passed) / n
        let z = 1.96
        let denominator = 1 + z * z / n
        let center = (p + z * z / (2 * n)) / denominator
        let radius = z * sqrt((p * (1 - p) + z * z / (4 * n)) / n) / denominator
        return (max(0, center - radius), min(1, center + radius))
    }
    public static func snapshot(
        source: StatisticsSource, query: StatisticsQuery, now: Date, calendar: Calendar = .autoupdatingCurrent
    ) -> StatisticsSnapshot {
        let range = query.range(now: now, rollover: source.rollover, calendar: calendar)
        let calendarYear = query.heatmapYear ?? calendar.component(.year, from: now)
        let heatStart = calendar.date(from: DateComponents(year: calendarYear, month: 1, day: 1))!
        let heatEnd = calendar.date(byAdding: .year, value: 1, to: heatStart)!
        var heatMinutes: [Date: Double] = [:]
        let prior = DateInterval(start: range.start.addingTimeInterval(-range.duration), end: range.start)
        let deckNames = Dictionary(uniqueKeysWithValues: source.decks.map { ($0.id, $0.name) })
        let itemAliases = Dictionary(
            source.aliases.map { ($0.id, $0.resolvedItemID) }, uniquingKeysWith: { a, _ in a })
        let cardLookup = Dictionary(uniqueKeysWithValues: source.cards.map { ($0.card.id, $0) })
        var deckIDs: Set<UUID> = []
        if case .deck(let id, let descendants) = query.scope {
            deckIDs.insert(id)
            if descendants {
                var changed = true
                while changed {
                    let before = deckIDs.count
                    for deck in source.decks where deck.parentID.map(deckIDs.contains) == true {
                        deckIDs.insert(deck.id)
                    }
                    changed = before != deckIDs.count
                }
            }
        }
        func matchesScope(item: UUID?, deck: UUID?, forceCurrent: Bool = false) -> Bool {
            let current = item.flatMap { source.itemDecks[$0] }
            let assigned = query.studyTimeAttribution && !forceCurrent ? deck : current
            switch query.scope {
            case .allDecks: return true
            case .unassigned: return item.map(source.liveItems.contains) == true && assigned == nil
            case .deck: return assigned.map(deckIDs.contains) == true
            }
        }
        func matches(_ type: UUID?, _ template: UUID?, _ skill: String?, _ interaction: String?) -> Bool {
            (query.itemTypeID == nil || type == query.itemTypeID)
                && (query.templateID == nil || template == query.templateID)
                && (query.skill == nil || (skill ?? "Unknown") == query.skill)
                && (query.interaction == nil || (interaction ?? "Unknown") == query.interaction)
        }
        let identityAliases = Dictionary(
            source.events.filter { $0.kind == "alias" }.map { ($0.id, $0.itemID) },
            uniquingKeysWith: { a, _ in a })
        func mapped(_ id: UUID?, _ kind: String, _ sourceID: UUID?) -> UUID? {
            guard let id, let sourceID else { return id }
            return identityAliases["alias:\(sourceID):\(kind):\(id)"] ?? id
        }
        let normalizedEvents =
            identityAliases.isEmpty
            ? source.events
            : source.events.map { event -> StatisticsEvent in
                var value = event
                let sourceID = event.sourceLibraryID
                value.cardID = mapped(event.cardID, "card", sourceID) ?? event.cardID
                value.itemID = mapped(event.itemID, "item", sourceID)
                value.deckID = mapped(event.deckID, "deck", sourceID)
                value.itemTypeID = mapped(event.itemTypeID, "itemType", sourceID)
                if event.kind == "undo" || event.kind == "legacyExcluded" {
                    value.templateID = mapped(event.templateID, "review", sourceID)
                }
                if let log = event.log {
                    let id = mapped(log.id, "review", sourceID) ?? log.id
                    value.log = ReviewLog(
                        id: id, cardID: value.cardID, reviewedAt: log.reviewedAt, rating: log.rating,
                        elapsedDays: log.elapsedDays, scheduledDays: log.scheduledDays,
                        phaseBefore: log.phaseBefore, durationMs: log.durationMs,
                        schedulingAudit: log.schedulingAudit)
                    value.id = "review:" + id.uuidString
                }
                if event.kind == "context",
                    let id = UUID(uuidString: event.id.replacingOccurrences(of: "context:", with: ""))
                {
                    value.id = "context:" + (mapped(id, "review", sourceID) ?? id).uuidString
                }
                return value
            }
        let context = Dictionary(
            normalizedEvents.filter { $0.kind == "context" }.map {
                ($0.id.replacingOccurrences(of: "context:", with: ""), $0)
            }, uniquingKeysWith: { a, _ in a })
        let excluded = Set(
            normalizedEvents.filter { $0.kind == "undo" || $0.kind == "legacyExcluded" }.compactMap(
                \.templateID))
        let rawReviews = normalizedEvents.filter { $0.kind == "review" }
        let uniqueReviews =
            identityAliases.isEmpty
            ? rawReviews
            : Array(
                Dictionary(
                    rawReviews.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.sessionID != nil ? a : b }
                ).values)
        let reviewEvents = uniqueReviews.filter {
            $0.kind == "review" && $0.occurredAt <= now && $0.log.map { !excluded.contains($0.id) } == true
        }
        .sorted { $0.occurredAt == $1.occurredAt ? $0.id < $1.id : $0.occurredAt < $1.occurredAt }
        var all: [StatisticsReview] = []
        for original in reviewEvents {
            var event = original
            if let sourceID = event.sourceLibraryID, let itemID = event.itemID {
                event.itemID = itemAliases[sourceID.uuidString + ":" + itemID.uuidString] ?? itemID
            }
            guard let log = event.log else { continue }
            let extra = context[log.id.uuidString] ?? event
            let skill = extra.skill ?? event.skill
            let interaction = extra.interaction ?? event.interaction
            guard matchesScope(item: event.itemID, deck: event.deckID),
                matches(event.itemTypeID, event.templateID, skill, interaction),
                query.sessionID == nil || extra.sessionID == query.sessionID
            else { continue }
            let deck =
                query.studyTimeAttribution ? event.deckID : event.itemID.flatMap { source.itemDecks[$0] }
            let name =
                event.itemID.map(source.liveItems.contains) == false
                ? "Deleted Content" : deck.flatMap { deckNames[$0] } ?? "Unassigned"
            all.append(
                StatisticsReview(
                    log: log, itemID: event.itemID, deckName: name, skill: skill ?? "Unknown",
                    interaction: interaction ?? "Unknown", sessionID: extra.sessionID,
                    before: event.memoryBefore, after: event.memoryAfter,
                    promptMilliseconds: extra.promptMilliseconds,
                    answerMilliseconds: extra.answerMilliseconds, checkedCorrect: extra.checkedCorrect))
        }
        let selected = all.filter { $0.log.reviewedAt >= range.start && $0.log.reviewedAt <= range.end }
        let previous = all.filter { $0.log.reviewedAt >= prior.start && $0.log.reviewedAt < prior.end }
        // A UTC day overlaps at most three local study days. Resolve those
        // boundaries once, instead of invoking Calendar for every review.
        var dayCache: [Int64: [DateInterval]] = [:]
        func day(_ date: Date) -> Date {
            let key = Int64(floor(date.timeIntervalSince1970 / 86400))
            if let intervals = dayCache[key],
                let interval = intervals.first(where: { $0.start <= date && date < $0.end })
            {
                return interval.start
            }
            let utcStart = Date(timeIntervalSince1970: Double(key) * 86400)
            var start = StudyDay.start(for: utcStart, rolloverMinutes: source.rollover, calendar: calendar)
            var intervals: [DateInterval] = []
            while start < utcStart.addingTimeInterval(86400) {
                let end = StudyDay.nextRollover(
                    after: start, rolloverMinutes: source.rollover, calendar: calendar)
                guard end > start else { break }
                intervals.append(.init(start: start, end: end))
                start = end
            }
            dayCache[key] = intervals
            return intervals.first(where: { $0.start <= date && date < $0.end })?.start ?? date
        }
        let days = Set(all.map { day($0.log.reviewedAt) }).sorted()
        var longest = 0
        var currentRun = 0
        var lastDay: Date?
        for date in days {
            currentRun =
                lastDay.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } == date
                ? currentRun + 1 : 1
            longest = max(longest, currentRun)
            lastDay = date
        }
        let today = day(now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let current = lastDay == today || lastDay == yesterday ? currentRun : 0
        var recallKeys: Set<StatisticsRecallKey> = []
        var eligible: [StatisticsReview] = []
        for review in selected where review.log.phaseBefore == .review && review.log.elapsedDays >= 1 {
            let key = StatisticsRecallKey(cardID: review.log.cardID, day: day(review.log.reviewedAt))
            if recallKeys.insert(key).inserted { eligible.append(review) }
        }
        let passed = eligible.filter { $0.log.rating != .again }.count
        let bounds = wilson(passed: passed, total: eligible.count)
        var dailyReviews: [Date: [String: Double]] = [:]
        var dailyTime: [Date: Double] = [:]
        var heatCounts: [Date: Double] = [:]
        for review in selected {
            dailyReviews[day(review.log.reviewedAt), default: [:]][
                review.log.phaseBefore.rawValue.capitalized, default: 0] += 1
        }
        for review in all { heatCounts[day(review.log.reviewedAt), default: 0] += 1 }
        var totalTime: Int64 = 0
        var previousTime: Int64 = 0
        var pending: Int64 = 0
        var sessionTimes: [UUID: (Date, Int64, Set<UUID>, Set<UUID>)] = [:]
        let aliases = Dictionary(
            source.aliases.map { ($0.id, $0.resolvedItemID) }, uniquingKeysWith: { a, _ in a })
        for segment in source.segments {
            let itemID =
                aliases[segment.sourceLibraryID.uuidString + ":" + segment.itemID.uuidString]
                ?? segment.itemID
            let liveCard = cardLookup[segment.cardID]
            guard matchesScope(item: itemID, deck: nil, forceCurrent: true),
                query.sessionID == nil || segment.sessionID == query.sessionID
            else { continue }
            if query.itemTypeID != nil || query.templateID != nil || query.skill != nil
                || query.interaction != nil
            {
                guard let card = liveCard,
                    matches(
                        card.itemTypeID, card.card.templateID, skillName(card.card.skill), card.interaction)
                else { continue }
            }
            func overlap(_ interval: DateInterval) -> Int64 {
                let seconds = max(
                    0,
                    min(segment.endedAt, interval.end).timeIntervalSince(
                        max(segment.startedAt, interval.start)))
                return Int64((seconds * 1000).rounded())
            }
            let amount = overlap(range)
            if !source.liveItems.contains(itemID) && !source.deletedItems.contains(itemID) {
                pending += amount
                continue
            }
            totalTime += amount
            previousTime += overlap(prior)
            if amount > 0 {
                var session = sessionTimes[segment.sessionID] ?? (segment.startedAt, 0, [], [])
                session.0 = min(session.0, segment.startedAt)
                session.1 += amount
                session.2.insert(segment.cardID)
                session.3.insert(itemID)
                sessionTimes[segment.sessionID] = session
            }
            var heatCursor = max(
                segment.startedAt,
                StudyDay.start(
                    for: heatStart.addingTimeInterval(12 * 3600), rolloverMinutes: source.rollover,
                    calendar: calendar))
            let heatLimit = min(
                segment.endedAt, heatEnd.addingTimeInterval(Double(source.rollover) * 60), now)
            while heatCursor < heatLimit {
                let next = min(
                    heatLimit,
                    StudyDay.nextRollover(
                        after: heatCursor, rolloverMinutes: source.rollover, calendar: calendar))
                guard next > heatCursor else { break }
                heatMinutes[day(heatCursor), default: 0] += next.timeIntervalSince(heatCursor) / 60
                heatCursor = next
            }
            var start = max(segment.startedAt, range.start)
            let end = min(segment.endedAt, range.end)
            while start < end {
                let next = min(
                    end,
                    StudyDay.nextRollover(after: start, rolloverMinutes: source.rollover, calendar: calendar))
                guard next > start else { break }
                dailyTime[day(start), default: 0] += next.timeIntervalSince(start) / 60
                start = next
            }
        }
        var daily: [StatisticsPoint] = []
        let selectedStart =
            range.start.timeIntervalSince1970 == 0
            ? min(all.first?.log.reviewedAt ?? now, source.segments.map(\.startedAt).min() ?? now)
            : range.start
        let dayCount = max(1, calendar.dateComponents([.day], from: day(selectedStart), to: today).day ?? 1)
        // Limit plotted buckets without dropping records or changing totals.
        let component: Calendar.Component = dayCount > 730 ? .month : dayCount > 120 ? .weekOfYear : .day
        func bucket(_ date: Date) -> Date {
            component == .day
                ? date
                : day(
                    (calendar.dateInterval(of: component, for: date)?.start ?? date).addingTimeInterval(
                        12 * 3600))
        }
        var grouped: [Date: [String: Double]] = [:]
        for (date, series) in dailyReviews {
            for (name, value) in series { grouped[bucket(date), default: [:]][name, default: 0] += value }
        }
        for (date, value) in dailyTime {
            grouped[bucket(date), default: [:]]["Active minutes", default: 0] += value
        }
        var cumulative = 0.0
        for date in grouped.keys.sorted() {
            for (name, value) in grouped[date]! {
                daily.append(
                    .init(
                        date: date, series: name, value: value,
                        intervalEnd: calendar.date(byAdding: component, value: 1, to: date)))
            }
            cumulative += (grouped[date] ?? [:]).filter { $0.key != "Active minutes" }.values.reduce(0, +)
            daily.append(.init(date: date, series: "Cumulative reviews", value: cumulative))
        }
        var timeCumulative = 0.0
        for date in grouped.keys.sorted() {
            timeCumulative += grouped[date]?["Active minutes"] ?? 0
            daily.append(.init(date: date, series: "Cumulative minutes", value: timeCumulative))
        }
        let year = query.heatmapYear ?? calendar.component(.year, from: now)
        let yearStart = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
        let yearEnd = calendar.date(byAdding: .year, value: 1, to: yearStart)!
        var heatmap: [StatisticsPoint] = []
        var date = yearStart
        while date < yearEnd {
            // Heatmap coordinates are calendar dates; lookup uses the associated
            // study-day key, including the configured rollover hour.
            let lookup = calendar.date(
                bySettingHour: source.rollover / 60, minute: source.rollover % 60, second: 0, of: date)!
            heatmap.append(.init(date: date, series: "Reviews", value: heatCounts[lookup, default: 0]))
            date = calendar.date(byAdding: .day, value: 1, to: date)!
        }
        var recalls: [StatisticsPoint] = []
        for (date, group) in Dictionary(grouping: eligible, by: { bucket(day($0.log.reviewedAt)) }).sorted(
            by: { $0.key < $1.key })
        {
            recalls.append(
                .init(
                    date: date, series: "Observed recall",
                    value: Double(group.filter { $0.log.rating != .again }.count) / Double(group.count) * 100,
                    count: group.count))
        }
        let durations = selected.map(\.log.durationMs).filter(ReviewWorkloadTimingPolicy.isUsable).map(
            Double.init)
        let scopedCards = source.cards.filter {
            matchesScope(item: $0.card.itemID, deck: $0.card.deckID)
                && matches($0.itemTypeID, $0.card.templateID, skillName($0.card.skill), $0.interaction)
        }
        let active = scopedCards.filter { !$0.card.isSuspended }
        let studied = active.filter { $0.card.memory.reps > 0 && $0.card.memory.stability > 0 }
        let remembered = studied.reduce(0.0) {
            $0 + FSRSScheduler(parameters: $1.parameters).retrievability(of: $1.card.memory, asOf: now)
        }
        func histogram(_ values: [Double], edges: [Double], labels: [String], ids: [UUID]? = nil)
            -> [StatisticsBin]
        {
            labels.enumerated().map { i, name in
                let rows = values.enumerated().filter {
                    $0.element >= edges[i] && (i + 1 == edges.count || $0.element < edges[i + 1])
                }
                return .init(
                    name, Double(rows.count), cardIDs: ids.map { keys in rows.map { keys[$0.offset] } } ?? [])
            }
        }
        let intervals = studied.map {
            max(0, $0.card.memory.due.timeIntervalSince($0.card.memory.lastReview ?? now) / 86400)
        }
        let ageEdges = [0.0, 1, 7, 30, 90, 365]
        let ageLabels = ["<1d", "1–6d", "7–29d", "30–89d", "90–364d", "365d+"]
        let phases: [StatisticsBin] = [
            .init("Not started", Double(active.filter { $0.card.memory.reps == 0 }.count)),
            .init("Learning", Double(active.filter { $0.card.memory.reps > 0 && !$0.maintaining }.count)),
            .init("Maintaining", Double(active.filter(\.maintaining).count)),
            .init("Suspended", Double(scopedCards.count - active.count)),
        ]
        let grades = ReviewRating.allCases.map { rating in
            StatisticsBin(
                String(describing: rating).capitalized,
                Double(selected.filter { $0.log.rating == rating }.count))
        }
        var hours: [StatisticsPoint] = []
        var hourCache: [Int64: Int] = [:]
        let hourly = Dictionary(grouping: selected) { review -> Int in
            let minute = Int64(floor(review.log.reviewedAt.timeIntervalSince1970 / 60))
            if let value = hourCache[minute] { return value }
            let components = calendar.dateComponents([.weekday, .hour], from: review.log.reviewedAt)
            let value = (components.weekday ?? 1) * 24 + (components.hour ?? 0)
            hourCache[minute] = value
            return value
        }
        for (hour, group) in hourly {
            hours.append(
                .init(
                    date: Date(timeIntervalSince1970: Double(hour) * 3600), series: "\(hour / 24)",
                    value: Double(group.count), count: hour % 24))
        }
        func recallBins(_ group: (StatisticsReview) -> String) -> [StatisticsBin] {
            Dictionary(grouping: eligible, by: group).map { label, rows in
                .init(
                    label, Double(rows.filter { $0.log.rating != .again }.count) / Double(rows.count) * 100,
                    count: rows.count)
            }.sorted { $0.label < $1.label }
        }
        let predictedReviews = eligible.filter { $0.log.schedulingAudit?.predictedRetrievability != nil }
        let calibrationGroups = Dictionary(grouping: predictedReviews) { review -> Int in
            min(9, max(0, Int((review.log.schedulingAudit?.predictedRetrievability ?? 0) * 10)))
        }
        let calibration: [StatisticsBin] = calibrationGroups.map { index, rows in
            let success = rows.filter { $0.log.rating != .again }.count
            let percent = Double(success) / Double(rows.count) * 100
            return StatisticsBin("\(index*10)–\((index+1)*10)%", percent, count: rows.count)
        }.sorted { $0.label < $1.label }

        let overdue = studied.filter { $0.card.memory.due < today }.map {
            today.timeIntervalSince($0.card.memory.due) / 86400
        }
        let dueGroups = Dictionary(
            grouping: active.filter {
                $0.card.memory.reps > 0 && $0.card.memory.due <= now.addingTimeInterval(365 * 86400)
            }, by: { max(today, day($0.card.memory.due)) })
        let due = dueGroups.map {
            StatisticsPoint(date: $0.key, series: "Scheduled cards", value: Double($0.value.count))
        }.sorted { $0.date < $1.date }
        let sessionReviews = Dictionary(
            grouping: selected.compactMap { review in review.sessionID.map { ($0, review) } }, by: { $0.0 }
        ).mapValues(\.count)
        let sessionSubmissions = Dictionary(
            grouping: source.events.filter {
                $0.kind == "submission" && $0.occurredAt >= range.start && $0.occurredAt <= range.end
            }.compactMap(\.sessionID), by: { $0 }
        ).mapValues(\.count)
        let sessions = sessionTimes.map { id, value in
            StatisticsSession(
                id: id, date: value.0, milliseconds: value.1, reviews: sessionReviews[id, default: 0],
                cards: value.2.count, items: value.3.count, submissions: sessionSubmissions[id, default: 0])
        }.sorted { $0.date > $1.date }

        var progressSource = source
        progressSource.events = normalizedEvents
        let history = progressHistory(
            source: progressSource, reviews: all, cards: scopedCards, now: now, day: day)
        var introductions: [UUID: Date] = [:]
        for review in all where review.log.phaseBefore == .new && introductions[review.log.cardID] == nil {
            introductions[review.log.cardID] = review.log.reviewedAt
        }
        for (id, date) in introductions where date >= range.start && date <= range.end {
            _ = id
            daily.append(.init(date: bucket(day(date)), series: "New introductions", value: 1))
        }
        // Aggregate introductions into the same display buckets as the review series.
        let introPoints = Dictionary(grouping: daily.filter { $0.series == "New introductions" }, by: \.date)
            .map { date, rows in
                StatisticsPoint(date: date, series: "New introductions", value: Double(rows.count))
            }
        daily.removeAll { $0.series == "New introductions" }
        daily.append(contentsOf: introPoints)
        let cohortGroups = Dictionary(grouping: introductions.keys) {
            calendar.dateInterval(of: .month, for: introductions[$0]!)!.start
        }
        var cohorts: [StatisticsPoint] = []
        for (cohort, ids) in cohortGroups {
            let age = min(24, max(0, calendar.dateComponents([.month], from: cohort, to: now).month ?? 0))
            for month in 0...age {
                let end = calendar.date(byAdding: .month, value: month + 1, to: cohort)!
                let reached = ids.filter { id in history.milestones[id].map { $0 < end } ?? false }.count
                cohorts.append(
                    .init(
                        date: cohort, series: String(month), value: Double(reached) / Double(ids.count) * 100,
                        count: ids.count))
            }
        }
        let milestoneDays = history.milestones.compactMap { id, date in
            introductions[id].map { date.timeIntervalSince($0) / 86400 }
        }
        var effort: [UUID: StatisticsReview] = [:]
        for row in selected {
            if row.log.durationMs >= (effort[row.log.cardID]?.log.durationMs ?? -1) {
                effort[row.log.cardID] = row
            }
        }
        let attention = effort.values.sorted { a, b in
            let al = cardLookup[a.log.cardID]?.card.memory.lapses ?? 0
            let bl = cardLookup[b.log.cardID]?.card.memory.lapses ?? 0
            return al == bl ? a.log.durationMs > b.log.durationMs : al > bl
        }.prefix(10)
        return StatisticsSnapshot(
            todayIntroductions: source.introductions.filter {
                $0.studyDay == StudyDay.key(for: now, rolloverMinutes: source.rollover, calendar: calendar)
            }, range: range, asOf: now, reviews: selected.reversed(), attentionReviews: Array(attention),
            reviewCount: selected.count,
            distinctCards: Set(selected.map(\.log.cardID)).count,
            distinctItems: Set(selected.compactMap(\.itemID)).count,
            activeMilliseconds: totalTime, previousReviews: previous.count,
            previousMilliseconds: previousTime, currentStreak: current,
            longestStreak: longest, activeDays: Set(selected.map { day($0.log.reviewedAt) }).count,
            recallPassed: passed, recallTotal: eligible.count, recallLower: bounds.0, recallUpper: bounds.1,
            durationMedian: quantile(durations, 0.5), durationP90: quantile(durations, 0.9),
            excludedDurations: selected.count - durations.count,
            estimatedRemembered: remembered, daily: daily.sorted { $0.date < $1.date }, heatmap: heatmap,
            timeHeatmap: heatmap.map { point in
                let lookup = calendar.date(
                    bySettingHour: source.rollover / 60, minute: source.rollover % 60, second: 0,
                    of: point.date)!
                return StatisticsPoint(
                    date: point.date, series: "Active minutes", value: heatMinutes[lookup, default: 0])
            }, recall: recalls, progress: history.points, cohorts: cohorts, hours: hours,
            phases: phases, grades: grades,
            stability: histogram(
                studied.map { $0.card.memory.stability }, edges: ageEdges, labels: ageLabels,
                ids: studied.map { $0.card.id }),
            difficulty: histogram(
                studied.map { $0.card.memory.difficulty }, edges: [1, 3, 5, 7, 9],
                labels: ["1–3", "3–5", "5–7", "7–9", "9–10"], ids: studied.map { $0.card.id }),
            retrievability: histogram(
                studied.map {
                    FSRSScheduler(parameters: $0.parameters).retrievability(of: $0.card.memory, asOf: now)
                        * 100
                }, edges: [0, 50, 70, 80, 90, 95],
                labels: ["<50%", "50–69%", "70–79%", "80–89%", "90–94%", "95–100%"],
                ids: studied.map { $0.card.id }),
            intervals: histogram(
                intervals, edges: ageEdges, labels: ageLabels, ids: studied.map { $0.card.id }),
            lapses: histogram(
                studied.map { Double($0.card.memory.lapses) }, edges: [0, 1, 3, 5, 10],
                labels: ["0", "1–2", "3–4", "5–9", "10+"], ids: studied.map { $0.card.id }),
            durations: histogram(
                durations.map { $0 / 1000 }, edges: [0, 5, 15, 30, 60, 120],
                labels: ["<5s", "5–14s", "15–29s", "30–59s", "1–2m", "2m+"]),
            backlog: histogram(
                overdue, edges: [0, 1, 7, 30, 90], labels: ["<1d", "1–6d", "7–29d", "30–89d", "90d+"]),
            calibration: calibration,
            latenessRecall: recallBins { review in
                let late =
                    review.log.reviewedAt.timeIntervalSince(review.before?.due ?? review.log.reviewedAt)
                    / 86400
                return late <= 1 ? "Within 1 day" : late < 7 ? "1–6 days late" : "7+ days late"
            },
            intervalRecall: recallBins {
                $0.log.elapsedDays < 7 ? "1–6 days" : $0.log.elapsedDays < 30 ? "7–29 days" : "30+ days"
            },
            skillComparisons: Dictionary(grouping: selected, by: \.skill).map {
                .init($0.key, Double($0.value.count))
            }.sorted { $0.value > $1.value },
            methodComparisons: Dictionary(grouping: selected, by: \.interaction).map {
                .init($0.key, Double($0.value.count))
            }.sorted { $0.value > $1.value },
            milestoneDurations: histogram(milestoneDays, edges: ageEdges, labels: ageLabels),
            comparisons: Dictionary(grouping: selected, by: \.deckName).map {
                .init($0.key, Double($0.value.count))
            }.sorted { $0.value > $1.value },
            due: due, sessions: sessions, cards: scopedCards,
            coverage: .init(
                historyStartedAt: all.first?.log.reviewedAt, progressStartedAt: source.trackingStartedAt,
                timeStartedAt: source.segments.map(\.startedAt).min(),
                unknownReviewCount: source.events.filter { $0.kind == "legacyExcluded" }.count,
                pendingMilliseconds: pending),
            itemTypeNames: source.itemTypeNames, templateNames: source.templateNames, decks: source.decks,
            skills: Array(Set(reviewEvents.compactMap(\.skill))).sorted(),
            interactions: Array(Set(reviewEvents.compactMap(\.interaction))).sorted())
    }
    public static func skillName(_ skill: Skill) -> String {
        "\(skill.input.rawValue) → \(skill.output.rawValue) · \(skill.operation.rawValue)"
    }

    private static func progressHistory(
        source: StatisticsSource, reviews: [StatisticsReview], cards: [StatisticsCard], now: Date,
        day: (Date) -> Date
    ) -> (points: [StatisticsPoint], milestones: [UUID: Date]) {
        guard let began = source.trackingStartedAt else { return ([], [:]) }
        let ids = Set(cards.map { $0.card.id }).union(reviews.map { $0.log.cardID })
        let reviewLookup = Dictionary(uniqueKeysWithValues: reviews.map { ($0.log.id, $0) })
        var evidence: [UUID: CardMaturityEvidence] = [:]
        var maintaining: Set<UUID> = []
        var points: [Date: Int] = [:]
        var milestones: [UUID: Date] = [:]
        let events = source.events.filter { $0.occurredAt <= now }.sorted {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
            return $0.id < $1.id
        }
        for event in events where ids.contains(event.cardID) {
            var value = evidence[event.cardID] ?? CardMaturityEvidence()
            if event.kind == "review", let log = event.log, reviewLookup[log.id] == nil { continue }
            if event.kind == "reset" { value = CardMaturityEvidence() }
            if let log = event.log, reviewLookup[log.id] != nil { value.observe(log) }
            evidence[event.cardID] = value
            if event.kind == "deleted" || event.suspended {
                maintaining.remove(event.cardID)
            } else if let memory = event.memoryAfter {
                let card = Card(
                    id: event.cardID, itemID: event.itemID ?? event.cardID,
                    templateID: event.templateID ?? event.cardID,
                    skill: .init(input: .text, output: .text, operation: .recall), memory: memory)
                if CardMaturityStatus.evaluate(card: card, evidence: value) == .maintaining {
                    maintaining.insert(card.id)
                    if milestones[card.id] == nil { milestones[card.id] = event.occurredAt }
                } else {
                    maintaining.remove(card.id)
                }
            }
            if event.occurredAt >= began { points[day(event.occurredAt)] = maintaining.count }
        }
        points[day(now)] = cards.filter { !$0.card.isSuspended && $0.maintaining }.count
        return (
            points.sorted { $0.key < $1.key }.map {
                .init(date: $0.key, series: "Maintaining", value: Double($0.value))
            }, milestones
        )
    }
}
