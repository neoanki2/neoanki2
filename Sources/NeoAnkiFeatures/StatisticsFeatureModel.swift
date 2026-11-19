import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import Observation

@MainActor @Observable
public final class StatisticsFeatureModel {
    public var query: StatisticsQuery
    public var section: StatisticsSection = .overview
    public private(set) var snapshot: StatisticsSnapshot?
    public private(set) var baselineForecast: StatisticsForecast?
    public private(set) var forecast: StatisticsForecast?
    public var forecastRequest = StatisticsForecastRequest()
    public private(set) var isLoading = true
    public private(set) var isForecasting = false
    public private(set) var error: String?
    public private(set) var forecastError: String?
    public private(set) var rollover = StudyDay.defaultRolloverMinutes
    private let reads: StatisticsSourceCache
    private struct RefreshStamp: Equatable {
        let revision: String
        let day: String
        let calendar: Calendar
    }
    private struct RefreshRequest {
        let now: Date
        let calendar: Calendar
        let force: Bool
    }
    private var refreshRevision: RefreshStamp?
    private var sourceRevision: String?
    private var previousQuery: StatisticsQuery?
    private var projectingQuery: StatisticsQuery?
    private var refreshPending: RefreshRequest?
    private var generation = 0
    private var forecastTask: Task<(StatisticsForecast, StatisticsForecast?), Error>?
    private var forecastGeneration = 0
    public convenience init(
        library: any LibraryRepository, scope: DeckScope = .allDecks, sessionID: UUID? = nil,
        statistics: (any LibraryStatistics)? = nil
    ) {
        self.init(scope: scope, sessionID: sessionID,
                  reads: StatisticsSourceCache(statistics ?? (library as? any LibraryStatistics)))
    }
    init(scope: DeckScope, sessionID: UUID?, reads: StatisticsSourceCache) {
        self.reads = reads
        query = StatisticsQuery(scope: scope, sessionID: sessionID)
        if sessionID != nil { section = .activity }
    }
    public func refresh(now: Date = .now, calendar: Calendar = .autoupdatingCurrent, force: Bool = true) async
    {
        // Freeze autoupdating calendar settings for both the detached projection
        // and its cache key; a later timezone change must not rewrite an old key.
        var resolvedCalendar = Calendar(identifier: calendar.identifier)
        resolvedCalendar.locale = calendar.locale
        resolvedCalendar.timeZone = TimeZone(identifier: calendar.timeZone.identifier) ?? calendar.timeZone
        resolvedCalendar.firstWeekday = calendar.firstWeekday
        resolvedCalendar.minimumDaysInFirstWeek = calendar.minimumDaysInFirstWeek
        let calendar = resolvedCalendar
        // Rapid filter edits coalesce behind one projection. Stale results
        // are discarded without running several large histories in parallel.
        if let projectingQuery {
            if query != projectingQuery || force || refreshPending != nil {
                generation += 1
                refreshPending = RefreshRequest(now: now, calendar: calendar, force: force)
            }
            return
        }
        defer {
            projectingQuery = nil
            refreshPending = nil
            if isLoading { isLoading = false }
        }
        var next: RefreshRequest? = RefreshRequest(now: now, calendar: calendar, force: force)
        while let request = next {
            projectingQuery = query
            refreshPending = nil
            await project(now: request.now, calendar: request.calendar, force: request.force)
            next = refreshPending
        }
    }

    private func project(now: Date, calendar: Calendar, force: Bool) async {
        generation += 1
        let token = generation
        let requested = query
        // Retained content stays visible during validation. An unchanged warm
        // destination does not even toggle its toolbar loading indicator.
        if snapshot == nil { isLoading = true }
        do {
            let before = try await reads.revision()
            let stamp = RefreshStamp(revision: before,
                day: StudyDay.key(for: now, rolloverMinutes: rollover, calendar: calendar), calendar: calendar)
            // Match the observer's cadence: clock-dependent memory metrics may
            // change within a study day even when no database row changed.
            if !force, error == nil, !before.isEmpty, refreshRevision == stamp, previousQuery == requested,
               let snapshot, now >= snapshot.asOf, now.timeIntervalSince(snapshot.asOf) < 30 {
                return
            }
            isLoading = true
            let loaded = try await reads.load(revision: before, force: force || error != nil)
            guard token == generation, query == requested else { return }
            let source = loaded.source
            let result = await Task.detached(priority: .userInitiated) {
                StatisticsEngine.snapshot(source: source, query: requested, now: now, calendar: calendar)
            }.value
            guard token == generation, query == requested else { return }
            let after = try await reads.revision()
            guard token == generation, query == requested else { return }
            if !loaded.revision.isEmpty, after != loaded.revision {
                // Never stamp old evidence with a commit that arrived during
                // projection; the next coalesced request loads that revision.
                refreshPending = RefreshRequest(now: now, calendar: calendar, force: false)
                return
            }
            let completedStamp = RefreshStamp(revision: loaded.revision,
                day: StudyDay.key(for: now, rolloverMinutes: source.rollover, calendar: calendar), calendar: calendar)
            if sourceRevision != loaded.revision || loaded.revision.isEmpty || previousQuery != requested
                || refreshRevision != completedStamp { cancelForecast() }
            sourceRevision = loaded.revision
            previousQuery = requested
            snapshot = result
            rollover = source.rollover
            error = nil
            refreshRevision = completedStamp
        } catch is CancellationError {
            // View task teardown is not a failure of an already loaded report.
        } catch {
            if token == generation {
                self.error = "Could not refresh statistics. \(error.localizedDescription)"
            }
        }
    }
    public func observe() async {
        await refresh(force: false)
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            await refresh(force: false)
        }
    }
    public func simulate() async {
        guard let snapshot else { return }
        cancelForecast()
        isForecasting = true
        forecastGeneration += 1
        let token = forecastGeneration
        let request = forecastRequest
        let rollover = rollover
        let task = Task.detached(priority: .userInitiated) {
            let result = try StatisticsSimulator.simulate(
                snapshot: snapshot, decks: snapshot.decks, request: request, rollover: rollover)
            var baseline: StatisticsForecast?
            if request.newCardsPerDay != nil || request.desiredRetention != nil {
                var original = StatisticsForecastRequest()
                original.days = request.days
                original.seed = request.seed
                baseline = try StatisticsSimulator.simulate(
                    snapshot: snapshot, decks: snapshot.decks, request: original, rollover: rollover)
            }
            return (result, baseline)
        }
        forecastTask = task
        do {
            let result = try await task.value
            if token == forecastGeneration {
                forecast = result.0
                baselineForecast = result.1
                forecastError = nil
            }
        } catch is CancellationError {} catch {
            if token == forecastGeneration { forecastError = error.localizedDescription }
        }
        if token == forecastGeneration {
            isForecasting = false
            forecastTask = nil
        }
    }
    public func cancelForecast() {
        forecastGeneration += 1
        forecastTask?.cancel()
        forecastTask = nil
        isForecasting = false
        forecast = nil
        baselineForecast = nil
    }
}
