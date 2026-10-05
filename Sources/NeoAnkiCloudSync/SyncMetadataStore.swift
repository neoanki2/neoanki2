import CloudKit
import Foundation
import NeoAnkiApplication

public struct SyncMetadata: Codable, Sendable {
    public var engineState: CKSyncEngine.State.Serialization?
    public var deviceID: String
    public var outboundCursor: Int64
    public var stagedInbound: [SyncRecordEnvelope]
    public var pendingOutbound: [SyncRecordEnvelope]?
    public var serverBaseline: [String: SyncRecordEnvelope]?
    public var issues: [SyncIssue]
    public var didCreateInitialBackup: Bool?
    public var didCompleteInitialMerge: Bool?

    public init(
        engineState: CKSyncEngine.State.Serialization? = nil,
        deviceID: String = UUID().uuidString,
        outboundCursor: Int64 = 0,
        stagedInbound: [SyncRecordEnvelope] = [],
        pendingOutbound: [SyncRecordEnvelope]? = nil,
        serverBaseline: [String: SyncRecordEnvelope]? = nil,
        issues: [SyncIssue] = [],
        didCreateInitialBackup: Bool? = nil,
        didCompleteInitialMerge: Bool? = nil
    ) {
        self.engineState = engineState
        self.deviceID = deviceID
        self.outboundCursor = outboundCursor
        self.stagedInbound = stagedInbound
        self.pendingOutbound = pendingOutbound
        self.serverBaseline = serverBaseline
        self.issues = issues
        self.didCreateInitialBackup = didCreateInitialBackup
        self.didCompleteInitialMerge = didCompleteInitialMerge
    }
}

