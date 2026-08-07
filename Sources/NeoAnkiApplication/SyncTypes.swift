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

    public init(
        id: UUID = UUID(),
        resourceKind: String,
        originalResourceID: String,
        sourceDeviceID: String,
        payload: Data,
        preservedAt: Date = .now
    ) {
        self.id = id
        self.resourceKind = resourceKind
        self.originalResourceID = originalResourceID
        self.sourceDeviceID = sourceDeviceID
        self.payload = payload
        self.preservedAt = preservedAt
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

    public init(
        id: String,
        resourceKind: String,
        revision: Int,
        deviceID: String,
        order: Int64,
        isTombstone: Bool,
        payload: Data
    ) {
        self.id = id
        self.resourceKind = resourceKind
        self.revision = revision
        self.deviceID = deviceID
        self.order = order
        self.isTombstone = isTombstone
        self.payload = payload
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
}

public protocol SyncService: Sendable {
    func start() async
    func synchronize() async
    func stop() async
    func status() async -> SyncStatus
    func issues() async -> [SyncIssue]
}

public actor DisabledSyncService: SyncService {
    public init() {}
    public func start() async {}
    public func synchronize() async {}
    public func stop() async {}
    public func status() async -> SyncStatus { .offline }
    public func issues() async -> [SyncIssue] { [] }
}
