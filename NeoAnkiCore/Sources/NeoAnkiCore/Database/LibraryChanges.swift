import Foundation

/// Stable resource names used by persistence, the local API, and sync. Unknown
/// values remain representable by the legacy string properties for API
/// compatibility during schema evolution.
public enum LibraryResourceKind: String, Codable, CaseIterable, Sendable {
    case library
    case deck
    case itemType
    case item
    case card
    case review
    case reviewRevert
    case studyResponse
    case media
    case itemTypeMembership
    case schedulingSettings
    case portableTypeMapping
}

public enum LibraryChangeOrigin: String, Codable, Sendable {
    case local
    case cloud
    case initialMerge
    case localAPI
    case importTransfer
}

/// One durable notification emitted after a library resource mutation.
/// Payloads intentionally identify resources without copying user content;
/// consumers load the current representation after receiving the event.
public struct LibraryChange: Sendable, Equatable, Identifiable {
    public var id: Int64 { cursor }
    public let cursor: Int64
    public let transactionID: UUID
    public let sequence: Int
    public let eventType: String
    public let resourceType: String
    public let resourceID: String
    public let revision: Int
    public let isTombstone: Bool
    public let occurredAt: Date

    public var resourceKind: LibraryResourceKind? {
        LibraryResourceKind(rawValue: resourceType)
    }

    public init(
        cursor: Int64,
        transactionID: UUID,
        sequence: Int,
        eventType: String,
        resourceType: String,
        resourceID: String,
        revision: Int,
        isTombstone: Bool,
        occurredAt: Date
    ) {
        self.cursor = cursor
        self.transactionID = transactionID
        self.sequence = sequence
        self.eventType = eventType
        self.resourceType = resourceType
        self.resourceID = resourceID
        self.revision = revision
        self.isTombstone = isTombstone
        self.occurredAt = occurredAt
    }
}

/// Latest optimistic-concurrency revision for a resource. Tombstones remain so
/// a deleted identifier cannot silently return to an older revision.
public struct LibraryResourceRevision: Sendable, Equatable {
    public let resourceType: String
    public let resourceID: String
    public let revision: Int
    public let updatedAt: Date
    public let isDeleted: Bool

    public init(
        resourceType: String,
        resourceID: String,
        revision: Int,
        updatedAt: Date,
        isDeleted: Bool
    ) {
        self.resourceType = resourceType
        self.resourceID = resourceID
        self.revision = revision
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
    }
}

public extension ItemStore {
    /// The last committed event cursor, or zero for a library with no events.
    func currentChangeCursor() async throws -> Int64 {
        try await database.currentChangeCursor()
    }

    /// The oldest retained event cursor, or nil when the change log is empty.
    func oldestChangeCursor() async throws -> Int64? {
        try await database.oldestChangeCursor()
    }

    /// Returns durable changes strictly after `cursor`, ordered by cursor.
    func libraryChanges(after cursor: Int64 = 0, limit: Int = 1_000) async throws -> [LibraryChange] {
        guard cursor >= 0 else {
            throw DatabaseError.queryFailed("Change cursor cannot be negative.")
        }
        guard (1 ... 1_000).contains(limit) else {
            throw DatabaseError.queryFailed("Change limit must be between 1 and 1000.")
        }
        return try await database.fetchLibraryChanges(after: cursor, limit: limit)
    }

    func resourceRevision(
        resourceType: String,
        resourceID: String
    ) async throws -> LibraryResourceRevision? {
        try await database.fetchResourceRevision(
            resourceType: resourceType,
            resourceID: resourceID
        )
    }

    /// Removes changes only after they are both older than `retentionInterval`
    /// and outside the newest `minimumRetained` events.
    @discardableResult
    func pruneLibraryChanges(
        asOf now: Date = .now,
        retentionInterval: TimeInterval = 30 * 24 * 60 * 60,
        minimumRetained: Int = 100_000
    ) async throws -> Int {
        guard retentionInterval >= 0, minimumRetained >= 1 else {
            throw DatabaseError.queryFailed("Invalid change-retention policy.")
        }
        return try await database.pruneLibraryChanges(
            before: now.addingTimeInterval(-retentionInterval),
            minimumRetained: minimumRetained
        )
    }
}
