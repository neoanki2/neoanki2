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
        do {
            try await transport.start()
            var metadata = try await metadataStore.load()
            if !metadata.stagedInbound.isEmpty {
                let recovered = metadata.stagedInbound
                try await consumeIncoming(recovered, metadata: &metadata)
                await metadataStore.removeStagedAssets(in: recovered)
                metadata.stagedInbound = []
                try await metadataStore.save(metadata)
            }
            await synchronize()
        } catch {
            currentStatus = cloudStatus(for: error) ?? .accountUnavailable
        }
    }

    public func synchronize() async {
        currentStatus = .syncing
        do {
            var metadata = try await metadataStore.load()
            currentIssues = metadata.issues
            if metadata.didCreateInitialBackup != true {
                let destination = backupURL()
                try await repository.createBackup(at: destination)
                try await repository.verifyBackup(at: destination)
                metadata.didCreateInitialBackup = true
                try await metadataStore.save(metadata)
            }
            let local = try await repository.changes(after: metadata.outboundCursor, limit: 1_000)
            let outbound = try await adapter.encode(changes: local, deviceID: metadata.deviceID)
            if !outbound.isEmpty {
                try await transport.enqueue(outbound)
                if let cursor = local.last?.cursor {
                    metadata.outboundCursor = cursor
                    try await metadataStore.save(metadata)
                }
            }

            let incoming = try await transport.fetchPendingChanges()
            if !incoming.isEmpty {
                let stagedIncoming = try await metadataStore.stageAssets(in: incoming)
                metadata.stagedInbound = stagedIncoming
                try await metadataStore.save(metadata)
                try await consumeIncoming(stagedIncoming, metadata: &metadata)
                await metadataStore.removeStagedAssets(in: stagedIncoming)
                metadata.stagedInbound = []
            }

            metadata.issues = currentIssues
            try await metadataStore.save(metadata)
            currentStatus = currentIssues.isEmpty
                ? .current(lastSync: .now)
                : .needsAttention(issueCount: currentIssues.count)
        } catch {
            await preserveFailure(error)
        }
    }

    public func stop() async {
        await transport.stop()
        currentStatus = .offline
    }

    public func status() async -> SyncStatus { currentStatus }
    public func issues() async -> [SyncIssue] { currentIssues }

    public func retryIssue(id: UUID) async {
        currentIssues.removeAll { $0.id == id }
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
            if !merged.isEmpty { try await transport.enqueue(merged) }
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
