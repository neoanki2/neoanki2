import Foundation
import NeoAnkiCore

public protocol LibraryStatistics: Sendable {
    /// Opaque revision covering evidence, library structure, and scheduling
    /// inputs. Return an empty string when reliable validation is unavailable.
    func statisticsRevision() async throws -> String
    func statisticsSource() async throws -> StatisticsSource
    func statisticsEvents(after cursor: Int64, limit: Int) async throws -> [StatisticsStoredEvent]
    func recordStatisticsEvents(_ events: [StatisticsEvent]) async throws
}

extension LibraryStatistics {
    /// An empty token means revision validation is unavailable; callers must
    /// reload rather than caching a successful read indefinitely.
    public func statisticsRevision() async throws -> String { "" }
}
extension SQLiteLibraryRepository: LibraryStatistics {
    public func statisticsRevision() async throws -> String { try await store.statisticsRevision() }
    public func statisticsSource() async throws -> StatisticsSource { try await store.statisticsSource() }
    public func statisticsEvents(after cursor: Int64, limit: Int) async throws -> [StatisticsStoredEvent] {
        try await store.statisticsEvents(after: cursor, limit: limit)
    }
    public func recordStatisticsEvents(_ events: [StatisticsEvent]) async throws {
        try await store.recordStatisticsEvents(events)
    }
}
