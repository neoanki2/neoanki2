import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import Testing

private final class LearningTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0
    func advance(_ seconds: Double) { lock.lock(); defer { lock.unlock() }; value += seconds }
    func read() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    var clock: LearningTimeClock {
        LearningTimeClock(instant: { self.read() }, date: { Date(timeIntervalSince1970: 1_800_000_000 + self.read()) })
    }
}
private enum LearningTestError: Error { case unavailable }
private actor LearningRecorder: LibraryLearningTime {
    let id = UUID()
    private var saved: [UUID: LearningTimeSegment] = [:]
    private var attempted: [[UUID]] = []
    private var fails = false
    private var suspendNextWrite = false
    private var suspended = false
    private var writeContinuation: CheckedContinuation<Void, Never>?
    private var writeStartedWaiters: [CheckedContinuation<Void, Never>] = []
    func learningTimeLibraryID() async throws -> UUID { id }
    func recordLearningTime(_ segments: [LearningTimeSegment]) async throws {
        attempted.append(segments.map(\.id))
        if suspendNextWrite {
            suspendNextWrite = false; suspended = true
            for waiter in writeStartedWaiters { waiter.resume() }; writeStartedWaiters = []
            await withCheckedContinuation { writeContinuation = $0 }
            suspended = false
        }
        if fails { throw LearningTestError.unavailable }
        for segment in segments { saved[segment.id] = segment }
    }
    func learningTimeSummary(scope: DeckScope, period: LearningTimePeriod, asOf: Date, calendar: Calendar) async throws -> LearningTimeSummary { throw LearningTestError.unavailable }
    func learningTimeSegments(after sequence: Int64, limit: Int) async throws -> [LearningTimeStoredSegment] { [] }
    func learningTimeNotifications() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func recordLearningTimeAliases(_ aliases: [LearningTimeItemAlias]) async throws {}
    func learningTimeItemAliases() async throws -> [LearningTimeItemAlias] { [] }
    func suspendWrite() { suspendNextWrite = true }
    func waitUntilWriteStarted() async {
        if suspended { return }
        await withCheckedContinuation { writeStartedWaiters.append($0) }
    }
    func releaseWrite() { writeContinuation?.resume(); writeContinuation = nil }
    func setFailing(_ value: Bool) { fails = value }
    func segments() -> [LearningTimeSegment] { Array(saved.values) }
    func attempts() -> [[UUID]] { attempted }
    func total() -> Int64 { saved.values.reduce(0) { $0 + $1.durationMilliseconds } }
}

@Suite(.serialized) @MainActor
struct LearningTimeTrackerTests {
    private func fixture() -> (LearningTimeTracker, LearningTestClock, LearningRecorder) {
        let clock = LearningTestClock(), recorder = LearningRecorder()
        let tracker = LearningTimeTracker(library: recorder, clock: clock.clock)
        tracker.setCard(itemID: UUID(), cardID: UUID()); tracker.setVisible(true)
        return (tracker, clock, recorder)
    }

