import CloudKit
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
    private var initialMergeCalls = 0
    private var applyCalls = 0
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
    func applyRemote(_ records: [SyncRecordEnvelope], origin: LibraryChangeOrigin) async throws {
        applyCalls += 1
    }
    func initialMerge(remote: [SyncRecordEnvelope], deviceID: String) async throws -> [SyncRecordEnvelope] {
        initialMergeCalls += 1
        return remote
    }
    func counts() -> (initial: Int, apply: Int) { (initialMergeCalls, applyCalls) }
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

private actor FailingTransportStub: CloudSyncTransport {
    enum FailurePoint { case start, fetch }
    let failurePoint: FailurePoint
    private var sent: [SyncRecordEnvelope] = []
    init(_ failurePoint: FailurePoint) { self.failurePoint = failurePoint }
    func start() async throws {
        if failurePoint == .start {
            throw NSError(domain: CKErrorDomain, code: CKError.Code.notAuthenticated.rawValue)
        }
    }
    func stop() async {}
    func enqueue(_ records: [SyncRecordEnvelope]) async throws { sent.append(contentsOf: records) }
    func fetchPendingChanges() async throws -> [SyncRecordEnvelope] {
        if failurePoint == .fetch {
            throw NSError(domain: CKErrorDomain, code: CKError.Code.networkUnavailable.rawValue)
        }
        return []
    }
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

    @Test func networkFailureKeepsOfflineStatusAndDoesNotResendAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoanki-sync-network-\(UUID().uuidString)", isDirectory: true)
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
        let metadataStore = SyncMetadataStore(directory: directory)
        let failing = FailingTransportStub(.fetch)
        let first = OfflineFirstSyncService(
            repository: repository,
            adapter: SyncAdapterStub(),
            transport: failing,
            metadataStore: metadataStore,
            backupURL: { directory.appendingPathComponent("backup.sqlite") }
        )
        await first.synchronize()
        #expect(await failing.sentCount() == 1)
        #expect(try await metadataStore.load().outboundCursor == 7)
        #expect(await first.issues().isEmpty)
        #expect(await first.status() == .offline)

        let succeeding = TransportStub()
        let restarted = OfflineFirstSyncService(
            repository: repository,
            adapter: SyncAdapterStub(),
            transport: succeeding,
            metadataStore: metadataStore,
            backupURL: { directory.appendingPathComponent("backup.sqlite") }
        )
        await restarted.synchronize()
        #expect(await succeeding.sentCount() == 0)
    }

    @Test func restartResumesStagedFirstMergeInsteadOfApplyingItAsOrdinaryPull() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoanki-sync-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let incoming = SyncRecordEnvelope(
            id: UUID().uuidString,
            resourceKind: "deck",
            revision: 1,
            deviceID: "cloud",
            order: 1,
            isTombstone: false,
            payload: Data("payload".utf8)
        )
        let metadataStore = SyncMetadataStore(directory: directory)
        try await metadataStore.save(SyncMetadata(
            stagedInbound: [incoming],
            didCreateInitialBackup: true,
            didCompleteInitialMerge: false
        ))
        let adapter = SyncAdapterStub()
        let service = OfflineFirstSyncService(
            repository: ChangeRepositoryStub(values: []),
            adapter: adapter,
            transport: TransportStub(),
            metadataStore: metadataStore,
            backupURL: { directory.appendingPathComponent("backup.sqlite") }
        )
        await service.start()
        let counts = await adapter.counts()
        #expect(counts.initial == 1)
        #expect(counts.apply == 0)
        let recovered = try await metadataStore.load()
        #expect(recovered.didCompleteInitialMerge == true)
        #expect(recovered.stagedInbound.isEmpty)
    }

    @Test func accountFailureIsReportedWithoutCreatingRecoveryIssue() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoanki-sync-account-\(UUID().uuidString)", isDirectory: true)
        let service = OfflineFirstSyncService(
            repository: ChangeRepositoryStub(values: []),
            adapter: SyncAdapterStub(),
            transport: FailingTransportStub(.start),
            metadataStore: SyncMetadataStore(directory: directory),
            backupURL: { directory.appendingPathComponent("backup.sqlite") }
        )
        await service.start()
        #expect(await service.status() == .accountUnavailable)
        #expect(await service.issues().isEmpty)
    }
}
