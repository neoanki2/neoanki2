import CloudKit
import Foundation
import NeoAnkiApplication
import OSLog
import os
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

protocol IncrementalLibraryTransport: CloudSyncTransport {
    func fetchLibraryChanges(didStagePage: @escaping @Sendable () async throws -> Void) async throws
    func confirmLibraryChanges(_ records: [SyncRecordEnvelope]) async throws -> [SyncRecordEnvelope]
    func fetchMediaAsset(_ record: SyncRecordEnvelope) async throws -> SyncRecordEnvelope?
    func enqueueMedia(_ record: SyncRecordEnvelope) async throws
}

actor TransportBuffers {
    var outgoing: [CKRecord.ID: SyncRecordEnvelope] = [:]
    private var serverRecords: [CKRecord.ID: CKRecord] = [:]
    private var absentRecords: Set<CKRecord.ID> = []
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
        absentRecords.contains(id)
    }

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

    func acceptedOutgoing(_ records: [CKRecord], deleted: [CKRecord.ID]) -> [SyncRecordEnvelope] {
        let saved = records.compactMap { record -> SyncRecordEnvelope? in
            guard let pending = outgoing[record.recordID], CKSyncEngineTransport.confirmsUpload(pending, record: record) else { return nil }
            return pending
        }
        return saved + deleted.compactMap { id in
            guard let pending = outgoing[id], pending.isTombstone else { return nil }
            return pending
        }
    }
    func failDelivery(_ error: any Error) { deliveryFailure = error }
    func hasDeliveryFailure() -> Bool { deliveryFailure != nil }
    func takeDeliveryFailure() -> (any Error)? {
        defer { deliveryFailure = nil }
        return deliveryFailure
    }

    func acknowledge(_ records: [CKRecord], deleted: [CKRecord.ID]) {
        let saved = records.filter { record in
            guard let pending = outgoing[record.recordID] else { return false }
            return CKSyncEngineTransport.confirmsUpload(pending, record: record)
        }
        remove(saved.map(\.recordID) + deleted.filter { outgoing[$0]?.isTombstone == true })
    }

    func discardVersions(_ ids: [CKRecord.ID]) {
        for id in ids { serverRecords[id] = nil }
        absentRecords.subtract(ids)
    }
}

