import CloudKit
import Foundation
import NeoAnkiApplication

public struct SyncMetadata: Codable, Sendable {
    public var engineState: CKSyncEngine.State.Serialization?
    public var deviceID: String
    public var outboundCursor: Int64
    public var stagedInbound: [SyncRecordEnvelope]
    public var issues: [SyncIssue]

    public init(
        engineState: CKSyncEngine.State.Serialization? = nil,
        deviceID: String = UUID().uuidString,
        outboundCursor: Int64 = 0,
        stagedInbound: [SyncRecordEnvelope] = [],
        issues: [SyncIssue] = []
    ) {
        self.engineState = engineState
        self.deviceID = deviceID
        self.outboundCursor = outboundCursor
        self.stagedInbound = stagedInbound
        self.issues = issues
    }
}

/// Stores engine state and sync bookkeeping beside, never inside, domain tables.
public actor SyncMetadataStore {
    private let fileURL: URL
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("cloud-sync-metadata.plist", isDirectory: false)
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
}
