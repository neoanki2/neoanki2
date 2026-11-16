import Foundation
import NeoAnkiCore

public protocol LibraryStatistics: Sendable {
    func statisticsRevision() async throws -> String
    func statisticsSource() async throws -> StatisticsSource
    func statisticsEvents(after cursor: Int64, limit: Int) async throws -> [StatisticsStoredEvent]
    func recordStatisticsEvents(_ events: [StatisticsEvent]) async throws
}

extension LibraryStatistics {
    public func statisticsRevision() async throws -> String { UUID().uuidString }
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
