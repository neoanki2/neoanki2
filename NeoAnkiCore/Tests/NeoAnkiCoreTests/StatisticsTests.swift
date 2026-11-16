import Foundation
import Testing

@testable import NeoAnkiCore

private func statsCalendar() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/New_York")!
    return c
}
private func statsDate(_ year: Int = 2026, _ month: Int = 11, _ day: Int = 16, _ hour: Int = 12) -> Date {
    statsCalendar().date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}
private func statsFixture() async throws -> (ItemStore, URL, Item, UUID) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("statistics-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let store = try ItemStore(databaseURL: folder.appendingPathComponent("library.sqlite"))
    try await store.bootstrap()
    let item = Item(
        itemTypeID: BuiltInItemTypes.basicID,
        fields: [
            .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Question")),
            .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
        ])
    _ = try await store.createItem(item)
    let card = try #require(try await store.fetchDueCards().first)
    return (store, folder, item, card.id)
}
private func emptyStatsSource() -> StatisticsSource {
    StatisticsSource(
        events: [], segments: [], cards: [], decks: [], itemDecks: [:], liveItems: [], deletedItems: [],
        aliases: [], trackingStartedAt: statsDate(), rollover: 240, itemTypeNames: [:], templateNames: [:])
}
private func statsReview(
    _ date: Date, _ card: UUID = UUID(), _ rating: ReviewRating = .good, _ phase: Phase = .review,
    _ elapsed: Double = 2, _ duration: Int = 10_000
) -> StatisticsEvent {
    let log = ReviewLog(
        cardID: card, reviewedAt: date, rating: rating, elapsedDays: elapsed, scheduledDays: 2,
        phaseBefore: phase, durationMs: duration)
    return StatisticsEvent(
        id: "review:" + log.id.uuidString, kind: "review", occurredAt: date, cardID: card, itemID: card,
        log: log, memoryBefore: .init(due: date.addingTimeInterval(-3600)))
}
@Test func statisticsCountsDistinctCardsFirstSpacedRecallAndDurations() {
    var source = emptyStatsSource()
    let card = UUID()
    let now = statsDate()
    source.events = [
        statsReview(now.addingTimeInterval(-100), card, .again),
        statsReview(now.addingTimeInterval(-60), card, .good), statsReview(now, UUID(), .good, .new, 0, 0),
    ]
    let result = StatisticsEngine.snapshot(
        source: source, query: .init(), now: now, calendar: statsCalendar())
    #expect(result.reviewCount == 3)
    #expect(result.distinctCards == 2)
    #expect(result.recallTotal == 1)
    #expect(result.recallPassed == 0)
    #expect(result.excludedDurations == 1)
    #expect(result.durationMedian == 10_000)
    #expect(result.recallUpper != nil)
}
@Test func statisticsStreakUsesStudyDaysAndKeepsYesterdayPending() {
    var source = emptyStatsSource()
    let now = statsDate()
    source.events = [
        statsReview(statsDate(2026, 11, 14)), statsReview(statsDate(2026, 11, 15)),
        statsReview(statsDate(2026, 11, 16, 2)),
    ]
    let result = StatisticsEngine.snapshot(
        source: source, query: .init(), now: now, calendar: statsCalendar())
    #expect(result.currentStreak == 2)
    #expect(result.longestStreak == 2)
    source.events.append(statsReview(statsDate()))
    #expect(
        StatisticsEngine.snapshot(source: source, query: .init(), now: now, calendar: statsCalendar())
            .currentStreak == 3)
}
@Test func statisticsUndoCanArriveBeforeReview() {
    var source = emptyStatsSource()
    let review = statsReview(statsDate())
    source.events = [
        StatisticsEvent(
            id: "undo:" + review.log!.id.uuidString, kind: "undo", occurredAt: statsDate(),
            cardID: review.cardID, templateID: review.log!.id), review,
    ]
    let snapshot = StatisticsEngine.snapshot(
        source: source, query: .init(), now: statsDate(), calendar: statsCalendar())
    #expect(snapshot.reviewCount == 0)
    #expect(snapshot.currentStreak == 0)
}
@Test func statisticsTimeClipsAtRolloverAcrossDSTAndCountsSimultaneousDevices() {
    var source = emptyStatsSource()
    let item = UUID()
    let card = UUID()
    let session = UUID()
    source.liveItems = [item]
    let start = statsDate(2026, 11, 1, 3).addingTimeInterval(59 * 60)
    let end = start.addingTimeInterval(120)
    source.segments = (0..<2).map { _ in
        LearningTimeSegment(
            sessionID: session, deviceID: UUID(), sourceLibraryID: UUID(), itemID: item, cardID: card,
            startedAt: start, endedAt: end, durationMilliseconds: 120_000)
    }
    var query = StatisticsQuery()
    query.period = .today
    let result = StatisticsEngine.snapshot(source: source, query: query, now: end, calendar: statsCalendar())
    #expect(result.activeMilliseconds == 120_000)
    #expect(result.daily.filter { $0.series == "Active minutes" }.reduce(0) { $0 + $1.value } == 2)
}
@Test func statisticsHeatmapSupportsLeapYearAndCustomRanges() {
    var source = emptyStatsSource()
    source.events = [statsReview(statsDate(2024, 2, 29))]
    var query = StatisticsQuery()
    query.period = .custom
    query.customStart = statsDate(2024, 2, 28)
    query.customEnd = statsDate(2024, 3, 1)
    query.heatmapYear = 2024
    let s = StatisticsEngine.snapshot(
        source: source, query: query, now: statsDate(), calendar: statsCalendar())
    #expect(s.reviewCount == 1)
    #expect(s.heatmap.count == 366)
    #expect(s.heatmap.reduce(0) { $0 + $1.value } == 1)
}
@Test func statisticsPreservesReviewAfterResetDeletionAndReopen() async throws {
    let (store, folder, item, card) = try await statsFixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let now = Date.now
    _ = try await store.submitReviewWithReceipt(cardID: card, rating: .good, now: now, durationMs: 5000)
    _ = try await store.statisticsSource()
    try await store.database.resetCardProgress(id: card, now: now.addingTimeInterval(1))
    #expect(try await store.deleteItem(id: item.id))
    let reopened = try ItemStore(databaseURL: folder.appendingPathComponent("library.sqlite"))
    try await reopened.bootstrap()
    var query = StatisticsQuery()
    query.period = .all
    let result = StatisticsEngine.snapshot(
        source: try await reopened.statisticsSource(), query: query, now: Date.now.addingTimeInterval(10))
    #expect(result.reviewCount == 1)
    #expect(result.reviews.first?.deckName == "Deleted Content")
}
@Test func statisticsDeletionBeforeFirstVisitDoesNotBecomeLegacyUndo() async throws {
    let (store, folder, item, card) = try await statsFixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    _ = try await store.submitReviewWithReceipt(cardID: card, rating: .good, now: .now)
    _ = try await store.deleteItem(id: item.id)
    let result = StatisticsEngine.snapshot(
        source: try await store.statisticsSource(), query: .init(), now: Date.now.addingTimeInterval(2))
    #expect(result.reviewCount == 1)
    #expect(result.coverage.unknownReviewCount == 0)
}
@Test func statisticsExplicitUndoRemovesReviewButNotActiveTime() async throws {
    let (store, folder, item, card) = try await statsFixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let now = Date.now
    let review = try await store.submitReviewWithReceipt(cardID: card, rating: .good, now: now)
    try await store.recordLearningTime([
        .init(
            sessionID: UUID(), deviceID: UUID(), sourceLibraryID: UUID(), itemID: item.id, cardID: card,
            startedAt: now.addingTimeInterval(-10), endedAt: now, durationMilliseconds: 10_000)
    ])
    try await store.revertReview(reviewLogID: review.reviewLogID, now: now)
    let s = StatisticsEngine.snapshot(
        source: try await store.statisticsSource(), query: .init(), now: now.addingTimeInterval(1))
    #expect(s.reviewCount == 0)
    #expect(s.activeMilliseconds == 10_000)
}
@Test func statisticsCapturesSessionContextInGradingTransaction() async throws {
    let (store, folder, _, card) = try await statsFixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let context = StatisticsReviewContext(
        sessionID: UUID(), deviceID: UUID(), promptMilliseconds: 3000, answerMilliseconds: 2000)
    let review = try await StatisticsCapture.$context.withValue(context) {
        try await store.submitReviewWithReceipt(cardID: card, rating: .good, now: .now)
    }
    let source = try await store.statisticsSource()
    let fact = try #require(source.events.first { $0.log?.id == review.reviewLogID })
    #expect(fact.sessionID == context.sessionID)
    #expect(fact.promptMilliseconds == 3000)
    let query = StatisticsQuery(sessionID: context.sessionID)
    #expect(
        StatisticsEngine.snapshot(source: source, query: query, now: Date.now.addingTimeInterval(1))
            .reviewCount == 1)
}
@Test func statisticsEvidenceIsIdempotentAndRejectsConflictingIdentity() async throws {
    let (store, folder, _, _) = try await statsFixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let fact = statsReview(.now)
    try await store.recordStatisticsEvents([fact, fact])
    var conflicting = fact
    conflicting.cardID = UUID()
    await #expect(throws: DatabaseError.self) { try await store.recordStatisticsEvents([conflicting]) }
    #expect(try await store.statisticsSource().events.filter { $0.id == fact.id }.count == 1)
}
@Test func statisticsCurrentDeckAttributionFollowsMovesWithoutChangingLibraryTotals() {
    var source = emptyStatsSource()
    let a = Deck(name: "A")
    let b = Deck(name: "B")
    let item = UUID()
    var event = statsReview(statsDate(), item)
    event.deckID = a.id
    source.events = [event]
    source.decks = [a, b]
    source.liveItems = [item]
    source.itemDecks[item] = b.id
    #expect(
        StatisticsEngine.snapshot(
            source: source, query: .init(scope: .deck(a.id)), now: statsDate(), calendar: statsCalendar()
        ).reviewCount == 0)
    #expect(
        StatisticsEngine.snapshot(
            source: source, query: .init(scope: .deck(b.id)), now: statsDate(), calendar: statsCalendar()
        ).reviewCount == 1)
    var query = StatisticsQuery(scope: .deck(a.id))
    query.studyTimeAttribution = true
    #expect(
        StatisticsEngine.snapshot(source: source, query: query, now: statsDate(), calendar: statsCalendar())
            .reviewCount == 1)
}
@Test func statisticsProjectionAndCSVAreDeterministicAcrossConsumers() {
    var source = emptyStatsSource()
    source.events = [statsReview(statsDate()), statsReview(statsDate())]
    let a = StatisticsEngine.snapshot(
        source: source, query: .init(), now: statsDate(), calendar: statsCalendar())
    let b = StatisticsEngine.snapshot(
        source: source, query: .init(), now: statsDate(), calendar: statsCalendar())
    #expect(a.csv == b.csv)
    #expect(a.reviewCount == b.reviewCount)
    #expect(a.csv.hasPrefix("date,series,value,samples\n"))
}
@Test func statisticsScenarioIsSeededAndNeverMutatesSource() throws {
    var source = emptyStatsSource()
    let deck = Deck(name: "Limited", newCardsPerDay: 1)
    let item = UUID()
    source.decks = [deck]
    source.liveItems = [item]
    source.itemDecks[item] = deck.id
    source.cards = (0..<3).map { _ in
        StatisticsCard(
            card: Card(
                itemID: item, templateID: UUID(),
                skill: .init(input: .text, output: .text, operation: .recall), memory: .new(due: statsDate()),
                deckID: deck.id), itemTypeID: UUID(), interaction: "reveal", maintaining: false,
            parameters: .init(), newCardsPerDay: 1)
    }
    let snapshot = StatisticsEngine.snapshot(
        source: source, query: .init(), now: statsDate(), calendar: statsCalendar())
    var request = StatisticsForecastRequest()
    request.newCardsPerDay = 0
    let zero = try StatisticsSimulator.simulate(
        snapshot: snapshot, decks: source.decks, request: request, rollover: 240, calendar: statsCalendar())
    #expect(zero.points.allSatisfy { $0.median == 0 })
    request.newCardsPerDay = 10
    let a = try StatisticsSimulator.simulate(
        snapshot: snapshot, decks: source.decks, request: request, rollover: 240, calendar: statsCalendar())
    let b = try StatisticsSimulator.simulate(
        snapshot: snapshot, decks: source.decks, request: request, rollover: 240, calendar: statsCalendar())
    #expect(a.points.first?.median == 1)
    #expect(a.points.map(\.median) == b.points.map(\.median))
    #expect(source.cards.allSatisfy { $0.card.memory.reps == 0 })
}