/// Stores engine state and sync bookkeeping beside, never inside, domain tables.
public actor SyncMetadataStore {
    private let fileURL: URL
    private let stagedAssetDirectory: URL
    private let outboundAssetDirectory: URL
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("cloud-sync-metadata.plist", isDirectory: false)
        stagedAssetDirectory = directory.appendingPathComponent("inbound-assets", isDirectory: true)
        outboundAssetDirectory = directory.appendingPathComponent("outbound-assets", isDirectory: true)
    }

    public func load() throws -> SyncMetadata {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return SyncMetadata()
        }
        return try decoder.decode(SyncMetadata.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ metadata: SyncMetadata) throws {
        var metadata = metadata
        // CKSyncEngine emits state updates while a service awaits a network
        // operation. Preserve that newer serialization during bookkeeping.
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let current = try load()
            metadata.engineState = current.engineState
            // Only completeIncoming may remove delivered records. A stale
            // service snapshot cannot erase a concurrent transport callback.
            metadata.stagedInbound = current.stagedInbound
            metadata.serverBaseline = current.serverBaseline
        }
        try persist(metadata)
    }

    func saveEngineState(_ state: CKSyncEngine.State.Serialization) throws {
        var metadata = try load()
        metadata.engineState = state
        try persist(metadata)
    }

    /// Commit delivered records before the engine may persist its next fetch
    /// token. On process death, the service can replay this durable inbox.
    func receive(_ records: [SyncRecordEnvelope]) throws {
        guard !records.isEmpty else { return }
        let staged = try stageAssets(in: records)
        var metadata = try load()
        var latest: [String: SyncRecordEnvelope] = [:]
        for record in metadata.stagedInbound + staged {
            latest["\(record.resourceKind):\(record.id)"] = record
        }
        let obsolete = (metadata.stagedInbound + staged).filter { old in
            latest["\(old.resourceKind):\(old.id)"]?.stagedFileURL != old.stagedFileURL
        }
        metadata.stagedInbound = Array(latest.values)
        try persist(metadata)
        removeStagedAssets(in: obsolete)
    }

    func completeIncoming(_ consumed: [SyncRecordEnvelope], metadata: SyncMetadata) throws -> SyncMetadata {
        var committed = metadata
        let current = try load()
        committed.engineState = current.engineState
        committed.stagedInbound = current.stagedInbound.filter { !consumed.contains($0) }
        committed.serverBaseline = current.serverBaseline
        for record in consumed { setBaseline(record, metadata: &committed) }
        try persist(committed)
        removeStagedAssets(in: consumed)
        return committed
    }

    func stageOutbound(_ records: [SyncRecordEnvelope]) throws -> [SyncRecordEnvelope] {
        try stageAssets(in: records, directory: outboundAssetDirectory)
    }

    func acknowledge(_ records: [SyncRecordEnvelope]) throws {
        var metadata = try load()
        for record in records { setBaseline(record, metadata: &metadata) }
        try persist(metadata)
    }

    private func setBaseline(_ record: SyncRecordEnvelope, metadata: inout SyncMetadata) {
        if metadata.serverBaseline == nil { metadata.serverBaseline = [:] }
        metadata.serverBaseline?["\(record.resourceKind):\(record.id)"] = SyncRecordEnvelope(
            id: record.id, resourceKind: record.resourceKind, revision: record.revision,
            deviceID: record.deviceID, order: record.order, isTombstone: record.isTombstone,
            payload: record.payload, asset: record.asset
        )
    }

    static func sameContent(_ a: SyncRecordEnvelope, _ b: SyncRecordEnvelope) -> Bool {
        a.id == b.id && a.resourceKind == b.resourceKind && a.payload == b.payload
            && a.asset == b.asset && a.isTombstone == b.isTombstone
    }

    func preserveConflict(local: SyncRecordEnvelope, server: SyncRecordEnvelope) throws {
        guard !Self.sameContent(local, server) else { return }
        var metadata = try load()
        // Retries/restarts preserve one copy of each losing version.
        guard !metadata.issues.contains(where: {
            $0.conflictCopy?.originalResourceID == local.id
                && $0.conflictCopy?.resourceKind == local.resourceKind
                && $0.conflictCopy?.payload == local.payload
                && $0.conflictCopy?.wasTombstone == local.isTombstone
        }) else { return }
        let kind: SyncIssueKind = local.isTombstone || server.isTombstone ? .deleteVersusEdit
            : local.resourceKind == "deck" ? .deckConflict
            : local.resourceKind == "itemType" ? .itemTypeConflict : .itemConflict
        let copy = SyncConflictCopy(resourceKind: local.resourceKind, originalResourceID: local.id,
            sourceDeviceID: local.deviceID, payload: local.payload,
            wasTombstone: local.isTombstone, acceptedWasTombstone: server.isTombstone)
        metadata.issues.append(SyncIssue(kind: kind, resourceID: local.id,
            summary: "A change from another device was accepted. Your prior version is preserved.", conflictCopy: copy))
        try persist(metadata)
    }

    private func persist(_ metadata: SyncMetadata) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(metadata)
        try data.write(to: fileURL, options: .atomic)
    }

    public func stageAssets(in records: [SyncRecordEnvelope]) throws -> [SyncRecordEnvelope] {
        try stageAssets(in: records, directory: stagedAssetDirectory)
    }

    private func stageAssets(in records: [SyncRecordEnvelope], directory: URL) throws -> [SyncRecordEnvelope] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var created: [URL] = []
        do { return try records.map { record in
            guard let source = record.stagedFileURL, let asset = record.asset else { return record }
            // Remote hash/extension strings are untrusted path components.
            // Validation happens in the adapter; staging uses an opaque name.
            let destination = directory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: source, to: destination)
            created.append(destination)
            return SyncRecordEnvelope(
                id: record.id,
                resourceKind: record.resourceKind,
                revision: record.revision,
                deviceID: record.deviceID,
                order: record.order,
                isTombstone: record.isTombstone,
                payload: record.payload,
                asset: asset,
                stagedFileURL: destination
            )
        } } catch {
            for url in created { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    public func removeStagedAssets(in records: [SyncRecordEnvelope]) {
        let roots = [stagedAssetDirectory, outboundAssetDirectory].map { $0.standardizedFileURL.path + "/" }
        for record in records {
            guard let url = record.stagedFileURL,
                  roots.contains(where: { url.standardizedFileURL.path.hasPrefix($0) })
            else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
