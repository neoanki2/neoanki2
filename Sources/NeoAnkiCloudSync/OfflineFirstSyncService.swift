import CloudKit
import Foundation
import NeoAnkiApplication
import NeoAnkiCore

/// Coordinates a local-authoritative repository and an independent CloudKit
/// transport. Transport failure changes status but never prevents local work.
public actor OfflineFirstSyncService: SyncService {
    private let repository: any LibraryChangePersisting
    private let adapter: any LibrarySyncAdapter
    private let transport: any CloudSyncTransport
    private let metadataStore: SyncMetadataStore
    private let backupURL: @Sendable () -> URL
    private var currentStatus: SyncStatus = .offline
    private var currentIssues: [SyncIssue] = []
    private var isSynchronizing = false
    private var automaticSyncTask: Task<Void, Never>?
    private var transportStarted = false
    private var lifecycle = 0

    public init(
        repository: any LibraryChangePersisting,
        adapter: any LibrarySyncAdapter,
        transport: any CloudSyncTransport,
        metadataStore: SyncMetadataStore,
        backupURL: @escaping @Sendable () -> URL
    ) {
        self.repository = repository
        self.adapter = adapter
        self.transport = transport
        self.metadataStore = metadataStore
        self.backupURL = backupURL
    }

    public func start() async {
        let generation = lifecycle
        await synchronize()
        guard generation == lifecycle else { return }
        if automaticSyncTask == nil {
            automaticSyncTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(10)) }
                    catch { return }
                    await self?.synchronize()
                }
            }
        }
    }

    public func synchronize() async {
        guard !isSynchronizing else { return }
        isSynchronizing = true
        defer { isSynchronizing = false }
        currentStatus = .syncing
        let generation = lifecycle
        do {
            if !transportStarted {
                try await transport.start()
                try checkLifecycle(generation)
                transportStarted = true
            }
            var metadata = try await metadataStore.load()
            currentIssues = metadata.issues
            if metadata.didCreateInitialBackup != true {
                let destination = backupURL()
                try await repository.createBackup(at: destination)
                try await repository.verifyBackup(at: destination)
                metadata.didCreateInitialBackup = true
                try await metadataStore.save(metadata)
            }
            try checkLifecycle(generation)
            // A cursor may advance only after its payloads are durably queued.
            // A process restart must not depend on CKSyncEngine's in-memory
            // records or on an adapter's consumed echo suppression entries.
            try await flushOutbound(metadata: &metadata, generation: generation)
            if metadata.didCompleteInitialMerge == true {
                try await stageLocalChanges(metadata: &metadata)
                try await flushOutbound(metadata: &metadata, generation: generation)
            }

            let incoming = try await transport.fetchPendingChanges()
            try checkLifecycle(generation)
            if !incoming.isEmpty { try await metadataStore.receive(incoming) }
            // The transport can durably stage callbacks while an awaited send
            // or fetch is in flight. Reload, never overwrite that newer inbox.
            metadata = try await metadataStore.load()
            currentIssues = metadata.issues
            // An empty cloud still requires the complete initial snapshot;
            // uploading a local journal first can overwrite colliding identities.
            if metadata.didCompleteInitialMerge != true || !metadata.stagedInbound.isEmpty {
                let recovered = metadata.stagedInbound
                let beforeMergeCursor = try await repository.currentChangeCursor()
                let firstMerge = metadata.didCompleteInitialMerge != true
                try await consumeIncoming(recovered, metadata: &metadata)
                if firstMerge { metadata.outboundCursor = beforeMergeCursor }
                metadata.stagedInbound = []
                metadata.issues = currentIssues
                metadata = try await metadataStore.completeIncoming(recovered, metadata: metadata)
            }
            try await flushOutbound(metadata: &metadata, generation: generation)
            try await stageLocalChanges(metadata: &metadata)
            try await flushOutbound(metadata: &metadata, generation: generation)

            try checkLifecycle(generation)
            metadata = try await metadataStore.load()
            currentIssues = metadata.issues
            currentIssues.removeAll { $0.resourceID == "sync-batch" && $0.conflictCopy == nil }
            metadata.issues = currentIssues
            try await metadataStore.save(metadata)
            try checkLifecycle(generation)
            currentStatus = !currentIssues.isEmpty ? .needsAttention(issueCount: currentIssues.count)
                : !metadata.stagedInbound.isEmpty || !(metadata.pendingOutbound ?? []).isEmpty ? .syncing
                : .current(lastSync: .now)
        } catch is CancellationError {
            currentStatus = .offline
        } catch {
            if generation == lifecycle { await preserveFailure(error) }
        }
    }

    private func stageLocalChanges(metadata: inout SyncMetadata) async throws {
        var latest: [String: LibraryChange] = [:]
        var cursor = metadata.outboundCursor
        while true {
            let page = try await repository.changes(after: cursor, limit: 1_000)
            guard let last = page.last else { break }
            for change in page { latest["\(change.resourceType):\(change.resourceID)"] = change }
            cursor = last.cursor
            if page.count < 1_000 { break }
        }
        let changes = latest.values.sorted { $0.cursor < $1.cursor }
        let outbound = try await adapter.encode(changes: changes, deviceID: metadata.deviceID)
        metadata.pendingOutbound = (metadata.pendingOutbound ?? []) + (try await metadataStore.stageOutbound(outbound))
        metadata.outboundCursor = cursor
        try await metadataStore.save(metadata)
    }

    private func checkLifecycle(_ generation: Int) throws {
        guard generation == lifecycle, !Task.isCancelled else { throw CancellationError() }
    }

    private func flushOutbound(metadata: inout SyncMetadata, generation: Int) async throws {
        try checkLifecycle(generation)
        guard let pending = metadata.pendingOutbound, !pending.isEmpty else { return }
        try await transport.enqueue(pending)
        try checkLifecycle(generation)
        metadata = try await metadataStore.load()
        currentIssues = metadata.issues
        metadata.pendingOutbound = []
        try await metadataStore.save(metadata)
        await metadataStore.removeStagedAssets(in: pending)
    }

    public func stop() async {
        lifecycle += 1
        automaticSyncTask?.cancel()
        automaticSyncTask = nil
        await transport.stop()
        transportStarted = false
        currentStatus = .offline
    }

    public func status() async -> SyncStatus { currentStatus }
    public func issues() async -> [SyncIssue] { currentIssues }

    public func retryIssue(id: UUID) async {
        currentIssues.removeAll { $0.id == id }
        await persistIssues()
        await synchronize()
    }

    public func dismissIssue(id: UUID) async {
        currentIssues.removeAll { $0.id == id }
        await persistIssues()
        currentStatus = currentIssues.isEmpty ? .current(lastSync: .now) : .needsAttention(issueCount: currentIssues.count)
    }

    public func restoreConflictCopy(forIssueID id: UUID) async throws {
        guard let issue = currentIssues.first(where: { $0.id == id }), let copy = issue.conflictCopy else {
            throw UserFacingError(title: "Conflict Can’t Be Restored", message: "The preserved copy is no longer available.")
        }
        try await adapter.restoreConflictCopy(copy)
        currentIssues.removeAll { $0.id == id }
        await persistIssues()
        await synchronize()
    }

    private func persistIssues() async {
        do {
            var metadata = try await metadataStore.load()
            metadata.issues = currentIssues
            try await metadataStore.save(metadata)
        } catch {}
    }

    private func conflictKind(_ resourceKind: String) -> SyncIssueKind {
        switch resourceKind {
        case LibraryResourceKind.deck.rawValue: .deckConflict
        case LibraryResourceKind.itemType.rawValue: .itemTypeConflict
        default: .itemConflict
        }
    }

    private func conflictKind(_ copy: SyncConflictCopy) -> SyncIssueKind {
        if copy.wasTombstone || copy.acceptedWasTombstone { return .deleteVersusEdit }
        return conflictKind(copy.resourceKind)
    }

    private func consumeIncoming(
        _ records: [SyncRecordEnvelope],
        metadata: inout SyncMetadata
    ) async throws {
        if metadata.didCompleteInitialMerge != true {
            let merged = try await adapter.initialMerge(
                remote: records,
                deviceID: metadata.deviceID
            )
            let copies = await adapter.preservedConflictCopies()
            for copy in copies where !currentIssues.contains(where: { $0.conflictCopy?.id == copy.id }) {
                currentIssues.append(SyncIssue(
                    kind: conflictKind(copy),
                    resourceID: copy.originalResourceID,
                    summary: "A change from another device was accepted. Your prior version is preserved.",
                    conflictCopy: copy
                ))
            }
            metadata.pendingOutbound = (metadata.pendingOutbound ?? []) + (try await metadataStore.stageOutbound(merged))
            metadata.didCompleteInitialMerge = true
        } else {
            try await adapter.applyRemote(records, origin: .cloud)
        }
    }

    private func preserveFailure(_ error: any Error) async {
        if let status = cloudStatus(for: error) {
            currentStatus = status
            return
        }
        let issue = SyncIssue(
            kind: (error as? SQLiteLibrarySyncError).map {
                if case .invalidAsset = $0 { return .mediaFailure }
                return .invalidRemoteChange
            } ?? .invalidRemoteChange,
            resourceID: "sync-batch",
            summary: "A sync batch was preserved for recovery: \(String(describing: error))"
        )
        currentIssues.removeAll { $0.resourceID == "sync-batch" && $0.conflictCopy == nil }
        currentIssues.append(issue)
        do {
            var metadata = try await metadataStore.load()
            metadata.issues = currentIssues
            try await metadataStore.save(metadata)
        } catch {
            // Keep the in-memory issue. The separate metadata store is retried
            // by the next synchronization and domain tables remain unchanged.
        }
        currentStatus = .needsAttention(issueCount: currentIssues.count)
    }

    private func cloudStatus(for error: any Error) -> SyncStatus? {
        let nsError = error as NSError
        if nsError.domain == CKErrorDomain,
           let code = CKError.Code(rawValue: nsError.code) {
            switch code {
            case .networkUnavailable, .networkFailure, .serviceUnavailable,
                 .requestRateLimited, .zoneBusy:
                return .offline
            case .notAuthenticated, .accountTemporarilyUnavailable,
                 .permissionFailure, .managedAccountRestricted:
                return .accountUnavailable
            default:
                break
            }
        }
        return nil
    }
}
