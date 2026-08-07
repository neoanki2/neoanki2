import CloudKit
import Foundation
import NeoAnkiApplication

private actor TransportBuffers {
    var outgoing: [CKRecord.ID: SyncRecordEnvelope] = [:]
    var incoming: [SyncRecordEnvelope] = []

    func enqueue(_ envelope: SyncRecordEnvelope, id: CKRecord.ID) {
        outgoing[id] = envelope
    }

    func envelope(for id: CKRecord.ID) -> SyncRecordEnvelope? { outgoing[id] }

    func remove(_ ids: [CKRecord.ID]) {
        for id in ids { outgoing[id] = nil }
    }

    func appendIncoming(_ values: [SyncRecordEnvelope]) { incoming.append(contentsOf: values) }

    func drainIncoming() -> [SyncRecordEnvelope] {
        defer { incoming.removeAll() }
        return incoming
    }
}

/// Private-database transport for NeoAnki's fixed custom library zone.
/// Local SQLite remains authoritative; this type only moves durable envelopes.
public final class CKSyncEngineTransport: CloudSyncTransport, CKSyncEngineDelegate, @unchecked Sendable {
    public static let containerIdentifier = "iCloud.com.neoanki2.app"
    public static let zoneName = "NeoAnkiLibrary"

    private let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    private let buffers = TransportBuffers()
    private let metadataStore: SyncMetadataStore
    private let initialState: CKSyncEngine.State.Serialization?
    private lazy var engine: CKSyncEngine = {
        let container = CKContainer(identifier: Self.containerIdentifier)
        let configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: initialState,
            delegate: self
        )
        return CKSyncEngine(configuration)
    }()

    private init(metadataStore: SyncMetadataStore, initialState: CKSyncEngine.State.Serialization?) {
        self.metadataStore = metadataStore
        self.initialState = initialState
    }

    public static func make(metadataStore: SyncMetadataStore) async throws -> CKSyncEngineTransport {
        let metadata = try await metadataStore.load()
        return CKSyncEngineTransport(metadataStore: metadataStore, initialState: metadata.engineState)
    }

    public func start() async throws {
        let zone = CKRecordZone(zoneID: zoneID)
        engine.state.add(pendingDatabaseChanges: [.saveZone(zone)])
        try await engine.sendChanges()
        try await engine.fetchChanges(.init(scope: .zoneIDs([zoneID])))
    }

    public func stop() async {
        await engine.cancelOperations()
    }

    public func enqueue(_ records: [SyncRecordEnvelope]) async throws {
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        for envelope in records {
            let id = recordID(for: envelope)
            await buffers.enqueue(envelope, id: id)
            changes.append(envelope.isTombstone ? .deleteRecord(id) : .saveRecord(id))
        }
        engine.state.add(pendingRecordZoneChanges: changes)
        try await engine.sendChanges(.init(scope: .zoneIDs([zoneID])))
    }

    public func fetchPendingChanges() async throws -> [SyncRecordEnvelope] {
        try await engine.fetchChanges(.init(scope: .zoneIDs([zoneID])))
        return await buffers.drainIncoming()
    }

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case let .stateUpdate(update):
            do {
                var metadata = try await metadataStore.load()
                metadata.engineState = update.stateSerialization
                try await metadataStore.save(metadata)
            } catch {
                // A later state event retries persistence. Domain data remains
                // untouched and the engine can refetch from its server token.
            }
        case let .fetchedRecordZoneChanges(changes):
            let received = changes.modifications.compactMap { Self.envelope(from: $0.record) }
                + changes.deletions.compactMap { Self.tombstone(from: $0.recordID) }
            await buffers.appendIncoming(received)
        case let .sentRecordZoneChanges(changes):
            await buffers.remove(changes.savedRecords.map(\.recordID) + changes.deletedRecordIDs)
        default:
            break
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter(context.options.scope.contains)
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [buffers] id in
            guard let envelope = await buffers.envelope(for: id), !envelope.isTombstone else {
                return nil
            }
            return Self.record(from: envelope, id: id)
        }
    }

    public func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        .init(scope: .zoneIDs([zoneID]))
    }

    private static func record(from envelope: SyncRecordEnvelope, id: CKRecord.ID) -> CKRecord {
        let record = CKRecord(recordType: "LibraryResource", recordID: id)
        record["resourceID"] = envelope.id as CKRecordValue
        record["resourceKind"] = envelope.resourceKind as CKRecordValue
        record["revision"] = envelope.revision as CKRecordValue
        record["deviceID"] = envelope.deviceID as CKRecordValue
        record["order"] = envelope.order as CKRecordValue
        record["payload"] = envelope.payload as CKRecordValue
        return record
    }

    private static func envelope(from record: CKRecord) -> SyncRecordEnvelope? {
        guard
            let resourceID = record["resourceID"] as? String,
            let resourceKind = record["resourceKind"] as? String,
            let revision = record["revision"] as? Int,
            let deviceID = record["deviceID"] as? String,
            let order = record["order"] as? Int64,
            let payload = record["payload"] as? Data
        else { return nil }
        return SyncRecordEnvelope(
            id: resourceID,
            resourceKind: resourceKind,
            revision: revision,
            deviceID: deviceID,
            order: order,
            isTombstone: false,
            payload: payload
        )
    }

    private func recordID(for envelope: SyncRecordEnvelope) -> CKRecord.ID {
        CKRecord.ID(
            recordName: "\(envelope.resourceKind)__\(envelope.id)",
            zoneID: zoneID
        )
    }

    private static func tombstone(from id: CKRecord.ID) -> SyncRecordEnvelope? {
        guard let separator = id.recordName.range(of: "__") else { return nil }
        let kind = String(id.recordName[..<separator.lowerBound])
        let resourceID = String(id.recordName[separator.upperBound...])
        guard !kind.isEmpty, !resourceID.isEmpty else { return nil }
        return SyncRecordEnvelope(
            id: resourceID,
            resourceKind: kind,
            revision: 0,
            deviceID: "cloud",
            order: 0,
            isTombstone: true,
            payload: Data()
        )
    }
}
