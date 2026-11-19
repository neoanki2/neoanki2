import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import Testing
import Observation

@testable import NeoAnkiFeatures

private enum StatisticsFailure: Error { case unavailable }
private actor StatisticsCapability: LibraryStatistics {
    let base: SQLiteLibraryRepository
    var failing = false
    private(set) var sourceReads = 0
    init(_ base: SQLiteLibraryRepository) { self.base = base }
    func setFailing(_ value: Bool) { failing = value }
    func statisticsSource() async throws -> StatisticsSource {
        sourceReads += 1
        if failing { throw StatisticsFailure.unavailable }
        return try await base.statisticsSource()
    }
    func statisticsEvents(after cursor: Int64, limit: Int) async throws -> [StatisticsStoredEvent] {
        try await base.statisticsEvents(after: cursor, limit: limit)
    }
    func recordStatisticsEvents(_ events: [StatisticsEvent]) async throws {
        try await base.recordStatisticsEvents(events)
    }
}

@Test @MainActor func statisticsWithoutRevisionSupportReloadRatherThanReusingStaleEvidence() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("statistics-unversioned-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
    try await library.bootstrap()
    let capability = StatisticsCapability(library)
    let model = StatisticsFeatureModel(library: library, statistics: capability)
    await model.refresh(force: false)
    _ = try await library.createDeck(Deck(name: "Unversioned change"))
    await model.refresh(force: false)
    #expect(model.snapshot?.decks.first?.name == "Unversioned change")
    #expect(await capability.sourceReads == 2)
}
@Test @MainActor func statisticsFeatureKeepsLastSuccessfulSnapshotOnFailure() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "statistics-feature-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = try SQLiteLibraryRepository(databaseURL: directory.appendingPathComponent("library.sqlite"))
    try await library.bootstrap()
    let capability = StatisticsCapability(library)
    let model = StatisticsFeatureModel(library: library, statistics: capability)
    await model.refresh()
    #expect(model.snapshot != nil)
    #expect(model.error == nil)
    let saved = model.snapshot?.csv
    await capability.setFailing(true)
    model.query.period = .week
    await model.refresh()
    #expect(model.snapshot?.csv == saved)
    #expect(model.error != nil)
    #expect(!model.isLoading)
    await capability.setFailing(false)
    await model.refresh()
    #expect(model.error == nil)
}
@Test @MainActor func statisticsSessionNavigationUsesTheSharedFeatureOnAllPlatforms() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "statistics-navigation-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = try SQLiteLibraryRepository(databaseURL: directory.appendingPathComponent("library.sqlite"))
    try await library.bootstrap()
    let sessionID = UUID()
    let scope = DeckScope.unassigned
    let mac = StatisticsFeatureModel(library: library, scope: scope, sessionID: sessionID)
    let ios = StatisticsFeatureModel(library: library, scope: scope, sessionID: sessionID)
    let now = Date.now
    await mac.refresh(now: now)
    await ios.refresh(now: now)
    #expect(mac.query == ios.query)
    #expect(mac.section == .activity)
    #expect(mac.query.period == .all)
    #expect(mac.snapshot?.csv == ios.snapshot?.csv)
}

private actor NavigationStatistics: LibraryStatistics {
    private var source: StatisticsSource
    private var version = 1
    private var failing = false
    private var shouldHold = false
    private var held: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var revisionWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var sourceReads = 0
    private(set) var revisionReads = 0
    init(_ source: StatisticsSource) { self.source = source }
    func update(_ value: StatisticsSource) { source = value; version += 1 }
    func setFailing(_ value: Bool) { failing = value }
    func holdNextRead() { shouldHold = true }
    func waitUntilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { held?.resume(); held = nil }
    func waitForRevisionReads(_ count: Int) async {
        if revisionReads >= count { return }
        await withCheckedContinuation { revisionWaiters.append((count, $0)) }
    }
    func statisticsRevision() -> String {
        revisionReads += 1
        let ready = revisionWaiters.filter { $0.0 <= revisionReads }
        revisionWaiters.removeAll { $0.0 <= revisionReads }
        for (_, waiter) in ready { waiter.resume() }
        return "navigation-\(version)"
    }
    func statisticsSource() async throws -> StatisticsSource {
        sourceReads += 1
        let value = source
        if shouldHold {
            shouldHold = false
            await withCheckedContinuation { held = $0; observer?.resume(); observer = nil }
        }
        if failing { throw StatisticsFailure.unavailable }
        return value
    }
    func statisticsEvents(after cursor: Int64, limit: Int) -> [StatisticsStoredEvent] { [] }
    func recordStatisticsEvents(_ events: [StatisticsEvent]) { source.events += events; version += 1 }
}