/// Private-database transport for NeoAnki's fixed custom library zone.
/// Local SQLite remains authoritative; this type only moves durable envelopes.
public actor CKSyncEngineTransport: IncrementalLibraryTransport, CKSyncEngineDelegate {
    static let latencyLog = Logger(subsystem: "com.neoanki2.sync", category: "Latency")
    static let libraryMetadataKeys = ["resourceID", "resourceKind", "revision", "deviceID", "order", "payload",
        "assetHash", "assetByteSize", "assetSignature", "assetExtension", "assetContentType"]
    public static let containerIdentifier = "iCloud.com.neoanki2.app"
    public static let zoneName = "NeoAnkiLibrary"
    public static let librarySubscriptionID = "neoanki-library-changes-v1"
    public static let statisticsZoneName = "NeoAnkiStatisticsV1"
    public static let statisticsSubscriptionID = "neoanki-statistics-changes-v1"
    public static let knownWordsZoneName = "NeoAnkiKnownWordsV1"
    public static let knownWordsSubscriptionID = "neoanki-known-words-changes-v1"
    public static let learningTimeZoneName = "NeoAnkiLearningTimeV1"
    public static let learningTimeSubscriptionID = "neoanki-learning-time-changes-v1"

    public static func librarySubscription(zoneID: CKRecordZone.ID, subscriptionID: String = librarySubscriptionID) -> CKRecordZoneSubscription {
        let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: subscriptionID)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        return subscription
    }

    public static func isLibraryNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        notificationScope(userInfo) != nil
    }

    public static func notificationScope(_ userInfo: [AnyHashable: Any]) -> SyncRemoteScope? {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo),
              notification.notificationType == .recordZone,
              notification.containerIdentifier == nil || notification.containerIdentifier == containerIdentifier else { return nil }
        switch notification.subscriptionID {
        case librarySubscriptionID: return .library
        case statisticsSubscriptionID: return .statistics
        case knownWordsSubscriptionID: return .knownWords
        case learningTimeSubscriptionID: return .learningTime
        default: return nil
        }
    }
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

    private let zoneID: CKRecordZone.ID
    private let subscriptionID: String
    private let buffers = TransportBuffers()
    private let metadataStore: SyncMetadataStore
    private var initialState: CKSyncEngine.State.Serialization?
    private var activeContainer: CKContainer?
    private var activeEngine: CKSyncEngine?

    private var container: CKContainer {
        if let activeContainer { return activeContainer }
        let created = CKContainer(identifier: Self.containerIdentifier)
        activeContainer = created
        return created
    }

    private var engine: CKSyncEngine {
        if let activeEngine { return activeEngine }
        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: initialState,
            delegate: self
        )
        // Explicit zone reads drive receiving. Automatic engine fetches rely on
        // notification hints and can deliver an older page after a direct read.
        configuration.automaticallySync = false
        let created = CKSyncEngine(configuration)
        activeEngine = created
        return created
    }

    private init(metadataStore: SyncMetadataStore, initialState: CKSyncEngine.State.Serialization?, zoneName: String) {
        self.metadataStore = metadataStore
        self.initialState = initialState
        zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        subscriptionID = switch zoneName {
        case Self.statisticsZoneName: Self.statisticsSubscriptionID
        case Self.learningTimeZoneName: Self.learningTimeSubscriptionID
        case Self.knownWordsZoneName: Self.knownWordsSubscriptionID
        default: Self.librarySubscriptionID
        }
    }

    public static func make(metadataStore: SyncMetadataStore, zoneName: String = zoneName) async throws -> CKSyncEngineTransport {
        try validateCurrentProcessEntitlements()
        let metadata = try await metadataStore.load()
        return CKSyncEngineTransport(metadataStore: metadataStore, initialState: metadata.engineState, zoneName: zoneName)
    }

    static func validateContainerIdentifiers(_ identifiers: [String]?) throws {
        guard identifiers?.contains(containerIdentifier) == true else {
            throw CKSyncEngineTransportError.missingContainerEntitlement(containerIdentifier)
        }
    }

    static func validateCurrentProcessEntitlements() throws {
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
        initialState = try await metadataStore.load().engineState
        let zone = CKRecordZone(zoneID: zoneID)
        // The first explicit read must wait until the custom zone exists.
        _ = try await container.privateCloudDatabase.save(zone)
        // A zone notification is only a wake-up hint. All data still goes
        // through the explicit, token-based reader and its durable inbox.
        let database = container.privateCloudDatabase
        do {
            _ = try await database.subscription(for: subscriptionID)
        } catch let error as CKError where error.code == .unknownItem {
            _ = try await database.save(Self.librarySubscription(zoneID: zoneID, subscriptionID: subscriptionID))
        }
    }

    public func stop() async {
        let previous = activeEngine
        // An invalidated CloudKit client can keep returning internalError on
        // every operation. Release the engine and its database/container so the
        // next start builds a new client from the durable checkpoint.
        activeEngine = nil
        activeContainer = nil
        await previous?.cancelOperations()
        _ = await buffers.takeDeliveryFailure()
    }

    public func enqueue(_ records: [SyncRecordEnvelope]) async throws {
        // The receiver can advance independently. Fetch current change tags
        // for this batch before deciding whether edits can be sent safely.
        let ids = records.map { Self.recordID(for: $0, in: zoneID) }
        let database = container.privateCloudDatabase
        for offset in stride(from: 0, to: ids.count, by: 200) {
            let batch = Array(ids[offset..<min(offset + 200, ids.count)])
            let results = try await database.records(for: batch, desiredKeys: Self.libraryMetadataKeys)
            for id in batch {
                guard let result = results[id] else { throw CKSyncEngineTransportError.unacknowledgedUpload }
                switch result {
                case let .success(record): await buffers.remember([record])
                case let .failure(error):
                    if (error as? CKError)?.code != .unknownItem { throw error }
                    await buffers.forget([id])
                }
            }
        }
        let (changes, matchedIDs) = try await Self.prepareOutgoing(records, in: zoneID,
            buffers: buffers, metadataStore: metadataStore)
        if !matchedIDs.isEmpty {
            engine.state.remove(pendingRecordZoneChanges: matchedIDs.flatMap { [.saveRecord($0), .deleteRecord($0)] })
            await buffers.remove(matchedIDs)
        }
        guard !changes.isEmpty else { await buffers.discardVersions(ids); return }
        _ = await buffers.takeDeliveryFailure()
        engine.state.add(pendingRecordZoneChanges: changes)
        do {
            let group = CKOperationGroup()
            group.defaultConfiguration.qualityOfService = .userInitiated
            try await engine.sendChanges(.init(scope: .recordIDs(ids), operationGroup: group))
        } catch {
            // The delegate stages server-conflict records for the merge. Those
            // resolved conflicts must not abort before incoming is consumed.
            guard Self.containsOnlyServerConflicts(error) else { throw error }
        }
        if let error = await buffers.takeDeliveryFailure() { throw error }
        if await buffers.hasPending(ids) { throw CKSyncEngineTransportError.unacknowledgedUpload }
        await buffers.discardVersions(ids)
    }

    /// Classify records against the fetched server versions and durably record
    /// conflicts before changes are handed to CKSyncEngine.
    static func prepareOutgoing(
        _ records: [SyncRecordEnvelope], in zoneID: CKRecordZone.ID,
        buffers: TransportBuffers, metadataStore: SyncMetadataStore
    ) async throws -> (pending: [CKSyncEngine.PendingRecordZoneChange], matched: [CKRecord.ID]) {
        let baseline = try await metadataStore.load().serverBaseline ?? [:]
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        var conflicts: [SyncMetadataStore.Conflict] = []
        var matchedIDs: [CKRecord.ID] = []
        for envelope in records {
            let id = recordID(for: envelope, in: zoneID)
            let server = await buffers.serverRecord(for: id).flatMap { Self.envelope(from: $0) }
            if let prior = baseline["\(envelope.resourceKind):\(envelope.id)"],
               let conflict = Self.conflictingVersion(local: envelope, baseline: prior,
                    server: server, knownAbsent: await buffers.isAbsent(id)) {
                let local = SyncMetadataStore.sameContent(prior, envelope) ? nil : envelope
                conflicts.append((local: local, server: conflict))
                matchedIDs.append(id)
                continue
            }
            if envelope.isTombstone, await buffers.isAbsent(id) {
                matchedIDs.append(id)
                continue
            }
            if let server = await buffers.serverRecord(for: id), Self.matchesServer(envelope, record: server) {
                matchedIDs.append(id)
                continue
            }
            await buffers.enqueue(envelope, id: id)
            changes.append(envelope.isTombstone ? .deleteRecord(id) : .saveRecord(id))
        }
        try await metadataStore.receiveConflicts(conflicts)
        return (changes, matchedIDs)
    }

    public func fetchPendingChanges() async throws -> [SyncRecordEnvelope] {
        if let error = await buffers.takeDeliveryFailure() { throw error }
        return try await fetchZoneChanges(desiredKeys: nil)
    }

    func fetchLibraryChanges(didStagePage: @escaping @Sendable () async throws -> Void) async throws {
        _ = try await fetchZoneChanges(desiredKeys: Self.libraryMetadataKeys, didStagePage: didStagePage)
    }

    func confirmLibraryChanges(_ records: [SyncRecordEnvelope]) async throws -> [SyncRecordEnvelope] {
        let database = container.privateCloudDatabase
        var confirmed: [SyncRecordEnvelope] = []
        for offset in stride(from: 0, to: records.count, by: 200) {
            let ids = records[offset..<min(offset + 200, records.count)].map { Self.recordID(for: $0, in: zoneID) }
            let results = try await database.records(for: ids, desiredKeys: Self.libraryMetadataKeys)
            for id in ids {
                guard let result = results[id] else { throw CKSyncEngineTransportError.unacknowledgedUpload }
                switch result {
                case let .success(record): confirmed.append(Self.receivedEnvelope(from: record))
                case let .failure(error):
                    guard (error as? CKError)?.code == .unknownItem, let deleted = Self.tombstone(from: id) else { throw error }
                    confirmed.append(deleted)
                }
            }
        }
        return confirmed
    }

    func fetchMediaAsset(_ record: SyncRecordEnvelope) async throws -> SyncRecordEnvelope? {
        let id = Self.recordID(for: record, in: zoneID)
        let result: CKRecord
        do { result = try await container.privateCloudDatabase.record(for: id) }
        catch let error as CKError where error.code == .unknownItem { return nil }
        let received = Self.receivedEnvelope(from: result)
        guard received.isSameVersion(as: record) else { return nil }
        return received
    }

    /// File uploads use independent CloudKit operations so an in-flight asset
    /// cannot occupy CKSyncEngine's single library send operation.
    func enqueueMedia(_ record: SyncRecordEnvelope) async throws {
        let database = container.privateCloudDatabase
        let id = Self.recordID(for: record, in: zoneID)
        let media = TransportBuffers()
        let found = try await database.records(for: [id], desiredKeys: Self.libraryMetadataKeys)
        guard let result = found[id] else { throw CKSyncEngineTransportError.unacknowledgedUpload }
        switch result {
        case let .success(server): await media.remember([server])
        case let .failure(error):
            guard (error as? CKError)?.code == .unknownItem else { throw error }
            await media.forget([id])
        }
        let (pending, _) = try await Self.prepareOutgoing([record], in: zoneID, buffers: media, metadataStore: metadataStore)
        if !pending.isEmpty {
            let saving = record.isTombstone ? [] : [Self.record(from: record, id: id, serverRecord: await media.serverRecord(for: id))]
            let modifying = try await database.modifyRecords(saving: saving, deleting: record.isTombstone ? [id] : [],
                savePolicy: .ifServerRecordUnchanged, atomically: false)
            do {
                if record.isTombstone {
                    guard let receipt = modifying.deleteResults[id] else { throw CKSyncEngineTransportError.unacknowledgedUpload }
                    try receipt.get()
                    try await metadataStore.acknowledge([record])
                } else {
                    guard let receipt = modifying.saveResults[id] else { throw CKSyncEngineTransportError.unacknowledgedUpload }
                    try await metadataStore.acknowledge([Self.receivedEnvelope(from: receipt.get())])
                }
            } catch let error as CKError where error.code == .serverRecordChanged {
                guard let server = error.serverRecord else { throw error }
                try await metadataStore.preserveConflict(local: record, server: Self.receivedEnvelope(from: server))
            } catch let error as CKError where error.code == .unknownItem && record.isTombstone {
                try await metadataStore.acknowledge([record])
            }
        }
        activeEngine?.state.remove(pendingRecordZoneChanges: [.saveRecord(id), .deleteRecord(id)])
    }

    private func fetchZoneChanges(
        desiredKeys: [CKRecord.FieldKey]?, didStagePage: @escaping @Sendable () async throws -> Void = {}
    ) async throws -> [SyncRecordEnvelope] {
        let database = container.privateCloudDatabase
        let fetcher = LibraryZoneChangeFetcher(metadataStore: metadataStore)
        do {
            return try await fetcher.fetch(persistEmptyFinalPage: false, collectRecords: desiredKeys == nil,
                didStagePage: didStagePage) { [self] data in
                let token = try data.flatMap {
                    try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
                }
                return try await Self.readPage(database: database, zoneID: zoneID, token: token, desiredKeys: desiredKeys)
            }
        } catch let error as CKError where error.code == .changeTokenExpired {
            try await metadataStore.resetLibraryZoneChangeToken()
            // Let the service retry from a full snapshot on its next cycle.
            throw error
        }
    }

    private struct ZonePageResponse {
        var records: [SyncRecordEnvelope] = []
        var error: (any Error)?
        var checkpoint: (CKServerChangeToken, Bool)?
    }

    private static func readPage(database: CKDatabase, zoneID: CKRecordZone.ID,
                                 token: CKServerChangeToken?, desiredKeys: [String]?) async throws -> LibraryZoneChangeFetcher.Page {
        let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        configuration.previousServerChangeToken = token
        configuration.desiredKeys = desiredKeys
        configuration.resultsLimit = 200
        let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zoneID], configurationsByRecordZoneID: [zoneID: configuration])
        operation.fetchAllChanges = false
        operation.configuration.qualityOfService = desiredKeys == nil ? .utility : .userInitiated
        let response = OSAllocatedUnfairLock(initialState: ZonePageResponse())
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                operation.recordWasChangedBlock = { _, result in
                    response.withLock { page in
                        switch result {
                        case let .success(record): page.records.append(receivedEnvelope(from: record))
                        case let .failure(error): page.error = error
                        }
                    }
                }
                operation.recordWithIDWasDeletedBlock = { id, _ in
                    if let deleted = tombstone(from: id) { response.withLock { $0.records.append(deleted) } }
                }
                operation.recordZoneFetchResultBlock = { _, result in
                    response.withLock { page in
                        switch result {
                        case let .success(checkpoint): page.checkpoint = (checkpoint.serverChangeToken, checkpoint.moreComing)
                        case let .failure(error): page.error = error
                        }
                    }
                }
                operation.fetchRecordZoneChangesResultBlock = { result in
                    if case let .failure(error) = result {
                        response.withLock { if $0.error == nil { $0.error = error } }
                    }
                }
                operation.completionBlock = { [weak operation] in
                    continuation.resume(with: Result {
                        if operation?.isCancelled == true { throw CancellationError() }
                        return try response.withLock { page in
                            if let error = page.error { throw error }
                            guard let (token, more) = page.checkpoint else { throw CKError(.serverResponseLost) }
                            let tokenData = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
                            let count = page.records.count
                            latencyLog.info("CloudKit zone page received records=\(count)")
                            return LibraryZoneChangeFetcher.Page(records: page.records, token: tokenData, moreComing: more)
                        }
                    })
                }
                database.add(operation)
            }
        } onCancel: { operation.cancel() }
    }

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard syncEngine === activeEngine else { return }
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
            let received = changes.modifications.map { Self.receivedEnvelope(from: $0.record) }
                + changes.deletions.compactMap { Self.tombstone(from: $0.recordID) }
            do { try await metadataStore.receive(received) }
            catch { await buffers.failDelivery(error) }
        case let .sentRecordZoneChanges(changes):
            Self.latencyLog.info("CloudKit write acknowledged saves=\(changes.savedRecords.count) deletes=\(changes.deletedRecordIDs.count)")
            await buffers.remember(changes.savedRecords)
            await buffers.forget(changes.deletedRecordIDs)
            do {
                let acknowledged = changes.savedRecords.compactMap { Self.envelope(from: $0) }
                    + changes.deletedRecordIDs.compactMap { Self.tombstone(from: $0) }
                let accepted = await buffers.acceptedOutgoing(changes.savedRecords, deleted: changes.deletedRecordIDs)
                try await metadataStore.acknowledge(acknowledged, outgoing: accepted)
            } catch { await buffers.failDelivery(error) }
            await buffers.acknowledge(changes.savedRecords, deleted: changes.deletedRecordIDs)
            let failed = changes.failedRecordSaves.map {
                (id: $0.record.recordID, change: CKSyncEngine.PendingRecordZoneChange.saveRecord($0.record.recordID), error: $0.error)
            } + changes.failedRecordDeletes.map {
                (id: $0.key, change: CKSyncEngine.PendingRecordZoneChange.deleteRecord($0.key), error: $0.value)
            }
            var conflicts: [SyncMetadataStore.Conflict] = []
            var resolvedIDs: [CKRecord.ID] = []
            var resolvedChanges: [CKSyncEngine.PendingRecordZoneChange] = []
            for (id, change, error) in failed {
                guard error.code == .serverRecordChanged, let server = error.serverRecord,
                      let envelope = Self.envelope(from: server) else {
                    await buffers.failDelivery(error)
                    continue
                }
                await buffers.remember([server])
                conflicts.append((local: await buffers.envelope(for: id), server: envelope))
                resolvedIDs.append(id)
                resolvedChanges.append(change)
            }
            if !conflicts.isEmpty {
                do {
                    try await metadataStore.receiveConflicts(conflicts)
                    syncEngine.state.remove(pendingRecordZoneChanges: resolvedChanges)
                    await buffers.remove(resolvedIDs)
                } catch { await buffers.failDelivery(error) }
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

    static func confirmsUpload(_ envelope: SyncRecordEnvelope, record: CKRecord) -> Bool {
        guard let received = Self.envelope(from: record) else { return false }
        return envelope.isSameVersion(as: received)
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

    static func recordID(for envelope: SyncRecordEnvelope, in zoneID: CKRecordZone.ID) -> CKRecord.ID {
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
