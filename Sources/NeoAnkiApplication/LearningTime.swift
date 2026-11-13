import Foundation
import NeoAnkiCore
import Observation

public protocol LibraryLearningTime: Sendable {
    func recordLearningTimeAliases(_ aliases: [LearningTimeItemAlias]) async throws
    func learningTimeItemAliases() async throws -> [LearningTimeItemAlias]
    func learningTimeLibraryID() async throws -> UUID
    func recordLearningTime(_ segments: [LearningTimeSegment]) async throws
    func learningTimeSummary(scope: DeckScope, period: LearningTimePeriod, asOf: Date, calendar: Calendar) async throws -> LearningTimeSummary
    func learningTimeSegments(after sequence: Int64, limit: Int) async throws -> [LearningTimeStoredSegment]
    func learningTimeNotifications() async -> AsyncStream<Void>
}

/// Clock injection keeps timing tests independent of wall time and sleeps.
public struct LearningTimeClock: Sendable {
    public let instant: @Sendable () -> Double
    public let date: @Sendable () -> Date
    public init(instant: @escaping @Sendable () -> Double, date: @escaping @Sendable () -> Date) {
        self.instant = instant; self.date = date
    }
    public static var continuous: Self {
        let origin = ContinuousClock.now
        return Self(instant: {
            let elapsed = origin.duration(to: .now).components
            return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        }, date: { .now })
    }
}

/// Installation-wide status survives dismissal of an individual study session.
@MainActor @Observable
public final class LearningTimeSaveStatus {
    public static let shared = LearningTimeSaveStatus()
    private var pendingSessions: Set<UUID> = []
    private var failures: [UUID: String] = [:]
    public var hasPendingSaves: Bool { !pendingSessions.isEmpty }
    public var errorMessage: String? { failures.values.sorted().first }
    private init() {}
    fileprivate func pending(_ session: UUID) { pendingSessions.insert(session) }
    fileprivate func failed(_ session: UUID, message: String) { failures[session] = message }
    fileprivate func saved(_ session: UUID) { pendingSessions.remove(session); failures[session] = nil }
}

