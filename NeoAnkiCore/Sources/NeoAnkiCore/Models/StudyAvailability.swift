import Foundation

/// Live due information for device services, without content or maturity history.
public struct StudyAvailability: Sendable, Equatable {
    public let dueNow: Int
    public let nextStudyAt: Date?

    public init(dueNow: Int, nextStudyAt: Date?) {
        self.dueNow = dueNow
        self.nextStudyAt = nextStudyAt
    }
}
