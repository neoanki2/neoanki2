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
    private var failsNextMerge: Bool
    private var mergedIDs: Set<String> = []
    init(failsNextMerge: Bool = false) { self.failsNextMerge = failsNextMerge }
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
        mergedIDs = Set(remote.map(\.id))
        if failsNextMerge {
            failsNextMerge = false
            throw NSError(domain: "SyncRecoveryTest", code: 1)
        }
        return remote
    }
    func counts() -> (initial: Int, apply: Int) { (initialMergeCalls, applyCalls) }
    func lastMergedIDs() -> Set<String> { mergedIDs }
}

private actor TransportStub: CloudSyncTransport {
    var sent: [SyncRecordEnvelope] = []
    var received: [SyncRecordEnvelope]
    init(received: [SyncRecordEnvelope] = []) { self.received = received }
    func start() async throws {}
    func stop() async {}
    func enqueue(_ records: [SyncRecordEnvelope]) async throws { sent.append(contentsOf: records) }
    func fetchPendingChanges() async throws -> [SyncRecordEnvelope] { received }
    func sentCount() -> Int { sent.count }
    func receive(_ records: [SyncRecordEnvelope]) { received = records }
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

private actor SuspendedUploadTransport: CloudSyncTransport {
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?
    var calls = 0
    func start() async throws {}
    func stop() async {}
    func fetchPendingChanges() async throws -> [SyncRecordEnvelope] { [] }
    func enqueue(_ records: [SyncRecordEnvelope]) async throws {
        calls += 1
        await withCheckedContinuation { continuation in
            release = continuation
            entered = true
            for waiter in waiters { waiter.resume() }
            waiters = []
        }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func finish() { release?.resume(); release = nil }
}

struct OfflineFirstSyncServiceTests {
    @Test func stopWinsOverAnInFlightUploadAndOverlappingSyncIsCoalesced() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let change = LibraryChange(cursor: 1, transactionID: UUID(), sequence: 0, eventType: "updated",
            resourceType: "deck", resourceID: "deck", revision: 1, isTombstone: false, occurredAt: .now)
        let metadata = SyncMetadataStore(directory: directory)
        try await metadata.save(SyncMetadata(didCreateInitialBackup: true, didCompleteInitialMerge: true))
        let transport = SuspendedUploadTransport()
        let service = OfflineFirstSyncService(repository: ChangeRepositoryStub(values: [change]),
            adapter: SyncAdapterStub(), transport: transport, metadataStore: metadata,
            backupURL: { directory.appendingPathComponent("backup.sqlite") })
        let running = Task { await service.start() }
        await transport.waitUntilEntered()
        await service.synchronize()
        #expect(await transport.calls == 1)
        await service.stop()
        await transport.finish()
        await running.value
        #expect(await service.status() == .offline)
        #expect(await service.issues().isEmpty)
        #expect(try await metadata.load().pendingOutbound?.count == 1)
    }

    @Test func retriesPreservedMergeBeforeReportingCurrentWithoutRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoanki-sync-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadata = SyncMetadataStore(directory: directory)
        let incoming = SyncRecordEnvelope(
            id: "deck", resourceKind: "deck", revision: 1, deviceID: "cloud",
            order: 1, isTombstone: false, payload: Data()
        )
        try await metadata.save(SyncMetadata(stagedInbound: [incoming], didCreateInitialBackup: true))
        let adapter = SyncAdapterStub(failsNextMerge: true)
        let transport = TransportStub()
        let service = OfflineFirstSyncService(
            repository: ChangeRepositoryStub(values: []), adapter: adapter,
            transport: transport, metadataStore: metadata,
            backupURL: { directory.appendingPathComponent("backup.sqlite") }
        )
        await service.synchronize()
        #expect(try await metadata.load().stagedInbound.count == 1)
        if case .needsAttention = await service.status() {} else {
            Issue.record("A failed preserved merge must not report current")
        }
        await transport.receive([SyncRecordEnvelope(
            id: "later-dependency", resourceKind: "deck", revision: 1, deviceID: "cloud",
            order: 2, isTombstone: false, payload: Data()
        )])
        await service.synchronize()
        #expect(await adapter.counts().initial == 2)
        #expect(await adapter.lastMergedIDs() == ["deck", "later-dependency"])
        #expect(try await metadata.load().stagedInbound.isEmpty)
        #expect(try await metadata.load().didCompleteInitialMerge == true)
        #expect(await service.issues().isEmpty)
        if case .current = await service.status() {} else { Issue.record("Expected recovered sync") }
    }

    @Test func drainsAndCoalescesChangesAcrossJournalPages() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoanki-sync-pages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let changes = (1...1_002).map { cursor in
            LibraryChange(
                cursor: Int64(cursor), transactionID: UUID(), sequence: 0,
                eventType: cursor == 1_002 ? "deleted" : "updated",
                resourceType: "deck", resourceID: "later-deleted-deck",
                revision: cursor, isTombstone: cursor == 1_002, occurredAt: .now
            )
        }
        let transport = TransportStub()
        let metadata = SyncMetadataStore(directory: directory)
        try await metadata.save(SyncMetadata(didCompleteInitialMerge: true))
        let service = OfflineFirstSyncService(
            repository: ChangeRepositoryStub(values: changes), adapter: SyncAdapterStub(),
            transport: transport, metadataStore: metadata,
            backupURL: { directory.appendingPathComponent("backup.sqlite") }
        )
        await service.synchronize()
        #expect(await transport.sentCount() == 1)
        #expect(try await metadata.load().outboundCursor == 1_002)
        #expect(await transport.sent.first?.isTombstone == true)
    }

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
        try await metadataStore.save(SyncMetadata(didCompleteInitialMerge: true))
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
        try await metadataStore.save(SyncMetadata(didCompleteInitialMerge: true))
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

