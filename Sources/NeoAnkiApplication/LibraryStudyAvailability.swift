import Foundation
import NeoAnkiCore

/// Optional fast projection for study-time device updates. Older repositories
/// can continue supplying their existing full scope summaries.
public protocol LibraryStudyAvailabilityReading: Sendable {
    func studyAvailability(scope: DeckScope, asOf: Date) async throws -> StudyAvailability
}

/// Batched foreground availability; optional for existing repository clients.
public protocol LibraryDueSnapshotReading: Sendable {
    func dueSnapshot(activeScope: DeckScope?, asOf: Date) async throws -> LibraryDueSnapshot
}

extension SQLiteLibraryRepository: LibraryDueSnapshotReading {
    public func dueSnapshot(activeScope: DeckScope?, asOf: Date) async throws -> LibraryDueSnapshot {
        try await store.dueSnapshot(activeScope: activeScope, asOf: asOf)
    }
}

extension SQLiteLibraryRepository: LibraryStudyAvailabilityReading {
    public func studyAvailability(scope: DeckScope, asOf: Date) async throws -> StudyAvailability {
        try await store.studyAvailability(scope: scope, asOf: asOf)
    }
}
