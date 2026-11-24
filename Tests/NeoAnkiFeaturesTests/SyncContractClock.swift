import Foundation
import NeoAnkiApplication
@testable import NeoAnkiCloudSync

struct SyncContractFailure: Error, CustomStringConvertible {
    let marker: String
    let detail: String
    var description: String { "\(marker): \(detail)" }
}

/// A wall-clock watchdog diagnoses a stalled test, never decides sync latency.
/// All debounce/poll deadlines are asserted against SyncContractClock instead.
func syncContractWatch<T: Sendable>(
    _ marker: String, operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(15))
            throw SyncContractFailure(marker: marker, detail: "No observable progress before deadlock watchdog")
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// The lock protects synchronous `now`, registration, cancellation and advances.
/// Continuations are always resumed outside it. Registration events let a test
/// advance an exact timer instead of hoping detached tasks have been scheduled.
final class SyncContractClock: @unchecked Sendable {
    struct Request: Sendable {
        let id: UUID
        let number: Int
        let deviceID: String
        let duration: Duration
        let deadline: Duration
        let reason: SyncTiming.Reason
    }
    private struct Sleeper {
        let request: Request
        let continuation: CheckedContinuation<Void, any Error>
    }
    let events = SyncLibraryChanges()
    private let lock = NSLock()
    private let origin: Date
    private var offset: Duration = .zero
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelled: Set<UUID> = []
    private var registrations: [Request] = []
    private var completions: [String: Int] = [:]

    init(origin: Date) { self.origin = origin }

    func timing(for deviceID: String) -> SyncTiming {
        SyncTiming(now: { self.now() }, sleep: { duration, reason in
            try await self.sleep(duration, reason: reason, deviceID: deviceID)
        }, didFinishSynchronization: { self.finished(deviceID) })
    }

    private func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        let parts = offset.components
        return origin.addingTimeInterval(Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
    }
    func elapsed() -> Duration {
        lock.lock(); defer { lock.unlock() }; return offset
    }
    func completed(_ deviceID: String) -> Int {
        lock.lock(); defer { lock.unlock() }; return completions[deviceID, default: 0]
    }
    private func finished(_ deviceID: String) {
        lock.lock(); completions[deviceID, default: 0] += 1; lock.unlock()
        signal()
    }
    private func signal() { Task { await events.publish() } }

    private func sleep(_ duration: Duration, reason: SyncTiming.Reason, deviceID: String) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if cancelled.remove(id) != nil || Task.isCancelled {
                    lock.unlock(); continuation.resume(throwing: CancellationError()); return
                }
                let request = Request(id: id, number: registrations.count, deviceID: deviceID,
                    duration: duration, deadline: offset + duration, reason: reason)
                registrations.append(request)
                if duration <= .zero {
                    lock.unlock(); continuation.resume(); signal(); return
                }
                sleepers[id] = Sleeper(request: request, continuation: continuation)
                lock.unlock(); signal()
            }
        } onCancel: { self.cancel(id) }
    }
    private func cancel(_ id: UUID) {
        lock.lock()
        let sleeper = sleepers.removeValue(forKey: id)
        if sleeper == nil { cancelled.insert(id) }
        lock.unlock()
        sleeper?.continuation.resume(throwing: CancellationError())
        signal()
    }
    func advance(by duration: Duration) {
        precondition(duration >= .zero)
        lock.lock(); offset += duration
        let ready = sleepers.values.filter { $0.request.deadline <= offset }
        for sleeper in ready { sleepers.removeValue(forKey: sleeper.request.id) }
        lock.unlock()
        for sleeper in ready { sleeper.continuation.resume() }
        signal()
    }
    func advance(to deadline: Duration) { advance(by: max(.zero, deadline - elapsed())) }
    private func pending(_ deviceID: String, reason: SyncTiming.Reason?) -> [Request] {
        lock.lock(); defer { lock.unlock() }
        return sleepers.values.map(\.request).filter {
            $0.deviceID == deviceID && (reason == nil || $0.reason == reason)
        }.sorted { $0.number < $1.number }
    }
    func localRequest(deviceID: String) async throws -> Request {
        try await syncContractWatch("SYNC_CONTRACT_AUTOMATIC_SEND") {
            let changes = await self.events.stream()
            var iterator = changes.makeAsyncIterator()
            while !Task.isCancelled {
                if let request = self.pending(deviceID, reason: nil).last(where: {
                    if case .localChange = $0.reason { return true }
                    return false
                }) { return request }
                guard await iterator.next() != nil else { break }
            }
            throw CancellationError()
        }
    }
    func pollRequest(deviceID: String) async throws -> Request {
        try await syncContractWatch("SYNC_CONTRACT_POLL_READINESS") {
            let changes = await self.events.stream()
            var iterator = changes.makeAsyncIterator()
            while !Task.isCancelled {
                if let request = self.pending(deviceID, reason: .recoveryPoll).first { return request }
                guard await iterator.next() != nil else { break }
            }
            throw CancellationError()
        }
    }
    func hasPoll(deviceID: String) -> Bool {
        !pending(deviceID, reason: .recoveryPoll).isEmpty
    }
    func waitForCompletion(deviceID: String, after count: Int) async throws {
        try await syncContractWatch("SYNC_CONTRACT_CYCLE_COMPLETION") {
            let changes = await self.events.stream()
            var iterator = changes.makeAsyncIterator()
            while self.completed(deviceID) <= count {
                guard await iterator.next() != nil else { throw CancellationError() }
            }
        }
    }
}
