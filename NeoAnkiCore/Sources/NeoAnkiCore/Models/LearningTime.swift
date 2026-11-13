import Foundation

/// Immutable evidence of active study, independent of grades and card lifetime.
public struct LearningTimeSegment: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sessionID: UUID
    public let deviceID: UUID
    public let sourceLibraryID: UUID
    public let itemID: UUID
    public let cardID: UUID
    public let startedAt: Date
    public let endedAt: Date
    public let durationMilliseconds: Int64

    public init(id: UUID = UUID(), sessionID: UUID, deviceID: UUID, sourceLibraryID: UUID,
                itemID: UUID, cardID: UUID, startedAt: Date, endedAt: Date, durationMilliseconds: Int64) {
        self.id = id; self.sessionID = sessionID; self.deviceID = deviceID
        self.sourceLibraryID = sourceLibraryID; self.itemID = itemID; self.cardID = cardID
        self.startedAt = startedAt; self.endedAt = endedAt; self.durationMilliseconds = durationMilliseconds
    }
}

public enum LearningTimePeriod: String, CaseIterable, Codable, Sendable, Identifiable {
    case today, last7Days, last30Days, allTime
    public var id: Self { self }
    public var title: String {
        switch self {
        case .today: "Today"
        case .last7Days: "Last 7 Days"
        case .last30Days: "Last 30 Days"
        case .allTime: "All Time"
        }
    }

    public func range(asOf now: Date, rolloverMinutes: Int, calendar: Calendar) -> DateInterval {
        let key = StudyDay.key(for: now, rolloverMinutes: rolloverMinutes, calendar: calendar)
        let parts = key.split(separator: "-").compactMap { Int($0) }
        let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
        let rollover = min(max(0, rolloverMinutes), 1439)
        let start = calendar.date(bySettingHour: rollover / 60, minute: rollover % 60, second: 0, of: day)!
        let days = self == .last7Days ? 6 : self == .last30Days ? 29 : 0
        let lower = self == .allTime ? Date(timeIntervalSince1970: 0)
            : calendar.date(byAdding: .day, value: -days, to: start)!
        return DateInterval(start: min(lower, now), end: now)
    }
}

public struct LearningTimeDeckTotal: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let parentID: UUID?
    public let directMilliseconds: Int64
    public let totalMilliseconds: Int64
}

public struct LearningTimeSummary: Sendable, Equatable {
    public let range: DateInterval
    public let totalMilliseconds: Int64
    public let directMilliseconds: Int64
    public let descendantMilliseconds: Int64
    public let unassignedMilliseconds: Int64
    public let deletedMilliseconds: Int64
    /// Durable remote activity awaiting an item or explicit deletion tombstone.
    public let pendingMilliseconds: Int64
    public let decks: [LearningTimeDeckTotal]
    public let trackingStartedAt: Date?
}

public struct LearningTimeStoredSegment: Sendable {
    public let sequence: Int64
    public let segment: LearningTimeSegment
}

public struct LearningTimeItemAlias: Codable, Sendable, Equatable, Identifiable {
    public let sourceLibraryID: UUID
    public let originalItemID: UUID
    public let resolvedItemID: UUID
    public var id: String { sourceLibraryID.uuidString + ":" + originalItemID.uuidString }
    public init(sourceLibraryID: UUID, originalItemID: UUID, resolvedItemID: UUID) {
        self.sourceLibraryID = sourceLibraryID; self.originalItemID = originalItemID; self.resolvedItemID = resolvedItemID
    }
}
