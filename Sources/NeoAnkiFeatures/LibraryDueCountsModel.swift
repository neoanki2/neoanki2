import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import Observation

public enum DueCountLoadState: Sendable, Equatable {
    case checking
    case ready
    case failed(String)
}

/// Availability has its own read lane and publication boundary. Full Home
/// snapshots can finish later without replacing these newer scheduling counts.
@MainActor @Observable
public final class LibraryDueCountsModel {
    public private(set) var state: DueCountLoadState = .checking
    public private(set) var snapshot: LibraryDueSnapshot?
    public private(set) var activeScope: DeckScope?
    public private(set) var revision: UInt64 = 0
    @ObservationIgnored var onSnapshot: (@MainActor (LibraryDueSnapshot) -> Void)?
    @ObservationIgnored private let library: any LibraryRepository
    @ObservationIgnored private let reader: (any LibraryDueSnapshotReading)?
    @ObservationIgnored var sleepUntil: @Sendable (Date) async throws -> Void = { date in
        try await Task.sleep(for: .seconds(max(0.001, date.timeIntervalSinceNow)))
    }
    @ObservationIgnored private var worker: LatestAsyncWork<Date>?
    @ObservationIgnored private var boundaryTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var opened = false
    @ObservationIgnored private var foreground = false

    public init(library: any LibraryRepository, reader: (any LibraryDueSnapshotReading)? = nil) {
        self.library = library
        self.reader = reader ?? (library as? any LibraryDueSnapshotReading)
    }
    var isRefreshing: Bool { worker?.isRunning == true }

    deinit {
        boundaryTask?.cancel()
        let worker = worker
        Task { @MainActor in worker?.cancel() }
    }

    func open() async {
        opened = true
        await refresh()
    }

    public func setForeground(_ active: Bool) {
        foreground = active
        boundaryTask?.cancel()
        boundaryTask = nil
        // This happens synchronously with the lifecycle callback, before a
        // restored zero can be presented as a current scheduling result.
        if active { invalidate() }
        else { state = .checking }
    }

    public func selectScope(_ scope: DeckScope?) {
        guard activeScope != scope else { return }
        activeScope = scope
        invalidate()
    }

    public func count(for scope: DeckScope) -> Int? {
        guard state == .ready else { return nil }
        return snapshot?.count(for: scope)
    }

    public func deckCount(_ id: UUID) -> Int? {
        guard state == .ready else { return nil }
        return snapshot?.decks[id] ?? 0
    }

    public func invalidate(asOf now: Date = .now) {
        state = .checking
        generation &+= 1
        boundaryTask?.cancel()
        boundaryTask = nil
        guard opened else { return }
        if worker == nil {
            worker = LatestAsyncWork { [weak self] now in await self?.read(asOf: now) }
        }
        worker?.request(now)
    }

    public func refresh(asOf now: Date = .now) async {
        guard !Task.isCancelled else { return }
        invalidate(asOf: now)
        await waitUntilSettled()
    }

    public func waitUntilSettled() async { await worker?.waitUntilSettled() }

    private func read(asOf now: Date) async {
        let requestedGeneration = generation
        let scope = activeScope
        do {
            let result: LibraryDueSnapshot
            if let reader {
                result = try await reader.dueSnapshot(activeScope: scope, asOf: now)
            } else {
                let home = try await library.coldHomeSnapshot(scope: scope ?? .allDecks, asOf: now)
                result = LibraryDueSnapshot(total: home.allDecksSummary.dueNow,
                    unassigned: home.unassignedSummary.dueNow,
                    decks: Dictionary(uniqueKeysWithValues: home.deckSummaries.map { ($0.id, $0.dueCount) }),
                    activeScope: scope, activeScopeCount: scope == nil ? nil : home.selectedScopeSummary.dueNow,
                    sourceRevision: 0, calculatedAt: now,
                    validUntil: min(home.allDecksSummary.nextStudyAt ?? now.addingTimeInterval(60), now.addingTimeInterval(60)),
                    nextStudyAt: home.allDecksSummary.nextStudyAt)
            }
            try Task.checkCancellation()
            guard requestedGeneration == generation, scope == activeScope else { return }
            if foreground, result.validUntil <= .now {
                invalidate()
                return
            }
            snapshot = result
            state = .ready
            revision &+= 1
            onSnapshot?(result)
            scheduleBoundary(result.validUntil)
        } catch is CancellationError {
            // Shutdown never turns the last successful result into zero.
        } catch {
            guard requestedGeneration == generation else { return }
            state = .failed(error.localizedDescription)
        }
    }

    private func scheduleBoundary(_ date: Date) {
        guard foreground else { return }
        boundaryTask?.cancel()
        let sleep = sleepUntil
        boundaryTask = Task { [weak self] in
            do { try await sleep(date) }
            catch { return }
            guard let self, foreground, !Task.isCancelled else { return }
            invalidate()
        }
    }
}