@MainActor @Observable
public final class LearningTimeTracker {
    public static let inactivitySeconds: Double = 120
    public static let checkpointSeconds: Double = 15
    private static var awaitingSave: [UUID: LearningTimeTracker] = [:]
    private static weak var owner: LearningTimeTracker?
    private static let installationID: UUID = {
        let key = "learningTime.installationID"
        if let value = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: value) { return id }
        let id = UUID(); UserDefaults.standard.set(id.uuidString, forKey: key); return id
    }()

    private var recordedMilliseconds: Int64 = 0
    public var sessionMilliseconds: Int64 { recordedMilliseconds + Int64((accumulatedSeconds * 1000).rounded()) }
    public private(set) var isManuallyPaused = false
    public private(set) var isIdle = false
    public private(set) var persistenceError: String?
    public var isPaused: Bool { isManuallyPaused || isIdle }

    private let library: (any LibraryLearningTime)?
    private let clock: LearningTimeClock
    private let deviceID: UUID
    private let sessionID = UUID()
    private var libraryID: UUID?
    private var itemID: UUID?
    private var cardID: UUID?
    private var visible = false
    private var active = true
    private var busy = false
    private var editing = false
    private var mediaSources: Set<UUID> = []
    private var mediaActive = false
    private var lastInstant: Double
    private var lastInteraction: Double
    private var lastCheckpoint: Double
    private var segmentStart: Date
    private var accumulatedSeconds = 0.0
    private var pending: [LearningTimeSegment] = []
    private var unidentified: [(UUID, UUID, Date, Int64)] = []
    private var saveWaiters: [CheckedContinuation<Void, Never>] = []
    private var isSaving = false
    private var timer: Task<Void, Never>?

    public init(library: (any LibraryLearningTime)?, clock: LearningTimeClock = .continuous, deviceID: UUID? = nil) {
        self.library = library; self.clock = clock; self.deviceID = deviceID ?? Self.installationID
        let now = clock.instant(); lastInstant = now; lastInteraction = now; lastCheckpoint = now
        segmentStart = clock.date()
    }

    public func setCard(itemID: UUID?, cardID: UUID?) {
        guard self.itemID != itemID || self.cardID != cardID else { return }
        settle(); emit(); self.itemID = itemID; self.cardID = cardID
        lastInteraction = clock.instant(); isIdle = false; segmentStart = clock.date()
        scheduleFlush()
    }

    public func setVisible(_ value: Bool) {
        guard visible != value || (value && Self.owner !== self) else { return }
        settle(); emit()
        if value {
            Self.owner?.setVisible(false)
            Self.owner = self
            lastInteraction = clock.instant(); isIdle = false
        } else if Self.owner === self { Self.owner = nil }
        visible = value; segmentStart = clock.date(); lastInstant = clock.instant()
        scheduleFlush(); startTimer()
    }

    public func setActive(_ value: Bool) {
        guard active != value else { return }
        transition {
            active = value
            if value { lastInteraction = clock.instant(); isIdle = false }
        }
    }
    public func setBusy(_ value: Bool) {
        guard busy != value else { return }
        transition {
            busy = value
            if !value { lastInteraction = clock.instant(); isIdle = false }
        }
    }
    public func setEditing(_ value: Bool) {
        guard editing != value else { return }
        transition {
            editing = value
            if !value { lastInteraction = clock.instant(); isIdle = false }
        }
    }
    public func setMediaActivity(sourceID: UUID, isActive: Bool) {
        if isActive { mediaSources.insert(sourceID) } else { mediaSources.remove(sourceID) }
        let value = !mediaSources.isEmpty
        guard value != mediaActive else { return }
        setMediaActive(value)
    }
    public func setMediaActive(_ value: Bool) {
        transition { mediaActive = value; lastInteraction = clock.instant(); isIdle = false }
    }
    public func togglePause() {
        transition { isManuallyPaused.toggle(); lastInteraction = clock.instant(); isIdle = false }
    }
    public func interaction() {
        settle()
        if isIdle { emit(); segmentStart = clock.date() }
        lastInteraction = clock.instant(); isIdle = false
    }

    /// Called by a lightweight timer and directly by deterministic tests.
    public func tick() async {
        let wasIdle = isIdle
        settle()
        if clock.instant() - lastCheckpoint >= Self.checkpointSeconds || (!wasIdle && isIdle) {
            emit(); lastCheckpoint = clock.instant(); await flush()
        }
    }
    public func finish() async {
        setVisible(false); emit(); await flush()
    }

    private var eligible: Bool { visible && active && !busy && !editing && !isManuallyPaused && itemID != nil && cardID != nil }
    private func settle() {
        let now = clock.instant()
        defer { lastInstant = now }
        guard eligible else { return }
        let end = mediaActive ? now : min(now, lastInteraction + Self.inactivitySeconds)
        let seconds = max(0, end - lastInstant)
        accumulatedSeconds += seconds
        isIdle = !mediaActive && now >= lastInteraction + Self.inactivitySeconds
    }
    private func transition(_ change: () -> Void) {
        settle(); emit(); change(); lastInstant = clock.instant(); segmentStart = clock.date(); scheduleFlush()
    }
    private func emit() {
        let milliseconds = Int64((accumulatedSeconds * 1000).rounded())
        if milliseconds > 0, let itemID, let cardID {
            recordedMilliseconds += milliseconds
            if library != nil {
                Self.awaitingSave[sessionID] = self
                LearningTimeSaveStatus.shared.pending(sessionID)
            }
            unidentified.append((itemID, cardID, segmentStart, milliseconds))
        }
        accumulatedSeconds = 0; segmentStart = clock.date()
    }
    private func scheduleFlush() {
        startTimer()
        Task { await flush() }
    }
    private func startTimer() {
        guard timer == nil, library != nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
                guard let self else { break }
                await self.tick()
                if !self.visible && self.pending.isEmpty && self.unidentified.isEmpty {
                    self.timer = nil; return
                }
            }
        }
    }
    public static func retryPendingSaves() async {
        for tracker in Array(awaitingSave.values) { await tracker.flush() }
    }

    public func flush() async {
        guard let library else { return }
        if isSaving {
            await withCheckedContinuation { saveWaiters.append($0) }
            return
        }
        guard !unidentified.isEmpty || !pending.isEmpty else { return }
        isSaving = true
        defer {
            isSaving = false
            let waiters = saveWaiters; saveWaiters = []
            for waiter in waiters { waiter.resume() }
        }
        do {
            if libraryID == nil { libraryID = try await library.learningTimeLibraryID() }
            guard let libraryID else { return }
            // A transition may emit more time while an earlier write awaits
            // SQLite. Drain successful writes before releasing finish/background
            // waiters; a failure exits once and retains the original IDs.
            while !pending.isEmpty || !unidentified.isEmpty {
                pending += unidentified.map { item, card, start, duration in
                    LearningTimeSegment(sessionID: sessionID, deviceID: deviceID, sourceLibraryID: libraryID,
                        itemID: item, cardID: card, startedAt: start,
                        endedAt: start.addingTimeInterval(Double(duration) / 1000), durationMilliseconds: duration)
                }
                unidentified = []
                let batch = pending
                try await library.recordLearningTime(batch)
                pending.removeFirst(batch.count)
            }
            persistenceError = nil
            Self.awaitingSave[sessionID] = nil
            LearningTimeSaveStatus.shared.saved(sessionID)
        } catch {
            let message = "Could not save learning time. It will be retried: \(error.localizedDescription)"
            persistenceError = message
            LearningTimeSaveStatus.shared.failed(sessionID, message: message)
        }
    }
}
