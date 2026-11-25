import Foundation
import NeoAnkiApplication
import NeoAnkiCore

/// Independent immutable activity stream. Nothing enters the legacy library zone.
public actor StatisticsSyncService {
    private let repository: any LibraryStatistics
    private let transport: any CloudSyncTransport
    private let metadataStore: SyncMetadataStore
    private var started = false
    private var lifecycle = 0
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    public init(
        repository: any LibraryStatistics, transport: any CloudSyncTransport, metadataStore: SyncMetadataStore
    ) {
        self.repository = repository
        self.transport = transport
        self.metadataStore = metadataStore
    }
    public static func make(repository: any LibraryStatistics, directory: URL) async throws
        -> StatisticsSyncService
    {
        let metadata = SyncMetadataStore(directory: directory)
        let transport = try await CKSyncEngineTransport.make(
            metadataStore: metadata, zoneName: CKSyncEngineTransport.statisticsZoneName)
        return StatisticsSyncService(repository: repository, transport: transport, metadataStore: metadata)
    }
    public func stop() async {
        lifecycle += 1
        started = false
        await transport.stop()
    }

    @discardableResult
    public func synchronize() async throws -> Bool {
        let generation = lifecycle
        if !started {
            try await transport.start()
            try check(generation)
            started = true
        }
        let incoming = try await transport.fetchPendingChanges()
        try check(generation)
        if !incoming.isEmpty { try await metadataStore.receive(incoming) }
        var metadata = try await metadataStore.load()
        let staged = metadata.stagedInbound
        var events: [StatisticsEvent] = []
        for record in staged {
            guard !record.isTombstone, record.revision == 1, record.resourceKind == "statistics" else {
                throw SQLiteLibrarySyncError.invalidPayload(record.id)
            }
            let value = try decoder.decode(StatisticsEvent.self, from: record.payload)
            guard value.id == record.id else { throw SQLiteLibrarySyncError.invalidPayload(record.id) }
            events.append(value)
        }
        if !staged.isEmpty {
            try await repository.recordStatisticsEvents(events)
            try check(generation)
            metadata = try await metadataStore.completeIncoming(staged, metadata: metadata)
        }
        if let pending = metadata.pendingOutbound, !pending.isEmpty {
            let remaining = pending.filter { !isKnownOnServer($0, metadata: metadata) }
            if remaining.isEmpty {
                try await metadataStore.finishOutgoing(pending)
            } else {
                try await send(remaining, generation: generation)
            }
            metadata = try await metadataStore.load()
        }
        var scannedCursor = metadata.outboundCursor
        while true {
            try check(generation)
            let page = try await repository.statisticsEvents(after: scannedCursor, limit: 500)
            try check(generation)
            guard let last = page.last else { break }
            let records = try page.map { row in
                SyncRecordEnvelope(
                    id: row.event.id, resourceKind: "statistics", revision: 1,
                    deviceID: metadata.deviceID, order: row.sequence,
                    isTombstone: false, payload: try encoder.encode(row.event))
            }.filter { !isKnownOnServer($0, metadata: metadata) }
            if !records.isEmpty {
                try await send(records, generation: generation, through: last.sequence)
                metadata = try await metadataStore.load()
            }
            scannedCursor = last.sequence
        }
        // A catch-up can scan many pages of received history without a single
        // upload. Save their progress together instead of rewriting the baseline per page.
        if scannedCursor > metadata.outboundCursor {
            metadata.outboundCursor = scannedCursor
            try await metadataStore.save(metadata)
        }
        return !staged.isEmpty
    }

    private func isKnownOnServer(_ record: SyncRecordEnvelope, metadata: SyncMetadata) -> Bool {
        guard let known = metadata.serverBaseline?[record.syncKey],
              known.revision == record.revision, known.isTombstone == record.isTombstone,
              known.asset == record.asset else { return false }
        if known.payload == record.payload { return true }
        // JSON key order can differ across clients. Compare the facts so a
        // review with genuinely new context still goes through upload preflight.
        guard let remote = try? decoder.decode(StatisticsEvent.self, from: known.payload) else { return false }
        return (try? decoder.decode(StatisticsEvent.self, from: record.payload)) == remote
    }

    private func send(_ records: [SyncRecordEnvelope], generation: Int, through cursor: Int64? = nil) async throws {
        var metadata = try await metadataStore.load()
        metadata.pendingOutbound = records
        try await metadataStore.save(metadata)
        try await transport.enqueue(records)
        try check(generation)
        try await metadataStore.acknowledge(records)
        metadata = try await metadataStore.load()
        metadata.pendingOutbound = []
        if let cursor { metadata.outboundCursor = max(metadata.outboundCursor, cursor) }
        try await metadataStore.save(metadata)
    }
    private func check(_ generation: Int) throws {
        guard generation == lifecycle, !Task.isCancelled else { throw CancellationError() }
    }
}
