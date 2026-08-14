import CloudKit
import Foundation
import NeoAnkiApplication

public struct SyncMetadata: Codable, Sendable {
    public var engineState: CKSyncEngine.State.Serialization?
    public var deviceID: String
    public var outboundCursor: Int64
    public var stagedInbound: [SyncRecordEnvelope]
    public var issues: [SyncIssue]
    public var didCreateInitialBackup: Bool?
    public var didCompleteInitialMerge: Bool?

    public init(
        engineState: CKSyncEngine.State.Serialization? = nil,
        deviceID: String = UUID().uuidString,
        outboundCursor: Int64 = 0,
        stagedInbound: [SyncRecordEnvelope] = [],
        issues: [SyncIssue] = [],
        didCreateInitialBackup: Bool? = nil,
        didCompleteInitialMerge: Bool? = nil
    ) {
        self.engineState = engineState
        self.deviceID = deviceID
        self.outboundCursor = outboundCursor
        self.stagedInbound = stagedInbound
        self.issues = issues
        self.didCreateInitialBackup = didCreateInitialBackup
        self.didCompleteInitialMerge = didCompleteInitialMerge
    }
}

/// Stores engine state and sync bookkeeping beside, never inside, domain tables.
public actor SyncMetadataStore {
    private let fileURL: URL
    private let stagedAssetDirectory: URL
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("cloud-sync-metadata.plist", isDirectory: false)
        stagedAssetDirectory = directory.appendingPathComponent("inbound-assets", isDirectory: true)
    }

    public func load() throws -> SyncMetadata {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return SyncMetadata()
        }
        return try decoder.decode(SyncMetadata.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ metadata: SyncMetadata) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(metadata)
        try data.write(to: fileURL, options: .atomic)
    }

    public func stageAssets(in records: [SyncRecordEnvelope]) throws -> [SyncRecordEnvelope] {
        try FileManager.default.createDirectory(at: stagedAssetDirectory, withIntermediateDirectories: true)
        return try records.map { record in
            guard let source = record.stagedFileURL, let asset = record.asset else { return record }
            let destination = stagedAssetDirectory
                .appendingPathComponent("\(asset.hash)-\(UUID().uuidString)")
                .appendingPathExtension(asset.fileExtension)
            try FileManager.default.copyItem(at: source, to: destination)
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
        }
    }

    public func removeStagedAssets(in records: [SyncRecordEnvelope]) {
        let root = stagedAssetDirectory.standardizedFileURL.path + "/"
        for record in records {
            guard let url = record.stagedFileURL,
                  url.standardizedFileURL.path.hasPrefix(root)
            else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
