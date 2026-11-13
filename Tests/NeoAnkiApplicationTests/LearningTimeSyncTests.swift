import CloudKit
import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import Testing
@testable import NeoAnkiCloudSync

private enum ActivitySyncFailure: Error { case offline }
private actor ActivityTransport: CloudSyncTransport {
    var received: [SyncRecordEnvelope] = []
    var sent: [SyncRecordEnvelope] = []
    var failing = false
    func start() async throws {}
    func stop() async {}
    func enqueue(_ records: [SyncRecordEnvelope]) async throws {
        if failing { throw ActivitySyncFailure.offline }
        sent += records
    }
    func fetchPendingChanges() async throws -> [SyncRecordEnvelope] { received }
    func receive(_ value: [SyncRecordEnvelope]) { received = value }
    func setFailing(_ value: Bool) { failing = value }
    func sentRecords() -> [SyncRecordEnvelope] { sent }
}
private func activityRepository() async throws -> (SQLiteLibraryRepository, URL, Item) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("learning-sync-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let repository = try SQLiteLibraryRepository(databaseURL: directory.appendingPathComponent("library.sqlite"))
    try await repository.bootstrap()
    let type = try #require(try await repository.loadItemTypes().itemTypes.first)
    let item = Item(itemTypeID: type.id, fields: type.fields.map { FieldValue(fieldID: $0.id, value: .text("Example")) })
    _ = try await repository.createItem(item, asOf: .now)
    return (repository, directory, item)
}
private func activitySegment(_ item: Item, source: UUID = UUID(), id: UUID = UUID()) -> LearningTimeSegment {
    let start = Date.now.addingTimeInterval(-60)
    return LearningTimeSegment(id: id, sessionID: UUID(), deviceID: UUID(), sourceLibraryID: source,
        itemID: item.id, cardID: UUID(), startedAt: start, endedAt: start.addingTimeInterval(10), durationMilliseconds: 10_000)
}

@Test func learningTimeSyncDeduplicatesDeliveryAndNeverUsesLibraryJournal() async throws {
    let (repository, directory, item) = try await activityRepository(); defer { try? FileManager.default.removeItem(at: directory) }
    let cursor = try await repository.currentChangeCursor()
    let segment = activitySegment(item)
    try await repository.recordLearningTime([segment])
    #expect(try await repository.currentChangeCursor() == cursor)
    let transport = ActivityTransport(), metadata = SyncMetadataStore(directory: directory.appendingPathComponent("sync"))
    let service = LearningTimeSyncService(repository: repository, transport: transport, metadataStore: metadata)
    try await service.synchronize()
    let records = await transport.sentRecords()
    #expect(records.count == 1); #expect(records.first?.resourceKind == "learningTime")
    await transport.receive(records + records)
    try await service.synchronize(); try await service.synchronize()
    #expect(try await repository.learningTimeSegments(after: 0, limit: 100).count == 1)
    #expect(try await repository.learningTimeSummary(scope: .allDecks, period: .allTime, asOf: .now, calendar: .current).totalMilliseconds == 10_000)
    let legacy = try await SQLiteLibrarySyncAdapter(repository: repository).initialMerge(remote: [], deviceID: "legacy")
    #expect(!legacy.contains { $0.resourceKind.hasPrefix("learningTime") })
}

@Test func learningTimeSyncRecoversPendingUploadAfterRestart() async throws {
    let (repository, directory, item) = try await activityRepository(); defer { try? FileManager.default.removeItem(at: directory) }
    let segment = activitySegment(item); try await repository.recordLearningTime([segment])
    let transport = ActivityTransport(), metadata = SyncMetadataStore(directory: directory.appendingPathComponent("sync"))
    await transport.setFailing(true)
    let first = LearningTimeSyncService(repository: repository, transport: transport, metadataStore: metadata)
    await #expect(throws: ActivitySyncFailure.self) { try await first.synchronize() }
    #expect(try await metadata.load().outboundCursor == 0)
    #expect(try await metadata.load().pendingOutbound?.first?.id == segment.id.uuidString)
    await first.stop(); await transport.setFailing(false)
    let recovered = LearningTimeSyncService(repository: repository, transport: transport, metadataStore: metadata)
    try await recovered.synchronize()
    #expect(try await metadata.load().outboundCursor == 1)
    #expect(try await metadata.load().pendingOutbound?.isEmpty == true)
    #expect(Set(await transport.sentRecords().map(\.id)) == [segment.id.uuidString])
}

