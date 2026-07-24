import Foundation

/// Deterministic clock for scheduling and review flow tests.
public struct TestClock: Sendable {
    private var current: Date

    public init(start: Date) {
        current = start
    }

    public func now() -> Date {
        current
    }

    public mutating func advance(by interval: TimeInterval) {
        current = current.addingTimeInterval(interval)
    }

    public mutating func advanceDays(_ days: Double) {
        advance(by: days * 86_400)
    }
}
