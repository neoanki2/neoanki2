import Foundation
import NeoAnkiApplication
import NeoAnkiCore

/// Independent immutable activity stream. Nothing enters the legacy library zone.
public actor LearningTimeSyncService {
    private let repository: any LibraryLearningTime
    private let transport: any CloudSyncTransport
    private let metadataStore: SyncMetadataStore
    private var started = false
    private var lifecycle = 0
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder
    }()
    private let decoder = JSONDecoder()

    public init(repository: any LibraryLearningTime, transport: any CloudSyncTransport, metadataStore: SyncMetadataStore) {
        self.repository = repository; self.transport = transport; self.metadataStore = metadataStore
    }
    public static func make(repository: any LibraryLearningTime, directory: URL) async throws -> LearningTimeSyncService {
        let metadata = SyncMetadataStore(directory: directory)
        let transport = try await CKSyncEngineTransport.make(metadataStore: metadata, zoneName: CKSyncEngineTransport.learningTimeZoneName)
        return LearningTimeSyncService(repository: repository, transport: transport, metadataStore: metadata)
    }
    public func stop() async { lifecycle += 1; started = false; await transport.stop() }

    public func synchronize() async throws {
        let generation = lifecycle
        if !started { try await transport.start(); try check(generation); started = true }
        let incoming = try await transport.fetchPendingChanges()
        try check(generation)
        if !incoming.isEmpty { try await metadataStore.receive(incoming) }
        var metadata = try await metadataStore.load()
        let staged = metadata.stagedInbound
        var segments: [LearningTimeSegment] = []
        var aliases: [LearningTimeItemAlias] = []
        for record in staged {
            guard !record.isTombstone, record.revision == 1 else { throw SQLiteLibrarySyncError.invalidPayload(record.id) }
            switch record.resourceKind {
            case "learningTime":
                let value = try decoder.decode(LearningTimeSegment.self, from: record.payload)
                guard value.id.uuidString == record.id else { throw SQLiteLibrarySyncError.invalidPayload(record.id) }
                segments.append(value)
            case "learningTimeItemAlias":
                let value = try decoder.decode(LearningTimeItemAlias.self, from: record.payload)
                guard value.id == record.id else { throw SQLiteLibrarySyncError.invalidPayload(record.id) }
                aliases.append(value)
            default: throw SQLiteLibrarySyncError.unknownResourceKind(record.resourceKind)
            }
        }
        // Events may arrive before their items. Aggregation waits for a live item
        // or explicit tombstone; an absent dependency never means deletion.
        try await repository.recordLearningTimeAliases(aliases)
        try await repository.recordLearningTime(segments)
        try check(generation)
        metadata = try await metadataStore.completeIncoming(staged, metadata: metadata)
        if let pending = metadata.pendingOutbound, !pending.isEmpty {
            try await send(pending, generation: generation)
            metadata = try await metadataStore.load()
        }
        // Collision mappings are small and immutable; enqueueing the snapshot is
        // safe because the transport skips content already present on the server.
        let aliasRecords = try await repository.learningTimeItemAliases().map { value in
            SyncRecordEnvelope(id: value.id, resourceKind: "learningTimeItemAlias", revision: 1,
                deviceID: metadata.deviceID, order: 0, isTombstone: false, payload: try encoder.encode(value))
        }
        if !aliasRecords.isEmpty { try await send(aliasRecords, generation: generation) }
        while true {
            try check(generation)
            metadata = try await metadataStore.load()
            let page = try await repository.learningTimeSegments(after: metadata.outboundCursor, limit: 500)
            guard let last = page.last else { break }
            let records = try page.map { row in
                SyncRecordEnvelope(id: row.segment.id.uuidString, resourceKind: "learningTime", revision: 1,
                    deviceID: row.segment.deviceID.uuidString, order: row.sequence,
                    isTombstone: false, payload: try encoder.encode(row.segment))
            }
            try await send(records, generation: generation)
            metadata = try await metadataStore.load()
            metadata.outboundCursor = last.sequence
            try await metadataStore.save(metadata)
        }
    }

    private func send(_ records: [SyncRecordEnvelope], generation: Int) async throws {
        var metadata = try await metadataStore.load()
        metadata.pendingOutbound = records
        try await metadataStore.save(metadata)
        try await transport.enqueue(records)
        try check(generation)
        try await metadataStore.acknowledge(records)
        metadata = try await metadataStore.load()
        metadata.pendingOutbound = []
        try await metadataStore.save(metadata)
    }
    private func check(_ generation: Int) throws {
        guard generation == lifecycle, !Task.isCancelled else { throw CancellationError() }
    }
}
