import NeoAnkiApplication
import NeoAnkiCore
import Testing

@Test func reviewTimingUsesMonotonicForegroundTime() async throws {
    var tracker = ReviewTimingTracker()
    tracker.reset()
    try await Task.sleep(for: .milliseconds(20))
    tracker.pause()
    let paused = tracker.elapsedMilliseconds()
    try await Task.sleep(for: .milliseconds(20))
    let stillPaused = tracker.elapsedMilliseconds()

    #expect(paused >= 10)
    #expect(stillPaused - paused < 5)

    tracker.resume()
    try await Task.sleep(for: .milliseconds(20))
    tracker.pause()
    #expect(tracker.elapsedMilliseconds() >= paused + 10)
}

@Test func freshReviewTimingStartsNearZero() {
    var tracker = ReviewTimingTracker()
    tracker.reset()
    #expect(tracker.elapsedMilliseconds() < 100)
}

@Test func reviewWorkloadTimingClampsStorageAndFiltersEvaluationSamples() {
    #expect(ReviewWorkloadTimingPolicy.clamped(-1) == 0)
    #expect(ReviewWorkloadTimingPolicy.clamped(2_000_000) == 1_800_000)
    #expect(!ReviewWorkloadTimingPolicy.isUsable(249))
    #expect(ReviewWorkloadTimingPolicy.isUsable(250))
    #expect(ReviewWorkloadTimingPolicy.isUsable(600_000))
    #expect(!ReviewWorkloadTimingPolicy.isUsable(600_001))
}