private final class LoadingChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var changes = 0
    func changed() { lock.withLock { changes += 1 } }
    var count: Int { lock.withLock { changes } }
}

@Suite @MainActor struct StatisticsWorkspaceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private func fixture() async throws -> (URL, SQLiteLibraryRepository, NavigationStatistics) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("statistics-workspace-\(UUID())")
        let library = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
        try await library.bootstrap()
        return (root, library, NavigationStatistics(try await library.statisticsSource()))
    }

    @Test func repeatedNavigationPreservesReportsWithoutHydrationProjectionOrLoadingChanges() async throws {
        let (root, library, capability) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = StatisticsWorkspace(library: library, statistics: capability)
        let home = workspace.home()
        let report = workspace.report()
        #expect(home !== report)
        await home.refresh(now: now, calendar: calendar, force: false)
        await report.refresh(now: now, calendar: calendar, force: false)
        #expect(await capability.sourceReads == 1, "Home and reports share immutable evidence")
        let changes = LoadingChanges()
        withObservationTracking { _ = home.isLoading; _ = report.isLoading } onChange: { changes.changed() }
        for _ in 0..<20 {
            #expect(workspace.home() === home)
            #expect(workspace.report() === report)
            await home.refresh(now: now.addingTimeInterval(1), calendar: calendar, force: false)
            await report.refresh(now: now.addingTimeInterval(1), calendar: calendar, force: false)
        }
        #expect(changes.count == 0)
        #expect(home.snapshot?.asOf == now && report.snapshot?.asOf == now, "Unchanged navigation does not rerun projection")
        #expect(await capability.sourceReads == 1)
        report.section = .memory
        report.query.period = .week
        await report.refresh(now: now.addingTimeInterval(2), calendar: calendar, force: false)
        #expect(home.query.period == .today)
        #expect(workspace.report().query.period == .week && workspace.report().section == .memory)
        #expect(await capability.sourceReads == 1, "Changing filters reuses source evidence")
    }

    @Test func reappearingObserverUsesValidationInsteadOfForcedRefresh() async throws {
        let (root, library, capability) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = StatisticsWorkspace(library: library, statistics: capability).report()
        await model.refresh(force: false)
        let checks = await capability.revisionReads
        let date = model.snapshot?.asOf
        let observer = Task { await model.observe() }
        await capability.waitForRevisionReads(checks + 1)
        observer.cancel()
        await observer.value
        #expect(await capability.sourceReads == 1)
        #expect(model.snapshot?.asOf == date)
        #expect(!model.isLoading)
    }

    @Test func timeRolloverTimezoneAndBackwardClockReprojectWithoutRereadingEvidence() async throws {
        let (root, library, capability) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = StatisticsWorkspace(library: library, statistics: capability).report()
        await model.refresh(now: now, calendar: calendar, force: false)
        await model.refresh(now: now.addingTimeInterval(29), calendar: calendar, force: false)
        #expect(model.snapshot?.asOf == now)
        await model.refresh(now: now.addingTimeInterval(30), calendar: calendar, force: false)
        #expect(model.snapshot?.asOf == now.addingTimeInterval(30))
        await model.refresh(now: now.addingTimeInterval(-1), calendar: calendar, force: false)
        #expect(model.snapshot?.asOf == now.addingTimeInterval(-1))
        let oldRange = model.snapshot?.range
        var shifted = calendar
        shifted.timeZone = TimeZone(secondsFromGMT: 3600)!
        await model.refresh(now: now, calendar: shifted, force: false)
        #expect(model.snapshot?.asOf == now && model.snapshot?.range != oldRange)
        let rollover = StudyDay.nextRollover(after: now, rolloverMinutes: model.rollover, calendar: calendar)
        await model.refresh(now: rollover.addingTimeInterval(-1), calendar: calendar, force: false)
        await model.refresh(now: rollover, calendar: calendar, force: false)
        #expect(model.snapshot?.asOf == rollover)
        #expect(await capability.sourceReads == 1)
    }

    @Test func revisionChangesRefreshBothContextsFromOneNewSource() async throws {
        let (root, library, capability) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = StatisticsWorkspace(library: library, statistics: capability)
        let home = workspace.home(), report = workspace.report()
        await home.refresh(now: now, calendar: calendar, force: false)
        await report.refresh(now: now, calendar: calendar, force: false)
        _ = try await library.createDeck(Deck(name: "New deck"))
        await capability.update(try await library.statisticsSource())
        await home.refresh(now: now, calendar: calendar, force: false)
        await report.refresh(now: now, calendar: calendar, force: false)
        #expect(await capability.sourceReads == 2)
        #expect(home.snapshot?.decks.count == 1 && report.snapshot?.decks.count == 1)
    }

    @Test func explicitRetryBypassesCacheAndPreservesSuccessfulContentOnFailure() async throws {
        let (root, library, capability) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = StatisticsWorkspace(library: library, statistics: capability).report()
        await model.refresh(now: now, calendar: calendar, force: false)
        let saved = model.snapshot?.csv
        await capability.setFailing(true)
        await model.refresh(now: now, calendar: calendar)
        #expect(model.error != nil && model.snapshot?.csv == saved)
        #expect(!model.isLoading)
        await capability.setFailing(false)
        await model.refresh(now: now, calendar: calendar, force: false)
        #expect(await capability.sourceReads == 3)
        #expect(model.error == nil)
    }

    @Test func concurrentDestinationsShareAReadAndNavigationCancellationDoesNotRestartIt() async throws {
        let (root, library, capability) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = StatisticsWorkspace(library: library, statistics: capability)
        let home = workspace.home(), report = workspace.report()
        await capability.holdNextRead()
        let first = Task { await home.refresh(now: now, calendar: calendar, force: false) }
        await capability.waitUntilHeld()
        let second = Task { await report.refresh(now: now, calendar: calendar, force: false) }
        await capability.waitForRevisionReads(3)
        first.cancel()
        await capability.release()
        await first.value; await second.value
        #expect(await capability.sourceReads == 1)
        #expect(home.snapshot != nil && report.snapshot != nil)
        #expect(home.error == nil && report.error == nil)
        #expect(!home.isLoading && !report.isLoading)
    }

    @Test func commitDuringReadCannotBeStampedAsAnAlreadyLoadedRevision() async throws {
        let (root, library, capability) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = StatisticsWorkspace(library: library, statistics: capability).report()
        await capability.holdNextRead()
        let read = Task { await model.refresh(now: now, calendar: calendar, force: false) }
        await capability.waitUntilHeld()
        _ = try await library.createDeck(Deck(name: "Arrived during read"))
        await capability.update(try await library.statisticsSource())
        await capability.release()
        await read.value
        #expect(model.snapshot?.decks.first?.name == "Arrived during read")
        #expect(await capability.sourceReads == 2)
        await model.refresh(now: now, calendar: calendar, force: false)
        #expect(await capability.sourceReads == 2)
    }

    @Test func rapidFiltersPublishOnlyTheLatestQuery() async throws {
        let (root, library, capability) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = StatisticsWorkspace(library: library, statistics: capability).report()
        await capability.holdNextRead()
        let initial = Task { await model.refresh(now: now, calendar: calendar, force: false) }
        await capability.waitUntilHeld()
        model.query.period = .week
        await model.refresh(now: now, calendar: calendar, force: false)
        model.query.period = .today
        let latest = now.addingTimeInterval(1)
        await model.refresh(now: latest, calendar: calendar, force: false)
        await capability.release()
        await initial.value
        #expect(model.snapshot?.asOf == latest)
        #expect(model.snapshot?.range.start == StudyDay.start(for: latest, rolloverMinutes: model.rollover, calendar: calendar))
        #expect(await capability.sourceReads == 1)
    }

    @Test func workspaceRetentionIsBoundedAndKeepsRecentContexts() async throws {
        let (root, library, capability) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = StatisticsWorkspace(library: library, statistics: capability, capacity: 2)
        let home = workspace.home(), report = workspace.report()
        #expect(workspace.home() === home)
        _ = workspace.report(scope: .unassigned)
        #expect(workspace.home() === home)
        #expect(workspace.report() !== report)
        let factory = LibraryFeatureFactory(library: library)
        let scene = factory.makeStatisticsWorkspace()
        #expect(scene.report() === scene.report())
        #expect(scene.home() !== scene.report())
        #expect(factory.makeStatistics() !== factory.makeStatistics(), "Standalone factory clients retain independent model ownership")
    }

    @Test func completedScenariosAndSettingsSurviveWarmNavigationButExpireAtRollover() async throws {
        let (root, library, capability) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = StatisticsWorkspace(library: library, statistics: capability)
        let model = workspace.report()
        await model.refresh(now: now, calendar: calendar, force: false)
        model.forecastRequest.newCardsPerDay = 7
        model.forecastRequest.desiredRetention = 0.85
        await model.simulate()
        #expect(model.forecast != nil)
        await workspace.home().refresh(now: now, calendar: calendar, force: false)
        await workspace.report().refresh(now: now.addingTimeInterval(1), calendar: calendar, force: false)
        #expect(model.forecast != nil)
        #expect(workspace.report().forecastRequest.newCardsPerDay == 7)
        #expect(workspace.report().forecastRequest.desiredRetention == 0.85)
        let rollover = StudyDay.nextRollover(after: now, rolloverMinutes: model.rollover, calendar: calendar)
        await model.refresh(now: rollover, calendar: calendar, force: false)
        #expect(model.forecast == nil)
    }
}
