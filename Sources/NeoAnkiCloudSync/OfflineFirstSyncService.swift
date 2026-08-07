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
            await synchronize()
        } catch {
            currentStatus = .accountUnavailable
        }
    }

    public func synchronize() async {
        currentStatus = .syncing
        do {
            var metadata = try await metadataStore.load()
            currentIssues = metadata.issues
            let local = try await repository.changes(after: metadata.outboundCursor, limit: 1_000)
            let outbound = try await adapter.encode(changes: local, deviceID: metadata.deviceID)
            if !outbound.isEmpty { try await transport.enqueue(outbound) }

            let incoming = try await transport.fetchPendingChanges()
            if !incoming.isEmpty {
                metadata.stagedInbound = incoming
                try await metadataStore.save(metadata)
                if metadata.outboundCursor == 0 {
                    try await repository.createBackup(at: backupURL())
                    let merged = try await adapter.initialMerge(
                        remote: incoming,
                        deviceID: metadata.deviceID
                    )
                    if !merged.isEmpty { try await transport.enqueue(merged) }
                } else {
                    try await adapter.applyRemote(incoming, origin: .cloud)
                }
                metadata.stagedInbound = []
            }

            if let cursor = local.last?.cursor { metadata.outboundCursor = cursor }
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

    private func preserveFailure(_ error: any Error) async {
        let issue = SyncIssue(
            kind: .invalidRemoteChange,
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
}
