import CloudKit
import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import Testing

@testable import NeoAnkiCloudSync

private enum StatisticsSyncFailure: Error { case offline }
private actor StatisticsTransport: CloudSyncTransport {
    var incoming: [SyncRecordEnvelope] = [], sent: [SyncRecordEnvelope] = []
    var failing = false
    func start() async throws {}
    func stop() async {}
    func enqueue(_ records: [SyncRecordEnvelope]) async throws {
        if failing { throw StatisticsSyncFailure.offline }
        sent += records
    }
    func fetchPendingChanges() async throws -> [SyncRecordEnvelope] {
        let rows = incoming
        incoming = []
        return rows
    }
    func receive(_ rows: [SyncRecordEnvelope]) { incoming += rows }
    func setFailing(_ value: Bool) { failing = value }
    func sentRecords() -> [SyncRecordEnvelope] { sent }
}
private func statisticsSyncFixture() async throws -> (SQLiteLibraryRepository, URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("statistics-sync-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let library = try SQLiteLibraryRepository(databaseURL: folder.appendingPathComponent("library.sqlite"))
    try await library.bootstrap()
    return (library, folder)
}
@Test func statisticsSyncSurvivesRestartAndDuplicateDelivery() async throws {
    let (library, folder) = try await statisticsSyncFixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let card = UUID()
    let now = Date.now
    let log = ReviewLog(
        cardID: card, reviewedAt: now, rating: .good, elapsedDays: 2, scheduledDays: 2, phaseBefore: .review,
        durationMs: 1000)
    let event = StatisticsEvent(
        id: "review:" + log.id.uuidString, kind: "review", occurredAt: now, cardID: card, log: log)
    try await library.recordStatisticsEvents([event])
    let transport = StatisticsTransport()
    let metadata = SyncMetadataStore(directory: folder.appendingPathComponent("sync"))
    await transport.setFailing(true)
    let first = StatisticsSyncService(repository: library, transport: transport, metadataStore: metadata)
    await #expect(throws: StatisticsSyncFailure.self) { try await first.synchronize() }
    #expect(try await metadata.load().outboundCursor == 0)
    await first.stop()
    await transport.setFailing(false)
    let recovered = StatisticsSyncService(repository: library, transport: transport, metadataStore: metadata)
    try await recovered.synchronize()
    let records = await transport.sentRecords()
    await transport.receive(records + records)
    try await recovered.synchronize()
    #expect(try await library.statisticsSource().events.filter { $0.id == event.id }.count == 1)
    #expect(try await metadata.load().pendingOutbound?.isEmpty == true)
}
@Test func statisticsSyncAcceptsUndoBeforeReviewWithoutContent() async throws {
    let (library, folder) = try await statisticsSyncFixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let card = UUID()
    let now = Date.now
    let log = ReviewLog(
        cardID: card, reviewedAt: now, rating: .again, elapsedDays: 2, scheduledDays: 2, phaseBefore: .review,
        durationMs: 1000)
    let events = [
        StatisticsEvent(
            id: "undo:" + log.id.uuidString, kind: "undo", occurredAt: now, cardID: card, templateID: log.id),
        StatisticsEvent(
            id: "review:" + log.id.uuidString, kind: "review", occurredAt: now, cardID: card, log: log),
    ]
    let envelopes = try events.map {
        SyncRecordEnvelope(
            id: $0.id, resourceKind: "statistics", revision: 1, deviceID: "other", order: 0,
            isTombstone: false, payload: try JSONEncoder().encode($0))
    }
    let transport = StatisticsTransport()
    await transport.receive(envelopes)
    let sync = StatisticsSyncService(
        repository: library, transport: transport,
        metadataStore: SyncMetadataStore(directory: folder.appendingPathComponent("sync")))
    try await sync.synchronize()
    let s = StatisticsEngine.snapshot(
        source: try await library.statisticsSource(), query: .init(), now: now.addingTimeInterval(1))
    #expect(s.reviewCount == 0)
}
@Test func statisticsUsesAnIndependentPrivateZone() {
    #expect(CKSyncEngineTransport.statisticsZoneName != CKSyncEngineTransport.zoneName)
    #expect(CKSyncEngineTransport.statisticsZoneName != CKSyncEngineTransport.learningTimeZoneName)
}

@Test func statisticsFailureDoesNotPreventIndependentLearningTimeSync() async throws {
    let (library, folder) = try await statisticsSyncFixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let now = Date.now
    let card = UUID()
    let review = ReviewLog(
        cardID: card, reviewedAt: now, rating: .good, elapsedDays: 2, scheduledDays: 2, phaseBefore: .review,
        durationMs: 1000)
    try await library.recordStatisticsEvents([
        .init(
            id: "review:" + review.id.uuidString, kind: "review", occurredAt: now, cardID: card, log: review)
    ])
    let segment = LearningTimeSegment(
        sessionID: UUID(), deviceID: UUID(), sourceLibraryID: try await library.libraryID(), itemID: UUID(),
        cardID: card, startedAt: now.addingTimeInterval(-10), endedAt: now, durationMilliseconds: 10000)
    try await library.recordLearningTime([segment])
    let statisticsTransport = StatisticsTransport()
    let timeTransport = StatisticsTransport()
    let mainTransport = StatisticsTransport()
    await statisticsTransport.setFailing(true)
    let service = OfflineFirstSyncService(
        repository: library, adapter: SQLiteLibrarySyncAdapter(repository: library), transport: mainTransport,
        metadataStore: SyncMetadataStore(directory: folder.appendingPathComponent("main-sync")),
        learningTime: LearningTimeSyncService(
            repository: library, transport: timeTransport,
            metadataStore: SyncMetadataStore(directory: folder.appendingPathComponent("time-sync"))),
        statistics: StatisticsSyncService(
            repository: library, transport: statisticsTransport,
            metadataStore: SyncMetadataStore(directory: folder.appendingPathComponent("stats-sync"))),
        backupURL: { folder.appendingPathComponent("backup.sqlite") })
    await service.synchronize()
    #expect(await timeTransport.sentRecords().contains { $0.id == segment.id.uuidString })
}
