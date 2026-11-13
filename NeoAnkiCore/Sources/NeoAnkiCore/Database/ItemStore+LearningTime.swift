import Foundation

public extension ItemStore {
    func recordLearningTimeAliases(_ aliases: [LearningTimeItemAlias]) async throws { try await database.recordLearningTimeAliases(aliases) }
    func learningTimeItemAliases() async throws -> [LearningTimeItemAlias] { try await database.learningTimeItemAliases() }
    func recordLearningTime(_ segments: [LearningTimeSegment]) async throws {
        try await database.insertLearningTime(segments)
    }
    func learningTimeSegments(after sequence: Int64, limit: Int = 500) async throws -> [LearningTimeStoredSegment] {
        guard sequence >= 0, (1...1000).contains(limit) else { throw DatabaseError.queryFailed("Invalid learning-time cursor.") }
        return try await database.learningTimeSegments(after: sequence, limit: limit)
    }
    func learningTimeNotifications() async -> AsyncStream<Void> { await database.learningTimeNotifications() }
    func learningTimeSummary(scope: DeckScope, period: LearningTimePeriod, asOf: Date,
                             calendar: Calendar = .autoupdatingCurrent) async throws -> LearningTimeSummary {
        let range = period.range(asOf: asOf, rolloverMinutes: try await studyDayRolloverMinutes(), calendar: calendar)
        return try await database.learningTimeSummary(scope: scope, range: range)
    }
}
