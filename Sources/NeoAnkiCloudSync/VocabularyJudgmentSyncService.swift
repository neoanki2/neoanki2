import Foundation
import NeoAnkiApplication
import NeoAnkiCore

/// Explicit judgments are immutable events. The repository resolves conflicts and
/// keeps clear events so stale devices cannot resurrect a removed judgment.
public actor VocabularyJudgmentSyncService {
    private let repository: SQLiteLibraryRepository
    private let transport: any CloudSyncTransport
    private let metadata: SyncMetadataStore
    private var started = false
    private var lifecycle = 0

    public init(repository: SQLiteLibraryRepository, transport: any CloudSyncTransport,
                metadata: SyncMetadataStore) {
        self.repository = repository
        self.transport = transport
        self.metadata = metadata
    }

    public static func make(repository: SQLiteLibraryRepository, directory: URL) async throws -> Self {
        let metadata = SyncMetadataStore(directory: directory)
        let transport = try await CKSyncEngineTransport.make(metadataStore: metadata, zoneName: CKSyncEngineTransport.knownWordsZoneName)
        return .init(repository: repository, transport: transport, metadata: metadata)
    }

    func committedChanges() async -> AsyncStream<Void> {
        await repository.vocabularyNotifications()
    }

    func stop() async {
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
        if !incoming.isEmpty { try await metadata.receive(incoming) }
        var state = try await metadata.load()
        let staged = state.stagedInbound
        if !staged.isEmpty {
            let changes = try staged.map { record in
                guard record.resourceKind == "vocabularyJudgment", !record.isTombstone, record.revision == 1,
                      let change = try? JSONDecoder().decode(VocabularyJudgmentChange.self, from: record.payload),
                      change.id.uuidString == record.id else { throw SQLiteLibrarySyncError.invalidPayload(record.id) }
                return change
            }
            try await repository.mergeVocabularyJudgments(changes)
            try check(generation)
            state = try await metadata.completeIncoming(staged, metadata: state)
        }
        while true {
            try check(generation)
            let records: [SyncRecordEnvelope]
            if let pending = state.pendingOutbound, !pending.isEmpty {
                records = pending
            } else {
                let page = try await repository.vocabularyJudgments(after: state.outboundCursor, limit: 200)
                if page.isEmpty { break }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                records = try page.map { row in
                    .init(id: row.change.id.uuidString, resourceKind: "vocabularyJudgment", revision: 1,
                          deviceID: state.deviceID, order: row.sequence, isTombstone: false,
                          payload: try encoder.encode(row.change))
                }
                state.pendingOutbound = records
                try await metadata.save(state)
            }
            try await transport.enqueue(records)
            try check(generation)
            try await metadata.acknowledge(records)
            state = try await metadata.load()
            state.pendingOutbound = []
            if let last = records.last { state.outboundCursor = max(state.outboundCursor, last.order) }
            try await metadata.save(state)
        }
        return !staged.isEmpty
    }

    private func check(_ generation: Int) throws {
        guard generation == lifecycle, !Task.isCancelled else { throw CancellationError() }
    }
}