@Test func statisticsLifecycleIDsAreUniqueAcrossReplicasOfTheSameLibrary() async throws {
    let (store, folder, _, _) = try await statsFixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = try await store.statisticsSource()
    let stateIDs = first.events.filter { $0.kind != "review" }.map(\.id)
    #expect(Set(stateIDs).count == stateIDs.count)
    #expect(stateIDs.allSatisfy { $0.hasPrefix("state:") && $0.count == 38 })
}
@Test func statisticsIdentityAliasesDeduplicateRemappedReviewEvidence() {
    var source = emptyStatsSource()
    let sourceID = UUID()
    let oldCard = UUID()
    let newCard = UUID()
    let newReview = UUID()
    var event = statsReview(statsDate(), oldCard)
    event.sourceLibraryID = sourceID
    let oldReview = event.log!.id
    let mapped = StatisticsEvent(
        id: "review:" + newReview.uuidString, kind: "review", occurredAt: event.occurredAt, cardID: newCard,
        log: ReviewLog(
            id: newReview, cardID: newCard, reviewedAt: event.occurredAt, rating: .good, elapsedDays: 2,
            scheduledDays: 2, phaseBefore: .review, durationMs: 10000))
    let aliases = [
        StatisticsEvent(
            id: "alias:\(sourceID):card:\(oldCard)", kind: "alias", occurredAt: statsDate(), cardID: oldCard,
            itemID: newCard, interaction: "card", sourceLibraryID: sourceID),
        StatisticsEvent(
            id: "alias:\(sourceID):review:\(oldReview)", kind: "alias", occurredAt: statsDate(),
            cardID: oldReview, itemID: newReview, interaction: "review", sourceLibraryID: sourceID),
    ]
    source.events = [event, mapped] + aliases
    let s = StatisticsEngine.snapshot(
        source: source, query: .init(), now: statsDate(), calendar: statsCalendar())
    #expect(s.reviewCount == 1)
    #expect(s.distinctCards == 1)
}

