import NeoAnkiApplication
import NeoAnkiCore
import Testing

@Test func reviewTimingUsesMonotonicForegroundTime() {
    let origin = ContinuousClock.now
    var tracker = ReviewTimingTracker()
    tracker.reset(at: origin)
    #expect(tracker.elapsedMilliseconds(at: origin.advanced(by: .milliseconds(20))) == 20)
    tracker.pause(at: origin.advanced(by: .milliseconds(20)))
    tracker.pause(at: origin.advanced(by: .milliseconds(40)))
    #expect(tracker.elapsedMilliseconds(at: origin.advanced(by: .milliseconds(1_020))) == 20)

    tracker.resume(at: origin.advanced(by: .milliseconds(1_020)))
    tracker.resume(at: origin.advanced(by: .milliseconds(1_030)))
    #expect(tracker.elapsedMilliseconds(at: origin.advanced(by: .milliseconds(1_040))) == 40)
    tracker.pause(at: origin.advanced(by: .milliseconds(1_040)))
    #expect(tracker.elapsedMilliseconds(at: origin.advanced(by: .seconds(10))) == 40)
}

@Test func freshReviewTimingAndResetStartAtZero() {
    let origin = ContinuousClock.now
    var tracker = ReviewTimingTracker()
    #expect(tracker.elapsedMilliseconds(at: origin) == 0)
    tracker.reset(at: origin)
    #expect(tracker.elapsedMilliseconds(at: origin) == 0)
    tracker.pause(at: origin.advanced(by: .milliseconds(75)))
    #expect(tracker.elapsedMilliseconds(at: origin.advanced(by: .milliseconds(100))) == 75)
    tracker.reset(at: origin.advanced(by: .milliseconds(100)))
    #expect(tracker.elapsedMilliseconds(at: origin.advanced(by: .milliseconds(100))) == 0)
    #expect(tracker.elapsedMilliseconds(at: origin.advanced(by: .milliseconds(125))) == 25)
}

@Test func reviewWorkloadTimingClampsStorageAndFiltersEvaluationSamples() {
    #expect(ReviewWorkloadTimingPolicy.clamped(-1) == 0)
    #expect(ReviewWorkloadTimingPolicy.clamped(2_000_000) == 1_800_000)
    #expect(!ReviewWorkloadTimingPolicy.isUsable(249))
    #expect(ReviewWorkloadTimingPolicy.isUsable(250))
    #expect(ReviewWorkloadTimingPolicy.isUsable(600_000))
    #expect(!ReviewWorkloadTimingPolicy.isUsable(600_001))
}
