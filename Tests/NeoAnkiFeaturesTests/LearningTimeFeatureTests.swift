import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import Testing

private enum LearningReportFailure: Error { case unavailable }
private actor ReportCapability: LibraryLearningTime {
    let base: SQLiteLibraryRepository
    var failing = false
    init(_ base: SQLiteLibraryRepository) { self.base = base }
    func setFailing(_ value: Bool) { failing = value }
    func learningTimeLibraryID() async throws -> UUID { try await base.learningTimeLibraryID() }
    func recordLearningTime(_ segments: [LearningTimeSegment]) async throws { try await base.recordLearningTime(segments) }
    func learningTimeSegments(after sequence: Int64, limit: Int) async throws -> [LearningTimeStoredSegment] {
        try await base.learningTimeSegments(after: sequence, limit: limit)
    }
    func recordLearningTimeAliases(_ aliases: [LearningTimeItemAlias]) async throws { try await base.recordLearningTimeAliases(aliases) }
    func learningTimeItemAliases() async throws -> [LearningTimeItemAlias] { try await base.learningTimeItemAliases() }
    func learningTimeNotifications() async -> AsyncStream<Void> { await base.learningTimeNotifications() }
    func learningTimeSummary(scope: DeckScope, period: LearningTimePeriod, asOf: Date, calendar: Calendar) async throws -> LearningTimeSummary {
        if failing { throw LearningReportFailure.unavailable }
        return try await base.learningTimeSummary(scope: scope, period: period, asOf: asOf, calendar: calendar)
    }
}

@Test @MainActor func learningTimeReportKeepsLastSuccessfulTotalsOnFailure() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("learning-report-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let library = try SQLiteLibraryRepository(databaseURL: folder.appendingPathComponent("library.sqlite"))
    try await library.bootstrap()
    let capability = ReportCapability(library)
    let model = LearningTimeFeatureModel(library: library, scope: .allDecks, learningTime: capability)
    #expect(model.summary == nil)
    await model.refresh()
    #expect(model.summary?.totalMilliseconds == 0)
    #expect(model.summary?.trackingStartedAt == nil)
    let type = try #require(try await library.loadItemTypes().itemTypes.first)
    let item = Item(itemTypeID: type.id, fields: type.fields.map { .init(fieldID: $0.id, value: .text("Example")) })
    _ = try await library.createItem(item, asOf: .now)
    let start = Date.now.addingTimeInterval(-60)
    try await library.recordLearningTime([LearningTimeSegment(sessionID: UUID(), deviceID: UUID(), sourceLibraryID: library.libraryID(),
        itemID: item.id, cardID: UUID(), startedAt: start, endedAt: start.addingTimeInterval(10), durationMilliseconds: 10_000)])
    model.period = .allTime
    await model.refresh()
    let saved = try #require(model.summary)
    #expect(saved.totalMilliseconds == 10_000)
    #expect(model.allTime?.totalMilliseconds == 10_000)
    await capability.setFailing(true)
    model.period = .last7Days; await model.refresh()
    #expect(model.summary == saved)
    #expect(model.error != nil)
    #expect(!model.isLoading)
    await capability.setFailing(false); await model.refresh()
    #expect(model.error == nil)
    #expect(model.summary?.totalMilliseconds == 10_000)
}