@Test func statisticsReviewAttributionNeverChangesActiveTimeScope() {
    var source = emptyStatsSource()
    let deck = Deck(name: "Deck")
    let item = UUID()
    let now = statsDate()
    source.decks = [deck]
    source.liveItems = [item]
    source.itemDecks[item] = deck.id
    source.segments = [
        .init(
            sessionID: UUID(), deviceID: UUID(), sourceLibraryID: UUID(), itemID: item, cardID: UUID(),
            startedAt: now.addingTimeInterval(-10), endedAt: now, durationMilliseconds: 10000)
    ]
    var query = StatisticsQuery(scope: .deck(deck.id))
    query.studyTimeAttribution = true
    #expect(
        StatisticsEngine.snapshot(source: source, query: query, now: now, calendar: statsCalendar())
            .activeMilliseconds == 10000)
    query.scope = .unassigned
    #expect(
        StatisticsEngine.snapshot(source: source, query: query, now: now, calendar: statsCalendar())
            .activeMilliseconds == 0)
}
@Test func statisticsForecastHonorsAlreadyConsumedDayZeroIntroductions() throws {
    var source = emptyStatsSource()
    let deck = Deck(name: "Limited", newCardsPerDay: 1)
    let item = UUID()
    let now = statsDate()
    source.decks = [deck]
    source.liveItems = [item]
    source.itemDecks[item] = deck.id
    source.introductions = [
        .init(
            cardID: UUID(), deckID: deck.id,
            studyDay: StudyDay.key(for: now, rolloverMinutes: 240, calendar: statsCalendar()))
    ]
    source.cards = [
        .init(
            card: Card(
                itemID: item, templateID: UUID(),
                skill: .init(input: .text, output: .text, operation: .recall), memory: .new(due: now),
                deckID: deck.id), itemTypeID: UUID(), interaction: "reveal", maintaining: false,
            parameters: .init(), newCardsPerDay: 1)
    ]
    let s = StatisticsEngine.snapshot(source: source, query: .init(), now: now, calendar: statsCalendar())
    let result = try StatisticsSimulator.simulate(
        snapshot: s, decks: [deck], request: .init(), rollover: 240, calendar: statsCalendar())
    #expect(result.points.first?.median == 0)
}
@Test func statisticsWarmReadsDecodeOnlyNewEvidence() async throws {
    let (store, folder, _, card) = try await statsFixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    _ = try await store.submitReviewWithReceipt(cardID: card, rating: .good, now: .now)
    let first = try await store.statisticsSource()
    let revision = try await store.statisticsRevision()
    let second = try await store.statisticsSource()
    #expect(first.events.count == second.events.count)
    #expect(try await store.statisticsRevision() == revision)
}

