import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import Testing

@testable import NeoAnkiFeatures

private enum StatisticsFailure: Error { case unavailable }
private actor StatisticsCapability: LibraryStatistics {
    let base: SQLiteLibraryRepository
    var failing = false
    init(_ base: SQLiteLibraryRepository) { self.base = base }
    func setFailing(_ value: Bool) { failing = value }
    func statisticsSource() async throws -> StatisticsSource {
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