@Test func learningTimeSyncCombinesDevicesAndStagesMissingContent() async throws {
    let (repository, directory, item) = try await activityRepository(); defer { try? FileManager.default.removeItem(at: directory) }
    try await repository.recordLearningTime([activitySegment(item)])
    let missing = Item(itemTypeID: item.itemTypeID, fields: item.fields)
    let remote = activitySegment(missing)
    let envelope = SyncRecordEnvelope(id: remote.id.uuidString, resourceKind: "learningTime", revision: 1,
        deviceID: "remote", order: 1, isTombstone: false, payload: try JSONEncoder().encode(remote))
    let transport = ActivityTransport(); await transport.receive([envelope])
    let service = LearningTimeSyncService(repository: repository, transport: transport,
        metadataStore: SyncMetadataStore(directory: directory.appendingPathComponent("sync")))
    try await service.synchronize()
    var total = try await repository.learningTimeSummary(scope: .allDecks, period: .allTime, asOf: .now, calendar: .current)
    #expect(total.totalMilliseconds == 10_000); #expect(total.deletedMilliseconds == 0)
    _ = try await repository.createItem(missing, asOf: .now)
    total = try await repository.learningTimeSummary(scope: .allDecks, period: .allTime, asOf: .now, calendar: .current)
    #expect(total.totalMilliseconds == 20_000)
}

@Test func learningTimeCloudZoneHasIndependentSubscriptionAndMetadata() {
    #expect(CKSyncEngineTransport.learningTimeZoneName != CKSyncEngineTransport.zoneName)
    let zone = CKRecordZone.ID(zoneName: CKSyncEngineTransport.learningTimeZoneName)
    let subscription = CKSyncEngineTransport.librarySubscription(zoneID: zone, subscriptionID: CKSyncEngineTransport.learningTimeSubscriptionID)
    #expect(subscription.zoneID == zone)
    #expect(subscription.subscriptionID != CKSyncEngineTransport.librarySubscriptionID)
}

@Test func learningTimeSyncPersistsLibraryCollisionMappings() async throws {
    let (local, localDirectory, localItem) = try await activityRepository()
    let (remote, remoteDirectory, _) = try await activityRepository()
    defer { try? FileManager.default.removeItem(at: localDirectory); try? FileManager.default.removeItem(at: remoteDirectory) }
    let conflicting = Item(id: localItem.id, itemTypeID: localItem.itemTypeID,
        fields: localItem.fields.map { .init(fieldID: $0.fieldID, value: .text("Remote version")) })
    _ = try await remote.createItem(conflicting, asOf: .now)
    let remoteLibraryID = try await remote.libraryID()
    let records = try await SQLiteLibrarySyncAdapter(repository: remote).initialMerge(remote: [], deviceID: "remote")
    _ = try await SQLiteLibrarySyncAdapter(repository: local).initialMerge(remote: records, deviceID: "local")
    let alias = try #require(try await local.learningTimeItemAliases().first { $0.originalItemID == localItem.id })
    #expect(alias.sourceLibraryID == remoteLibraryID)
    #expect(alias.resolvedItemID != localItem.id)
    #expect(try await local.item(id: alias.resolvedItemID) != nil)
    try await local.recordLearningTime([activitySegment(conflicting, source: remoteLibraryID)])
    #expect(try await local.learningTimeSummary(scope: .allDecks, period: .allTime, asOf: .now, calendar: .current).totalMilliseconds == 10_000)
    let transport = ActivityTransport()
    let service = LearningTimeSyncService(repository: local, transport: transport,
        metadataStore: SyncMetadataStore(directory: localDirectory.appendingPathComponent("time-sync")))
    try await service.synchronize()
    #expect(await transport.sentRecords().contains { $0.resourceKind == "learningTimeItemAlias" })
}

@Test func learningTimeFailureDoesNotPreventOrdinaryLibraryUpload() async throws {
    let (repository, directory, item) = try await activityRepository(); defer { try? FileManager.default.removeItem(at: directory) }
    try await repository.recordLearningTime([activitySegment(item)])
    let activityTransport = ActivityTransport(), libraryTransport = ActivityTransport()
    await activityTransport.setFailing(true)
    let activity = LearningTimeSyncService(repository: repository, transport: activityTransport,
        metadataStore: SyncMetadataStore(directory: directory.appendingPathComponent("activity-sync")))
    let service = OfflineFirstSyncService(repository: repository,
        adapter: SQLiteLibrarySyncAdapter(repository: repository), transport: libraryTransport,
        metadataStore: SyncMetadataStore(directory: directory.appendingPathComponent("library-sync")), learningTime: activity,
        backupURL: { directory.appendingPathComponent("backup.sqlite") })
    await service.synchronize()
    #expect(await libraryTransport.sentRecords().contains { $0.resourceKind == "item" })
    #expect(await service.status() == .needsAttention(issueCount: 1))
    await activityTransport.setFailing(false)
    await service.synchronize()
    if case .current = await service.status() {} else { Issue.record("Expected activity recovery to clear sync failure") }
    await service.stop()
}