@Test func statisticsMillionReviewBenchmark() throws {
    guard ProcessInfo.processInfo.environment["NEOANKI_RUN_STATISTICS_BENCHMARK"] == "1" else { return }
    var source = emptyStatsSource()
    let now = statsDate()
    let skill = Skill(input: .text, output: .text, operation: .recall)
    let typeID = UUID()
    let templateID = UUID()
    let cardIDs = (0..<100_000).map { _ in UUID() }
    source.liveItems = Set(cardIDs)
    source.cards = cardIDs.map { id in
        .init(
            card: Card(
                id: id, itemID: id, templateID: templateID, skill: skill,
                memory: .init(
                    stability: 30, difficulty: 5, due: now, lastReview: now, reps: 10, phase: .review)),
            itemTypeID: typeID, interaction: "reveal", maintaining: true, parameters: .init(),
            newCardsPerDay: nil)
    }
    source.events.reserveCapacity(1_000_000)
    for round in 0..<10 {
        let date = now.addingTimeInterval(Double(round - 10) * 2 * 86400)
        for id in cardIDs { source.events.append(statsReview(date, id, .good, round == 0 ? .new : .review)) }
    }
    var query = StatisticsQuery()
    query.period = .all
    let start = ContinuousClock.now
    let result = StatisticsEngine.snapshot(source: source, query: query, now: now, calendar: statsCalendar())
    let duration = start.duration(to: .now)
    print("STATISTICS_BENCHMARK cards=100000 reviews=1000000 projection=\(duration)")
    #expect(result.reviewCount == 1_000_000)
    #expect(result.distinctCards == 100_000)
}

