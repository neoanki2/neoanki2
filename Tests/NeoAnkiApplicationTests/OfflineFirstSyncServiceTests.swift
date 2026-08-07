import Foundation
import NeoAnkiApplication
import NeoAnkiCloudSync
import NeoAnkiCore
import Testing

private actor ChangeRepositoryStub: LibraryChangePersisting {
    let values: [LibraryChange]
    init(values: [LibraryChange]) { self.values = values }
    func currentChangeCursor() async throws -> Int64 { values.last?.cursor ?? 0 }
    func changes(after cursor: Int64, limit: Int) async throws -> [LibraryChange] {
        Array(values.filter { $0.cursor > cursor }.prefix(limit))
    }
    func createBackup(at destination: URL) async throws {
        try Data("backup".utf8).write(to: destination)
    }
}

private actor SyncAdapterStub: LibrarySyncAdapter {
    func encode(changes: [LibraryChange], deviceID: String) async throws -> [SyncRecordEnvelope] {
        changes.map {
            SyncRecordEnvelope(
                id: $0.resourceID,
                resourceKind: $0.resourceType,
                revision: $0.revision,
                deviceID: deviceID,
                order: $0.cursor,
                isTombstone: $0.isTombstone,
                payload: Data()
            )
        }
    }
    func applyRemote(_ records: [SyncRecordEnvelope], origin: LibraryChangeOrigin) async throws {}
    func initialMerge(remote: [SyncRecordEnvelope], deviceID: String) async throws -> [SyncRecordEnvelope] {
        remote
    }
}

private actor TransportStub: CloudSyncTransport {
    var sent: [SyncRecordEnvelope] = []
    let received: [SyncRecordEnvelope]
    init(received: [SyncRecordEnvelope] = []) { self.received = received }
    func start() async throws {}
    func stop() async {}
    func enqueue(_ records: [SyncRecordEnvelope]) async throws { sent.append(contentsOf: records) }
    func fetchPendingChanges() async throws -> [SyncRecordEnvelope] { received }
    func sentCount() -> Int { sent.count }
}

struct OfflineFirstSyncServiceTests {
    @Test func advancesDurableCursorAfterSendingLocalChanges() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoanki-sync-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let change = LibraryChange(
            cursor: 7,
            transactionID: UUID(),
            sequence: 0,
            eventType: "updated",
            resourceType: "item",
            resourceID: "item-1",
            revision: 2,
            isTombstone: false,
            occurredAt: .now
        )
        let repository = ChangeRepositoryStub(values: [change])
        let transport = TransportStub()
        let metadataStore = SyncMetadataStore(directory: directory)
        let service = OfflineFirstSyncService(
            repository: repository,
            adapter: SyncAdapterStub(),
            transport: transport,
            metadataStore: metadataStore,
            backupURL: { directory.appendingPathComponent("backup.sqlite") }
        )

        await service.synchronize()

        #expect(await transport.sentCount() == 1)
        #expect(try await metadataStore.load().outboundCursor == 7)
        if case .current = await service.status() {} else {
            Issue.record("Expected current sync status")
        }
    }
}