    @Test func inactivityCountsOnlyToCutoffAndInteractionResumes() async {
        let (tracker, clock, recorder) = fixture()
        clock.advance(180); await tracker.tick()
        #expect(tracker.isIdle)
        #expect(await recorder.total() == 120_000)
        clock.advance(60); tracker.interaction(); clock.advance(10)
        await tracker.finish()
        #expect(await recorder.total() == 130_000)
        #expect(tracker.sessionMilliseconds == 130_000)
    }
    @Test func manualPauseRequiresResumeAndExcludesBackgroundEditingAndSaves() async {
        let (tracker, clock, recorder) = fixture()
        clock.advance(10); tracker.togglePause()
        clock.advance(30); tracker.interaction(); clock.advance(30)
        tracker.togglePause(); clock.advance(10)
        tracker.setActive(false); clock.advance(600); tracker.setActive(true)
        tracker.setEditing(true); clock.advance(60); tracker.setEditing(false)
        tracker.setBusy(true); clock.advance(20); tracker.setBusy(false)
        tracker.interaction(); clock.advance(10); await tracker.finish()
        #expect(await recorder.total() == 30_000)
    }
    @Test func mediaAndRecordingSourcesExtendActivityUntilLastSourceStops() async {
        let (tracker, clock, recorder) = fixture(); let first = UUID(), second = UUID()
        tracker.setMediaActivity(sourceID: first, isActive: true)
        tracker.setMediaActivity(sourceID: second, isActive: true)
        clock.advance(180); await tracker.tick()
        tracker.setMediaActivity(sourceID: first, isActive: false)
        clock.advance(180); await tracker.tick()
        tracker.setMediaActivity(sourceID: second, isActive: false)
        clock.advance(180); await tracker.finish()
        #expect(await recorder.total() == 480_000)
    }
    @Test func checkpointsAndCardTransitionsKeepUnfinishedAttempts() async {
        let (tracker, clock, recorder) = fixture()
        clock.advance(15); await tracker.tick()
        #expect(await recorder.total() == 15_000)
        clock.advance(5); tracker.setCard(itemID: UUID(), cardID: UUID())
        clock.advance(7); await tracker.finish()
        #expect(await recorder.total() == 27_000)
        let segments = await recorder.segments()
        #expect(Set(segments.map(\.cardID)).count == 2)
        // A fresh session never reconstructs closed-app time.
        let fresh = LearningTimeTracker(library: recorder, clock: clock.clock)
        #expect(fresh.sessionMilliseconds == 0)
    }
    @Test func retriesKeepStableSegmentIDsAndExposeErrors() async {
        let (tracker, clock, recorder) = fixture()
        await recorder.setFailing(true)
        clock.advance(15); await tracker.tick()
        #expect(tracker.persistenceError != nil)
        #expect(LearningTimeSaveStatus.shared.errorMessage != nil)
        let first = await recorder.attempts().first
        await recorder.setFailing(false); await tracker.flush()
        #expect(tracker.persistenceError == nil)
        #expect(LearningTimeSaveStatus.shared.errorMessage == nil)
        #expect(await recorder.total() == 15_000)
        let last = await recorder.attempts().last
        #expect(first == last)
        await tracker.finish()
    }
    @Test func onlyOneVisibleOwnerCanAccumulate() async {
        let (first, clock, recorder) = fixture()
        clock.advance(10)
        let second = LearningTimeTracker(library: recorder, clock: clock.clock)
        second.setCard(itemID: UUID(), cardID: UUID()); second.setVisible(true)
        second.setVisible(true) // Duplicate lifecycle callback must not reset time.
        clock.advance(20); await first.tick(); await second.finish(); await first.finish()
        #expect(await recorder.total() == 30_000)
        #expect(first.sessionMilliseconds == 10_000)
        #expect(second.sessionMilliseconds == 20_000)
    }
    @Test func finishDrainsSegmentsEmittedDuringAnInFlightCheckpoint() async {
        let (tracker, clock, recorder) = fixture()
        await recorder.suspendWrite()
        clock.advance(15)
        let checkpoint = Task { await tracker.tick() }
        await recorder.waitUntilWriteStarted()
        clock.advance(5); tracker.setCard(itemID: UUID(), cardID: UUID())
        clock.advance(10)
        // Hide synchronously before releasing the blocked write, as the UI does.
        tracker.setVisible(false)
        let finish = Task { await tracker.finish() }
        await recorder.releaseWrite()
        await finish.value; await checkpoint.value
        #expect(await recorder.total() == 30_000)
        #expect(tracker.sessionMilliseconds == 30_000)
    }
    @Test func hiddenAndAbsentCardsNeverCount() async {
        let (tracker, clock, recorder) = fixture()
        tracker.setCard(itemID: nil, cardID: nil); clock.advance(60); await tracker.tick()
        tracker.setCard(itemID: UUID(), cardID: UUID()); clock.advance(10)
        tracker.setVisible(false); clock.advance(600); await tracker.finish()
        #expect(await recorder.total() == 10_000)
    }
}