@Test func statisticsLegacyBackfillIsPagedAndPreservesOptionalMemory() async throws {
    let (store, folder, _, card) = try await statsFixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    for offset in 0..<3 {
        _ = try await store.submitReviewWithReceipt(
            cardID: card, rating: .good, now: Date.now.addingTimeInterval(Double(offset)))
    }
    try await store.database.execute("DELETE FROM statistics_events;")
    let firstPage = try await store.database.backfillStatisticsPage()
    #expect(firstPage)
    #expect(try await store.database.backfillStatisticsPage() == false)
    let source = try await store.statisticsSource()
    let reviews = source.events.filter { $0.kind == "review" }
    #expect(reviews.count == 3)
    #expect(reviews.allSatisfy { $0.log?.sequence == nil })
    #expect(reviews.allSatisfy { $0.memoryAfter != nil })
    try await store.recordStatisticsEvents(reviews)
    #expect(try await store.statisticsSource().events.filter { $0.kind == "review" }.count == 3)
}

@Test func statisticsFactCopiesKeepIndependentValueSemantics() throws {
    let original = statsReview(statsDate())
    var copy = original
    copy.kind = "state"
    #expect(original.kind == "review")
    #expect(copy.kind == "state")
    let encoded = try JSONEncoder().encode(original)
    #expect(try JSONDecoder().decode(StatisticsEvent.self, from: encoded) == original)
}

@Test func statisticsOlderClientRevertStaysUndoneAfterLaterDeletion() async throws {
    let (store, folder, item, card) = try await statsFixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let review = try await store.submitReviewWithReceipt(cardID: card, rating: .good, now: .now)
    try await store.database.execute(
        "INSERT INTO review_reverts(id,review_log_id,reverted_at) VALUES (?,?,?);",
        bindings: [
            .text(UUID().uuidString), .text(review.reviewLogID.uuidString),
            .double(Date.now.timeIntervalSince1970),
        ])
    var source = try await store.statisticsSource()
    #expect(
        StatisticsEngine.snapshot(source: source, query: .init(), now: Date.now.addingTimeInterval(1))
            .reviewCount == 0)
    _ = try await store.deleteItem(id: item.id)
    source = try await store.statisticsSource()
    #expect(
        StatisticsEngine.snapshot(source: source, query: .init(), now: Date.now.addingTimeInterval(2))
            .reviewCount == 0)
}

@Test func statisticsSeriesAndExportsStayOrderedAcrossEventArrivalOrders() {
    var source = emptyStatsSource()
    let now = statsDate()
    source.events = [
        statsReview(now, UUID(), .good, .new), statsReview(now, UUID(), .again, .learning),
        statsReview(now, UUID(), .hard, .review), statsReview(now, UUID(), .easy, .relearning),
    ]
    let a = StatisticsEngine.snapshot(source: source, query: .init(), now: now, calendar: statsCalendar())
    source.events.reverse()
    let b = StatisticsEngine.snapshot(source: source, query: .init(), now: now, calendar: statsCalendar())
    #expect(a.csv == b.csv)
    #expect(a.daily.map(\.series) == b.daily.map(\.series))
}

@Test func statisticsDoesNotInventHistoricalUnassignedContext() {
    var source = emptyStatsSource()
    let event = statsReview(statsDate())
    source.events = [event]
    source.liveItems = [event.itemID!]
    var query = StatisticsQuery()
    query.studyTimeAttribution = true
    let all = StatisticsEngine.snapshot(
        source: source, query: query, now: statsDate(), calendar: statsCalendar())
    #expect(all.reviews.first?.deckName == "Unknown historical deck")
    query.scope = .unassigned
    #expect(
        StatisticsEngine.snapshot(source: source, query: query, now: statsDate(), calendar: statsCalendar())
            .reviewCount == 0)
}
