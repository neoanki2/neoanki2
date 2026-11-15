import Foundation
import NeoAnkiCore

/// Optional fast projection for study-time device updates. Older repositories
/// can continue supplying their existing full scope summaries.
public protocol LibraryStudyAvailabilityReading: Sendable {
    func studyAvailability(scope: DeckScope, asOf: Date) async throws -> StudyAvailability
}

extension SQLiteLibraryRepository: LibraryStudyAvailabilityReading {
    public func studyAvailability(scope: DeckScope, asOf: Date) async throws -> StudyAvailability {
        try await store.studyAvailability(scope: scope, asOf: asOf)
    }
}
