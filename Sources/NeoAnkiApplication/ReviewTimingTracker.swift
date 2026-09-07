import Foundation
import NeoAnkiCore

/// Monotonic, foreground-only review timing shared by native study surfaces.
/// Wall-clock changes cannot distort it, and inactive app time is excluded.
public struct ReviewTimingTracker: Sendable {
    private var accumulatedMilliseconds = 0.0
    private var startedAt: ContinuousClock.Instant?

    public init() {}

    public mutating func reset() {
        accumulatedMilliseconds = 0
        startedAt = .now
    }

    public mutating func pause() {
        guard let startedAt else { return }
        accumulatedMilliseconds += Self.milliseconds(from: startedAt, to: .now)
        self.startedAt = nil
    }

    public mutating func resume() {
        guard startedAt == nil else { return }
        startedAt = .now
    }

    public func elapsedMilliseconds() -> Int {
        let running = startedAt.map { Self.milliseconds(from: $0, to: .now) } ?? 0
        return ReviewWorkloadTimingPolicy.clamped(
            Int((accumulatedMilliseconds + running).rounded())
        )
    }

    private static func milliseconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> Double {
        let duration = start.duration(to: end)
        return Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1e15
    }
}