private actor ConflictRecoveryAdapter: LibrarySyncAdapter {
    let fails: Bool
    private(set) var restored: [UUID] = []
    init(fails: Bool = false) { self.fails = fails }
    func encode(changes: [LibraryChange], deviceID: String) async throws -> [SyncRecordEnvelope] { [] }
    func applyRemote(_ records: [SyncRecordEnvelope], origin: LibraryChangeOrigin) async throws {}
    func initialMerge(remote: [SyncRecordEnvelope], deviceID: String) async throws -> [SyncRecordEnvelope] { [] }
    func restoreConflictCopy(_ copy: SyncConflictCopy) async throws {
        if fails { throw SQLiteLibrarySyncError.invalidPayload(copy.originalResourceID) }
        restored.append(copy.id)
    }
}

@Test func oldCardConflictAutomaticallyArchivesWithoutDuplicatingAnItem() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let copy = SyncConflictCopy(resourceKind: "card", originalResourceID: "card", sourceDeviceID: "local", payload: Data("preserved state".utf8))
    let issue = SyncIssue(kind: .itemConflict, resourceID: "card", summary: "Old conflict", conflictCopy: copy)
    let metadata = SyncMetadataStore(directory: directory)
    try await metadata.save(SyncMetadata(issues: [issue], didCreateInitialBackup: true, didCompleteInitialMerge: true))
    let adapter = ConflictRecoveryAdapter()
    let service = OfflineFirstSyncService(repository: ChangeRepositoryStub(values: []), adapter: adapter,
        transport: TransportStub(), metadataStore: metadata, backupURL: { directory.appendingPathComponent("backup") })
    await service.synchronize()
    #expect(await service.issues().isEmpty)
    #expect(await adapter.restored.isEmpty)
    #expect(try await metadata.load().resolvedConflictCopies == [copy])
    if case .current = await service.status() {} else { Issue.record("Automatically resolved conflict should be Current") }
    await service.synchronize()
    #expect(try await metadata.load().resolvedConflictCopies == [copy])
}

@Test func failedAutomaticRecoveryRetainsOriginalConflictAndPayloadForRetry() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let copy = SyncConflictCopy(resourceKind: "item", originalResourceID: "item", sourceDeviceID: "local", payload: Data("preserved content".utf8))
    let issue = SyncIssue(kind: .itemConflict, resourceID: "item", summary: "Old conflict", conflictCopy: copy)
    let metadata = SyncMetadataStore(directory: directory)
    try await metadata.save(SyncMetadata(issues: [issue], didCreateInitialBackup: true, didCompleteInitialMerge: true))
    let service = OfflineFirstSyncService(repository: ChangeRepositoryStub(values: []), adapter: ConflictRecoveryAdapter(fails: true),
        transport: TransportStub(), metadataStore: metadata, backupURL: { directory.appendingPathComponent("backup") })
    await service.synchronize()
    let retained = try await metadata.load()
    #expect(retained.issues.contains(issue))
    #expect(retained.resolvedConflictCopies?.isEmpty != false)
    #expect(await service.issues().contains(issue))
    // A subsequent automatic retry can finish the preserved work.
    let recovered = OfflineFirstSyncService(repository: ChangeRepositoryStub(values: []), adapter: ConflictRecoveryAdapter(),
        transport: TransportStub(), metadataStore: metadata, backupURL: { directory.appendingPathComponent("backup") })
    await recovered.synchronize()
    #expect(await recovered.issues().isEmpty)
    #expect(try await metadata.load().resolvedConflictCopies == [copy])
}
