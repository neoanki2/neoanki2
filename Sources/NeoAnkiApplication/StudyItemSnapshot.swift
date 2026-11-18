import Foundation
import NeoAnkiCore

/// Additive read capability: native study refreshes need exact persisted card
/// membership, including cards which are not currently due.
public protocol LibraryStudyItemSnapshotReading: Sendable {
    func studyItemSnapshot(id: UUID) async throws -> ItemCardSnapshot?
}

extension SQLiteLibraryRepository: LibraryStudyItemSnapshotReading {
    public func studyItemSnapshot(id: UUID) async throws -> ItemCardSnapshot? {
        try await store.itemCardSnapshot(id: id)
    }
}
