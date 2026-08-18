import CloudKit
import Foundation
import NeoAnkiApplication
#if os(macOS)
import Security
#endif

public enum CKSyncEngineTransportError: Error, Equatable, LocalizedError, Sendable {
    case missingContainerEntitlement(String)

    public var errorDescription: String? {
        switch self {
        case let .missingContainerEntitlement(identifier):
            "This build is not provisioned for the iCloud container \(identifier)."
        }
    }
}

private actor TransportBuffers {
    var outgoing: [CKRecord.ID: SyncRecordEnvelope] = [:]
    var incoming: [SyncRecordEnvelope] = []

    func enqueue(_ envelope: SyncRecordEnvelope, id: CKRecord.ID) {
        outgoing[id] = envelope
    }

    func envelope(for id: CKRecord.ID) -> SyncRecordEnvelope? { outgoing[id] }

    func remove(_ ids: [CKRecord.ID]) {
        for id in ids {
            if let url = outgoing[id]?.stagedFileURL,
               url.lastPathComponent.hasPrefix("neoanki-sync-") {
                try? FileManager.default.removeItem(at: url)
            }
            outgoing[id] = nil
        }
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
    private static let containerIdentifiersEntitlement =
        "com.apple.developer.icloud-container-identifiers"

    /// Creating a `CKContainer` for an identifier absent from the executable's
    /// signed entitlements terminates the process instead of throwing an error.
    /// Check the effective signature first so ad-hoc development builds can
    /// report that sync is unavailable without crashing.
    public static var isAvailable: Bool {
#if os(macOS)
        (try? validateCurrentProcessEntitlements()) != nil
#else
        true
#endif
    }

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
        try validateCurrentProcessEntitlements()
        let metadata = try await metadataStore.load()
        return CKSyncEngineTransport(metadataStore: metadataStore, initialState: metadata.engineState)
    }

    static func validateContainerIdentifiers(_ identifiers: [String]?) throws {
        guard identifiers?.contains(containerIdentifier) == true else {
            throw CKSyncEngineTransportError.missingContainerEntitlement(containerIdentifier)
        }
    }

    private static func validateCurrentProcessEntitlements() throws {
#if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                  task,
                  containerIdentifiersEntitlement as CFString,
                  nil
              )
        else {
            throw CKSyncEngineTransportError.missingContainerEntitlement(containerIdentifier)
        }
        try validateContainerIdentifiers(value as? [String])
#endif
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
            var resolvedFailures: [CKRecord.ID] = []
            for failure in changes.failedRecordSaves where failure.error.code == .serverRecordChanged {
                if let server = failure.error.serverRecord,
                   let envelope = Self.envelope(from: server) {
                    await buffers.appendIncoming([envelope])
                }
                resolvedFailures.append(failure.record.recordID)
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
            }
            for (recordID, error) in changes.failedRecordDeletes where error.code == .serverRecordChanged {
                if let server = error.serverRecord,
                   let envelope = Self.envelope(from: server) {
                    await buffers.appendIncoming([envelope])
                }
                resolvedFailures.append(recordID)
                syncEngine.state.remove(pendingRecordZoneChanges: [.deleteRecord(recordID)])
            }
            await buffers.remove(resolvedFailures)
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
        if let asset = envelope.asset {
            record["assetHash"] = asset.hash as CKRecordValue
            record["assetByteSize"] = asset.byteSize as CKRecordValue
            record["assetSignature"] = asset.signature as CKRecordValue
            record["assetExtension"] = asset.fileExtension as CKRecordValue
            record["assetContentType"] = asset.contentType as CKRecordValue
            if let fileURL = envelope.stagedFileURL {
                record["asset"] = CKAsset(fileURL: fileURL)
            }
        }
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
        let asset: SyncAssetDescriptor?
        if let hash = record["assetHash"] as? String,
           let byteSize = record["assetByteSize"] as? Int64,
           let signature = record["assetSignature"] as? String,
           let fileExtension = record["assetExtension"] as? String,
           let contentType = record["assetContentType"] as? String {
            asset = SyncAssetDescriptor(
                hash: hash,
                byteSize: byteSize,
                signature: signature,
                fileExtension: fileExtension,
                contentType: contentType
            )
        } else {
            asset = nil
        }
        return SyncRecordEnvelope(
            id: resourceID,
            resourceKind: resourceKind,
            revision: revision,
            deviceID: deviceID,
            order: order,
            isTombstone: false,
            payload: payload,
            asset: asset,
            stagedFileURL: (record["asset"] as? CKAsset)?.fileURL
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
