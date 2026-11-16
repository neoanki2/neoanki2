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
    public private(set) var isLoading = false
    public private(set) var isForecasting = false
    public private(set) var error: String?
    public private(set) var forecastError: String?
    public private(set) var rollover = StudyDay.defaultRolloverMinutes
    private let capability: (any LibraryStatistics)?
    private var refreshRevision: String?
    private var sourceRevision = -1
    private var previousQuery: StatisticsQuery?
    private var projectingQuery: StatisticsQuery?
    private var refreshPending = false
    private var generation = 0
    private var forecastTask: Task<(StatisticsForecast, StatisticsForecast?), Error>?
    private var forecastGeneration = 0
    public init(
        library: any LibraryRepository, scope: DeckScope = .allDecks, sessionID: UUID? = nil,
        statistics: (any LibraryStatistics)? = nil
    ) {
        capability = statistics ?? (library as? any LibraryStatistics)
        query = StatisticsQuery(scope: scope, sessionID: sessionID)
        if sessionID != nil { section = .activity }
    }
    public func refresh(now: Date = .now, calendar: Calendar = .autoupdatingCurrent, force: Bool = true) async
    {
        // Rapid filter edits coalesce behind one projection. Stale results
        // are discarded without running several large histories in parallel.
        if let projectingQuery {
            if query != projectingQuery {
                generation += 1
                refreshPending = true
            }
            return
        }
        projectingQuery = query
        defer {
            projectingQuery = nil
            if refreshPending {
                refreshPending = false
                Task { await refresh() }
            }
        }
        generation += 1
        let token = generation
        let requested = query
        isLoading = true
        guard let capability else {
            error = "Statistics are unavailable for this library."
            isLoading = false
            return
        }
        do {
            let before = try await capability.statisticsRevision()
            let stamp =
                "\(before):\(StudyDay.key(for:now,rolloverMinutes:rollover,calendar:calendar)):\(calendar.timeZone.identifier)"
            if !force, refreshRevision == stamp, previousQuery == requested {
                isLoading = false
                return
            }
            let source = try await capability.statisticsSource()
            let result = await Task.detached(priority: .userInitiated) {
                StatisticsEngine.snapshot(source: source, query: requested, now: now, calendar: calendar)
            }.value
            guard token == generation else { return }
            let revision = source.events.count + source.segments.count
            if sourceRevision != revision || previousQuery != requested { cancelForecast() }
            sourceRevision = revision
            previousQuery = requested
            snapshot = result
            rollover = source.rollover
            error = nil
            let after = try await capability.statisticsRevision()
            refreshRevision =
                "\(after):\(StudyDay.key(for:now,rolloverMinutes:source.rollover,calendar:calendar)):\(calendar.timeZone.identifier)"
        } catch {
            if token == generation {
                self.error = "Could not refresh statistics. \(error.localizedDescription)"
            }
        }
        if token == generation { isLoading = false }
    }
    public func observe() async {
        await refresh()
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
