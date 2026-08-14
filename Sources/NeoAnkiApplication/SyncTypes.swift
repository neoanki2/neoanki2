import Foundation
import NeoAnkiCore

public enum SyncStatus: Sendable, Equatable {
    case offline
    case syncing
    case current(lastSync: Date?)
    case accountUnavailable
    case needsAttention(issueCount: Int)
}

public enum SyncIssueKind: String, Codable, Sendable {
    case itemConflict
    case deckConflict
    case itemTypeConflict
    case deleteVersusEdit
    case invalidRemoteChange
    case mediaFailure
}

public struct SyncIssue: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: SyncIssueKind
    public let resourceID: String
    public let summary: String
    public let createdAt: Date
    public let conflictCopy: SyncConflictCopy?

    public init(
        id: UUID = UUID(),
        kind: SyncIssueKind,
        resourceID: String,
        summary: String,
        createdAt: Date = .now,
        conflictCopy: SyncConflictCopy? = nil
    ) {
        self.id = id
        self.kind = kind
        self.resourceID = resourceID
        self.summary = summary
        self.createdAt = createdAt
        self.conflictCopy = conflictCopy
    }
}

public struct SyncConflictCopy: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let resourceKind: String
    public let originalResourceID: String
    public let sourceDeviceID: String
    public let payload: Data
    public let preservedAt: Date
    public let wasTombstone: Bool
    public let acceptedWasTombstone: Bool

    public var isRestorable: Bool { !wasTombstone && !payload.isEmpty }

    public init(
        id: UUID = UUID(),
        resourceKind: String,
        originalResourceID: String,
        sourceDeviceID: String,
        payload: Data,
        preservedAt: Date = .now,
        wasTombstone: Bool = false,
        acceptedWasTombstone: Bool = false
    ) {
        self.id = id
        self.resourceKind = resourceKind
        self.originalResourceID = originalResourceID
        self.sourceDeviceID = sourceDeviceID
        self.payload = payload
        self.preservedAt = preservedAt
        self.wasTombstone = wasTombstone
        self.acceptedWasTombstone = acceptedWasTombstone
    }

    private enum CodingKeys: String, CodingKey {
        case id, resourceKind, originalResourceID, sourceDeviceID, payload,
             preservedAt, wasTombstone, acceptedWasTombstone
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        resourceKind = try container.decode(String.self, forKey: .resourceKind)
        originalResourceID = try container.decode(String.self, forKey: .originalResourceID)
        sourceDeviceID = try container.decode(String.self, forKey: .sourceDeviceID)
        payload = try container.decode(Data.self, forKey: .payload)
        preservedAt = try container.decode(Date.self, forKey: .preservedAt)
        wasTombstone = try container.decodeIfPresent(Bool.self, forKey: .wasTombstone) ?? false
        acceptedWasTombstone = try container.decodeIfPresent(Bool.self, forKey: .acceptedWasTombstone) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(resourceKind, forKey: .resourceKind)
        try container.encode(originalResourceID, forKey: .originalResourceID)
        try container.encode(sourceDeviceID, forKey: .sourceDeviceID)
        try container.encode(payload, forKey: .payload)
        try container.encode(preservedAt, forKey: .preservedAt)
        try container.encode(wasTombstone, forKey: .wasTombstone)
        try container.encode(acceptedWasTombstone, forKey: .acceptedWasTombstone)
    }
}

public struct SyncRecordEnvelope: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let resourceKind: String
    public let revision: Int
    public let deviceID: String
    public let order: Int64
    public let isTombstone: Bool
    public let payload: Data
    public let asset: SyncAssetDescriptor?
    public let stagedFileURL: URL?

    public init(
        id: String,
        resourceKind: String,
        revision: Int,
        deviceID: String,
        order: Int64,
        isTombstone: Bool,
        payload: Data,
        asset: SyncAssetDescriptor? = nil,
        stagedFileURL: URL? = nil
    ) {
        self.id = id
        self.resourceKind = resourceKind
        self.revision = revision
        self.deviceID = deviceID
        self.order = order
        self.isTombstone = isTombstone
        self.payload = payload
        self.asset = asset
        self.stagedFileURL = stagedFileURL
    }
}

public struct SyncAssetDescriptor: Codable, Sendable, Equatable {
    public let hash: String
    public let byteSize: Int64
    public let signature: String
    public let fileExtension: String
    public let contentType: String

    public init(hash: String, byteSize: Int64, signature: String, fileExtension: String, contentType: String) {
        self.hash = hash
        self.byteSize = byteSize
        self.signature = signature
        self.fileExtension = fileExtension
        self.contentType = contentType
    }
}

public protocol CloudSyncTransport: Sendable {
    func start() async throws
    func stop() async
    func enqueue(_ records: [SyncRecordEnvelope]) async throws
    func fetchPendingChanges() async throws -> [SyncRecordEnvelope]
}

/// Converts typed local changes to transport envelopes and applies validated
/// remote batches with an explicit origin for outbound echo suppression.
public protocol LibrarySyncAdapter: Sendable {
    func encode(
        changes: [LibraryChange],
        deviceID: String
    ) async throws -> [SyncRecordEnvelope]
    func applyRemote(
        _ records: [SyncRecordEnvelope],
        origin: LibraryChangeOrigin
    ) async throws
    func initialMerge(
        remote: [SyncRecordEnvelope],
        deviceID: String
    ) async throws -> [SyncRecordEnvelope]
    func preservedConflictCopies() async -> [SyncConflictCopy]
    func restoreConflictCopy(_ copy: SyncConflictCopy) async throws
}

public extension LibrarySyncAdapter {
    func preservedConflictCopies() async -> [SyncConflictCopy] { [] }
    func restoreConflictCopy(_ copy: SyncConflictCopy) async throws {
        throw UserFacingError(title: "Conflict Can’t Be Restored", message: "This library adapter cannot restore that resource type.")
    }
}

public protocol SyncService: Sendable {
    func start() async
    func synchronize() async
    func stop() async
    func status() async -> SyncStatus
    func issues() async -> [SyncIssue]
    func retryIssue(id: UUID) async
    func dismissIssue(id: UUID) async
    func restoreConflictCopy(forIssueID id: UUID) async throws
}

public extension SyncService {
    func retryIssue(id: UUID) async { _ = id; await synchronize() }
    func dismissIssue(id: UUID) async { _ = id }
    func restoreConflictCopy(forIssueID id: UUID) async throws {
        _ = id
        throw UserFacingError(title: "Conflict Can’t Be Restored", message: "No restorable copy is available.")
    }
}

public actor DisabledSyncService: SyncService {
    public init() {}
    public func start() async {}
    public func synchronize() async {}
    public func stop() async {}
    public func status() async -> SyncStatus { .offline }
    public func issues() async -> [SyncIssue] { [] }
}
