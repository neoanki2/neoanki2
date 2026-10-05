import CloudKit
import Foundation
import NeoAnkiApplication
#if os(macOS)
import Security
#endif

public enum CKSyncEngineTransportError: Error, Equatable, LocalizedError, Sendable {
    case missingContainerEntitlement(String)
    case unacknowledgedUpload

    public var errorDescription: String? {
        switch self {
        case .unacknowledgedUpload: "The cloud has not acknowledged every pending change. The batch will be retried."
        case let .missingContainerEntitlement(identifier):
            "This build is not provisioned for the iCloud container \(identifier)."
        }
    }
}

actor TransportBuffers {
    var outgoing: [CKRecord.ID: SyncRecordEnvelope] = [:]
    var incoming: [SyncRecordEnvelope] = []
    private var serverRecords: [CKRecord.ID: CKRecord] = [:]
    private var absentRecords: Set<CKRecord.ID> = []
    private var hasCompleteSnapshot = false
    private var deliveryFailure: (any Error)?

    func remember(_ records: [CKRecord]) {
        for record in records {
            serverRecords[record.recordID] = record
            absentRecords.remove(record.recordID)
        }
    }

    func serverRecord(for id: CKRecord.ID) -> CKRecord? {
        serverRecords[id]?.copy() as? CKRecord
    }

    func forget(_ ids: [CKRecord.ID]) {
        for id in ids {
            serverRecords.removeValue(forKey: id)
            absentRecords.insert(id)
        }
    }

    func isAbsent(_ id: CKRecord.ID) -> Bool {
        absentRecords.contains(id) || (hasCompleteSnapshot && serverRecords[id] == nil)
    }
    func completedInitialFetch() { hasCompleteSnapshot = true }

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

    func hasPending(_ ids: [CKRecord.ID]) -> Bool { ids.contains { outgoing[$0] != nil } }
    func failDelivery(_ error: any Error) { deliveryFailure = error }
    func hasDeliveryFailure() -> Bool { deliveryFailure != nil }
    func takeDeliveryFailure() -> (any Error)? {
        defer { deliveryFailure = nil }
        return deliveryFailure
    }

    func acknowledge(_ records: [CKRecord], deleted: [CKRecord.ID]) {
        for record in records {
            guard let pending = outgoing[record.recordID], CKSyncEngineTransport.matchesServer(pending, record: record) else { continue }
            remove([record.recordID])
        }
        for id in deleted where outgoing[id]?.isTombstone == true { remove([id]) }
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
        // Await zone creation itself: the engine can coalesce a manual send
        // with its automatic send, otherwise the first fetch races creation.
        _ = try await CKContainer(identifier: Self.containerIdentifier)
            .privateCloudDatabase.save(zone)
        try await engine.fetchChanges(.init(scope: .zoneIDs([zoneID])))
        if initialState == nil { await buffers.completedInitialFetch() }
    }

    public func stop() async {
        await engine.cancelOperations()
    }

    public func enqueue(_ records: [SyncRecordEnvelope]) async throws {
        // A serialized engine token does not contain CKRecord system fields.
        // Fetch uncached records after restart so ordinary edits can update
        // existing records with their change tags rather than inserting again.
        var missing: [CKRecord.ID] = []
        for envelope in records {
            let id = recordID(for: envelope)
            if await buffers.serverRecord(for: id) == nil, !(await buffers.isAbsent(id)) { missing.append(id) }
        }
        let database = CKContainer(identifier: Self.containerIdentifier).privateCloudDatabase
        for offset in stride(from: 0, to: missing.count, by: 200) {
            let batch = Array(missing[offset..<min(offset + 200, missing.count)])
            let results = try await database.records(for: batch)
            for (id, result) in results {
                switch result {
                case let .success(record): await buffers.remember([record])
                case let .failure(error):
                    if (error as? CKError)?.code != .unknownItem { throw error }
                    await buffers.forget([id])
                }
            }
        }
        let baseline = try await metadataStore.load().serverBaseline ?? [:]
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        for envelope in records {
            let id = recordID(for: envelope)
            let server = await buffers.serverRecord(for: id).flatMap { Self.envelope(from: $0) }
            if let prior = baseline["\(envelope.resourceKind):\(envelope.id)"],
               let conflict = Self.conflictingVersion(local: envelope, baseline: prior,
                    server: server, knownAbsent: await buffers.isAbsent(id)) {
                if !SyncMetadataStore.sameContent(prior, envelope) {
                    try await metadataStore.preserveConflict(local: envelope, server: conflict)
                }
                try await metadataStore.receive([conflict])
                await buffers.appendIncoming([conflict])
                engine.state.remove(pendingRecordZoneChanges: [.saveRecord(id), .deleteRecord(id)])
                await buffers.remove([id])
                continue
            }
            if envelope.isTombstone, await buffers.isAbsent(id) {
                engine.state.remove(pendingRecordZoneChanges: [.deleteRecord(id)])
                await buffers.remove([id])
                continue
            }
            if let server = await buffers.serverRecord(for: id), Self.matchesServer(envelope, record: server) {
                engine.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
                await buffers.remove([id])
                continue
            }
            await buffers.enqueue(envelope, id: id)
            changes.append(envelope.isTombstone ? .deleteRecord(id) : .saveRecord(id))
        }
        guard !changes.isEmpty else { return }
        _ = await buffers.takeDeliveryFailure()
        engine.state.add(pendingRecordZoneChanges: changes)
        do {
            try await engine.sendChanges(.init(scope: .zoneIDs([zoneID])))
        } catch {
            // The delegate stages server-conflict records for the merge. Those
            // resolved conflicts must not abort before incoming is consumed.
            guard Self.containsOnlyServerConflicts(error) else { throw error }
        }
        if let error = await buffers.takeDeliveryFailure() { throw error }
        let ids = records.map { recordID(for: $0) }
        if await buffers.hasPending(ids) { throw CKSyncEngineTransportError.unacknowledgedUpload }
    }

    public func fetchPendingChanges() async throws -> [SyncRecordEnvelope] {
        try await engine.fetchChanges(.init(scope: .zoneIDs([zoneID])))
        if let error = await buffers.takeDeliveryFailure() { throw error }
        return await buffers.drainIncoming()
    }

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case let .stateUpdate(update):
            guard !(await buffers.hasDeliveryFailure()) else { return }
            do {
                try await metadataStore.saveEngineState(update.stateSerialization)
            } catch {
                // A later state event retries persistence. Domain data remains
                // untouched and the engine can refetch from its server token.
            }
        case let .fetchedRecordZoneChanges(changes):
            await buffers.remember(changes.modifications.map(\.record))
            await buffers.forget(changes.deletions.map(\.recordID))
            let received = changes.modifications.map { Self.receivedEnvelope(from: $0.record) }
                + changes.deletions.compactMap { Self.tombstone(from: $0.recordID) }
            do { try await metadataStore.receive(received) }
            catch { await buffers.failDelivery(error) }
            await buffers.appendIncoming(received)
        case let .sentRecordZoneChanges(changes):
            await buffers.remember(changes.savedRecords)
            await buffers.forget(changes.deletedRecordIDs)
            do {
                let acknowledged = changes.savedRecords.compactMap { Self.envelope(from: $0) }
                    + changes.deletedRecordIDs.compactMap { Self.tombstone(from: $0) }
                try await metadataStore.acknowledge(acknowledged)
            } catch { await buffers.failDelivery(error) }
            await buffers.acknowledge(changes.savedRecords, deleted: changes.deletedRecordIDs)
            var resolvedFailures: [CKRecord.ID] = []
            for failure in changes.failedRecordSaves where failure.error.code == .serverRecordChanged {
                if let server = failure.error.serverRecord,
                   let envelope = Self.envelope(from: server) {
                    await buffers.remember([server])
                    do {
                        if let local = await buffers.envelope(for: server.recordID) {
                            try await metadataStore.preserveConflict(local: local, server: envelope)
                        }
                        try await metadataStore.receive([envelope])
                    }
                    catch { await buffers.failDelivery(error) }
                    await buffers.appendIncoming([envelope])
                }
                resolvedFailures.append(failure.record.recordID)
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
            }
            for (recordID, error) in changes.failedRecordDeletes where error.code == .serverRecordChanged {
                if let server = error.serverRecord,
                   let envelope = Self.envelope(from: server) {
                    await buffers.remember([server])
                    do {
                        if let local = await buffers.envelope(for: server.recordID) {
                            try await metadataStore.preserveConflict(local: local, server: envelope)
                        }
                        try await metadataStore.receive([envelope])
                    }
                    catch { await buffers.failDelivery(error) }
                    await buffers.appendIncoming([envelope])
                }
                resolvedFailures.append(recordID)
                syncEngine.state.remove(pendingRecordZoneChanges: [.deleteRecord(recordID)])
            }
            await buffers.remove(resolvedFailures)
            if let failure = changes.failedRecordSaves.first(where: { $0.error.code != .serverRecordChanged }) {
                await buffers.failDelivery(failure.error)
            }
            if let failure = changes.failedRecordDeletes.first(where: { $0.value.code != .serverRecordChanged }) {
                await buffers.failDelivery(failure.value)
            }
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
            return Self.record(from: envelope, id: id, serverRecord: await buffers.serverRecord(for: id))
        }
    }

    public func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        .init(scope: .zoneIDs([zoneID]))
    }

    /// Detect cold-start conflicts using the last acknowledged/applied content,
    /// not freshly fetched change tags (which would hide an offline conflict).
    static func conflictingVersion(
        local: SyncRecordEnvelope, baseline: SyncRecordEnvelope,
        server: SyncRecordEnvelope?, knownAbsent: Bool
    ) -> SyncRecordEnvelope? {
        if let server, !SyncMetadataStore.sameContent(server, baseline),
           !SyncMetadataStore.sameContent(server, local) { return server }
        if server == nil, knownAbsent, !baseline.isTombstone, !local.isTombstone {
            return SyncRecordEnvelope(id: local.id, resourceKind: local.resourceKind,
                revision: 0, deviceID: "cloud", order: 0, isTombstone: true, payload: Data())
        }
        return nil
    }

    static func containsOnlyServerConflicts(_ error: any Error) -> Bool {
        guard let error = error as? CKError else { return false }
        if error.code == .serverRecordChanged { return error.serverRecord != nil }
        guard error.code == .partialFailure,
              let failures = error.partialErrorsByItemID, !failures.isEmpty else { return false }
        return failures.values.allSatisfy(containsOnlyServerConflicts)
    }

    static func matchesServer(_ envelope: SyncRecordEnvelope, record: CKRecord) -> Bool {
        guard !envelope.isTombstone, let server = Self.envelope(from: record) else { return false }
        return envelope.id == server.id && envelope.resourceKind == server.resourceKind
            && envelope.payload == server.payload && envelope.asset == server.asset
    }

    static func record(
        from envelope: SyncRecordEnvelope,
        id: CKRecord.ID,
        serverRecord: CKRecord? = nil
    ) -> CKRecord {
        let record = serverRecord ?? CKRecord(recordType: "LibraryResource", recordID: id)
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
        } else {
            for key in ["assetHash", "assetByteSize", "assetSignature", "assetExtension", "assetContentType", "asset"] {
                record[key] = nil
            }
        }
        return record
    }

    static func receivedEnvelope(from record: CKRecord) -> SyncRecordEnvelope {
        if let decoded = envelope(from: record) { return decoded }
        // Preserve malformed records instead of advancing the fetch token past
        // data that compactMap silently discarded. The adapter rejects this
        // sentinel; the durable inbox contains the original archived record.
        return SyncRecordEnvelope(id: record.recordID.recordName,
            resourceKind: "invalidCloudKitRecord", revision: 0, deviceID: "cloud", order: 0,
            isTombstone: false,
            payload: (try? NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)) ?? Data())
    }

    private static func envelope(from record: CKRecord) -> SyncRecordEnvelope? {
        guard record.recordType == "LibraryResource",
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
