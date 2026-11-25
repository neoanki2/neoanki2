import CloudKit
import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import Network

/// The scheduler is replaceable inside tests so debounce/recovery contracts can
/// advance virtual time without turning a busy CI runner into a latency failure.
struct SyncTiming: Sendable {
    enum Reason: Sendable, Equatable {
        case localChange(cursor: Int64)
        case recoveryPoll
        case activityPoll
        case retry
    }

    let now: @Sendable () -> Date
    let sleep: @Sendable (Duration, Reason) async throws -> Void
    var didFinishSynchronization: @Sendable () -> Void = {}

    static let continuous = SyncTiming(now: { .now }, sleep: { duration, _ in try await Task.sleep(for: duration) })
}

/// Coordinates a local-authoritative repository and an independent CloudKit
/// transport. Transport failure changes status but never prevents local work.
public actor OfflineFirstSyncService: SyncService {
    private let repository: any LibraryChangePersisting
    private let adapter: any LibrarySyncAdapter
    private let transport: any CloudSyncTransport
    private let metadataStore: SyncMetadataStore
    private let statistics: StatisticsSyncService?
    private let knownWords: VocabularyJudgmentSyncService?
    private let learningTime: LearningTimeSyncService?
    private let backupURL: @Sendable () -> URL
    private let recoveryPollInterval: Duration
    private let timing: SyncTiming
    private let timingUsesSystemNetwork: Bool
    private var currentStatus: SyncStatus = .offline
    private var currentIssues: [SyncIssue] = []
    private enum Work: Hashable, CaseIterable {
        case upload, download, media, statistics, learningTime, knownWords

        var usesLibraryTransport: Bool { self == .upload || self == .download || self == .media }
    }

    private struct Waiter {
        let work: Set<Work>
        let continuation: CheckedContinuation<Void, Never>
    }

    private var workers: [Work: Task<Void, Never>] = [:]
    private var requested: Set<Work> = []
    private var completionWaiters: [UUID: Waiter] = [:]
    private var retryUntil: [Work: Date] = [:]
    private var retryTasks: [Work: Task<Void, Never>] = [:]
    private var retryAttempts: [Work: Int] = [:]
    private var failures: [Work: SyncStatus] = [:]
    private var failedWork: Set<Work> = []
    private var appliedGenerations: [Work: Int] = [:]
    private var automaticSyncTask: Task<Void, Never>?
    private var activityPollTask: Task<Void, Never>?
    private var localChangeMonitor: Task<Void, Never>?
    private var knownWordsMonitor: Task<Void, Never>?
    private var learningTimeMonitor: Task<Void, Never>?
    private var localSyncTask: Task<Void, Never>?
    private var networkMonitor: NWPathMonitor?
    private var networkAvailable: Bool?
    private var foreground = true
    private var isStarted = false
    private let libraryChangeEvents = SyncLibraryChanges()
    private var preparation: Task<Void, any Error>?
    private var localWork: Task<Void, Never>?
    private var transportStarted = false
    private var libraryReady = false
    private var lifecycle = 0

    public init(
        repository: any LibraryChangePersisting,
        adapter: any LibrarySyncAdapter,
        transport: any CloudSyncTransport,
        metadataStore: SyncMetadataStore,
        learningTime: LearningTimeSyncService? = nil,
        statistics: StatisticsSyncService? = nil,
        knownWords: VocabularyJudgmentSyncService? = nil,
        recoveryPollInterval: Duration = .seconds(3),
        backupURL: @escaping @Sendable () -> URL
    ) {
        self.repository = repository
        self.adapter = adapter
        self.transport = transport
        self.metadataStore = metadataStore
        self.learningTime = learningTime
        self.statistics = statistics
        self.knownWords = knownWords
        self.backupURL = backupURL
        self.recoveryPollInterval = recoveryPollInterval
        self.timing = .continuous
        self.timingUsesSystemNetwork = true
    }

    /// Internal scheduling seam; production callers retain the public initializer.
    init(
        repository: any LibraryChangePersisting,
        adapter: any LibrarySyncAdapter,
        transport: any CloudSyncTransport,
        metadataStore: SyncMetadataStore,
        recoveryPollInterval: Duration = .seconds(3),
        timing: SyncTiming,
        backupURL: @escaping @Sendable () -> URL
    ) {
        self.repository = repository
        self.adapter = adapter
        self.transport = transport
        self.metadataStore = metadataStore
        self.learningTime = nil
        self.statistics = nil
        self.knownWords = nil
        self.backupURL = backupURL
        self.recoveryPollInterval = recoveryPollInterval
        self.timing = timing
        self.timingUsesSystemNetwork = false
    }

    public func start() async {
        await startMonitoring()
        guard isStarted else { return }
        request(.upload, .download, .media, .statistics, .learningTime, .knownWords)
        await wait(for: [.upload, .download])
    }

    private func startMonitoring() async {
        let generation = lifecycle
        if !isStarted {
            isStarted = true
            let stream = await repository.changeNotifications()
            guard generation == lifecycle else { return }
            localChangeMonitor = Task { [weak self] in
                for await cursor in stream {
                    guard !Task.isCancelled else { return }
                    await self?.scheduleLocalSync(after: cursor)
                }
            }
            if let knownWords {
                let changes = await knownWords.committedChanges()
                guard generation == lifecycle else { return }
                knownWordsMonitor = Task { [weak self] in
                    for await _ in changes {
                        guard !Task.isCancelled else { return }
                        await self?.request(.knownWords)
                    }
                }
            }
            if let learningTime {
                let changes = await learningTime.committedChanges()
                guard generation == lifecycle else { return }
                learningTimeMonitor = Task { [weak self] in
                    for await _ in changes {
                        guard !Task.isCancelled else { return }
                        await self?.request(.learningTime)
                    }
                }
            }
            if timingUsesSystemNetwork { monitorConnectivity() }
            configureForegroundTimers()
        }
    }

    public func setForeground(_ foreground: Bool) async {
        guard self.foreground != foreground else { return }
        self.foreground = foreground
        configureForegroundTimers()
        if foreground, isStarted { request(.download, .upload, .media, .statistics, .learningTime, .knownWords) }
    }

    public func receiveRemoteChanges(_ scope: SyncRemoteScope) async -> SyncRemoteResult {
        let generation = lifecycle
        await startMonitoring()
        guard generation == lifecycle, isStarted, !Task.isCancelled else { return .noData }
        let work: Work = switch scope {
        case .library: .download
        case .statistics: .statistics
        case .learningTime: .learningTime
        case .knownWords: .knownWords
        }
        let before = appliedGenerations[work, default: 0]
        request(work)
        await wait(for: [work])
        guard generation == lifecycle, !Task.isCancelled else { return .noData }
        if appliedGenerations[work, default: 0] > before { return .changed }
        return failedWork.contains(work) ? .failed : .noData
    }

    public func synchronize() async {
        let core: Set<Work> = [.upload, .download]
        let alreadyRunning = core.contains { workers[$0] != nil }
        request(.upload, .download, .media, .statistics, .learningTime, .knownWords)
        if !alreadyRunning { await wait(for: Set(Work.allCases)) }
    }

    public func synchronizeAndWait() async {
        request(.upload, .download, .media, .statistics, .learningTime, .knownWords)
        await wait(for: Set(Work.allCases))
    }

    private func wait(for work: Set<Work>) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || work.allSatisfy({ workers[$0] == nil }) { continuation.resume() }
                else { completionWaiters[id] = Waiter(work: work, continuation: continuation) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) { completionWaiters.removeValue(forKey: id)?.continuation.resume() }

    private func finishWaiters() {
        let completed = completionWaiters.filter { _, waiter in
            waiter.work.allSatisfy { workers[$0] == nil }
        }
        for id in completed.keys { cancelWaiter(id) }
    }

    private func configureForegroundTimers() {
        automaticSyncTask?.cancel()
        activityPollTask?.cancel()
        automaticSyncTask = nil
        activityPollTask = nil
        guard isStarted, foreground else { return }
        let scheduler = timing
        let interval = recoveryPollInterval
        automaticSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await scheduler.sleep(interval, .recoveryPoll) }
                catch { return }
                guard !Task.isCancelled else { return }
                await self?.pollLibrary()
            }
        }
        if statistics != nil || learningTime != nil || knownWords != nil {
            activityPollTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await scheduler.sleep(.seconds(30), .activityPoll) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    await self?.pollActivity()
                }
            }
        }
    }

    private func pollLibrary() {
        guard foreground, workers[.download] == nil else { return }
        request(.download)
    }

    private func pollActivity() {
        guard foreground else { return }
        request(.statistics, .learningTime, .knownWords)
    }

    private func monitorConnectivity() {
        let monitor = NWPathMonitor()
        networkMonitor = monitor
        let generation = lifecycle
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { await self?.connectivityChanged(available, generation: generation) }
        }
        monitor.start(queue: DispatchQueue(label: "com.neoanki2.sync.network"))
    }

    private func connectivityChanged(_ available: Bool, generation: Int) {
        guard generation == lifecycle else { return }
        let reconnected = networkAvailable == false && available
        networkAvailable = available
        if reconnected, foreground {
            for work in Work.allCases where retryAttempts[work] != nil {
                retryUntil[work] = nil
            }
            request(.download, .upload, .media, .statistics, .learningTime, .knownWords)
        }
    }

    private func request(_ work: Work...) {
        for operation in work {
            if (operation == .statistics && statistics == nil)
                || (operation == .knownWords && knownWords == nil)
                || (operation == .learningTime && learningTime == nil) { continue }
            if operation == .media && !(transport is any IncrementalLibraryTransport) { continue }
            if let deadline = retryUntil[operation], deadline > timing.now() { continue }
            requested.insert(operation)
            guard workers[operation] == nil else { continue }
            let generation = lifecycle
            workers[operation] = Task { [weak self] in await self?.run(operation, generation: generation) }
        }
    }

    private func run(_ work: Work, generation: Int) async {
        while generation == lifecycle && requested.remove(work) != nil {
            if let deadline = retryUntil[work], deadline > timing.now() { break }
            do {
                if work.usesLibraryTransport { try await prepareLibrary(generation: generation) }
                try checkLifecycle(generation)
                switch work {
                case .upload: try await uploadLibrary(generation: generation)
                case .download: try await downloadLibrary(generation: generation)
                case .media: try await transferMedia(generation: generation)
                case .statistics:
                    if try await statistics?.synchronize() == true { appliedGenerations[work, default: 0] += 1 }
                case .knownWords:
                    if try await knownWords?.synchronize() == true { appliedGenerations[work, default: 0] += 1 }
                case .learningTime:
                    if try await learningTime?.synchronize() == true { appliedGenerations[work, default: 0] += 1 }
                }
                try checkLifecycle(generation)
                failures[work] = nil
                failedWork.remove(work)
                retryAttempts[work] = nil
                if retryUntil[work].map({ $0 <= timing.now() }) ?? true {
                    retryUntil[work] = nil
                    retryTasks.removeValue(forKey: work)?.cancel()
                }
                let identifier = failureID(for: work)
                currentIssues = try await metadataStore.updateIssues {
                    $0.removeAll { $0.resourceID == identifier && $0.conflictCopy == nil }
                }
            } catch is CancellationError {
                break
            } catch {
                guard generation == lifecycle else { return }
                await preserveFailure(error, for: work, generation: generation)
                break
            }
        }
        guard generation == lifecycle else { return }
        workers[work] = nil
        refreshStatus()
        finishWaiters()
        if work == .download || work == .upload { timing.didFinishSynchronization() }
    }

    private func refreshStatus() {
        if let failure = failures[.download] ?? failures[.upload] {
            currentStatus = failure
        } else if !currentIssues.isEmpty {
            currentStatus = .needsAttention(issueCount: currentIssues.count)
        } else if workers[.download] != nil || workers[.upload] != nil || workers[.media] != nil {
            currentStatus = .syncing
        } else {
            currentStatus = .current(lastSync: timing.now())
        }
    }

    private func prepareLibrary(generation: Int) async throws {
        guard !libraryReady else { return }
        if let preparation { return try await preparation.value }
        let task = Task { try await self.prepareLibraryOnce(generation: generation) }
        preparation = task
        defer { if generation == lifecycle { preparation = nil } }
        try await task.value
    }

    private func prepareLibraryOnce(generation: Int) async throws {
        if !transportStarted {
            try await transport.start()
            try checkLifecycle(generation)
            transportStarted = true
        }
        var metadata = try await metadataStore.load()
        currentIssues = metadata.issues
        if metadata.didCreateInitialBackup != true {
            let destination = backupURL()
            try await repository.createBackup(at: destination)
            try await repository.verifyBackup(at: destination)
            try checkLifecycle(generation)
            metadata.didCreateInitialBackup = true
            try await metadataStore.save(metadata)
        }
        if metadata.didCompleteInitialMerge != true {
            let incoming = try await transport.fetchPendingChanges()
            try checkLifecycle(generation)
            try await metadataStore.receive(incoming)
            metadata = try await metadataStore.load()
            let recovered = metadata.stagedInbound
            let localCursor = try await repository.currentChangeCursor()
            try await consumeIncoming(recovered, metadata: &metadata)
            try checkLifecycle(generation)
            metadata.outboundCursor = localCursor
            metadata.issues = currentIssues
            _ = try await metadataStore.completeIncoming(recovered, metadata: metadata)
            if !recovered.isEmpty {
                appliedGenerations[.download, default: 0] += 1
                await libraryChangeEvents.publish()
            }
        }
        libraryReady = true
    }

    public func libraryChanges() async -> AsyncStream<Void> { await libraryChangeEvents.stream() }

    public func prioritizeMedia(in scope: DeckScope?) async {
        await (adapter as? any MediaSyncAdapter)?.prioritizeMedia(in: scope)
    }

    private func scheduleLocalSync(after cursor: Int64) {
        guard localSyncTask == nil else { return }
        let generation = lifecycle
        let scheduler = timing
        // Start one bounded window at the first commit. Continuous edits
        // must not keep moving the deadline or cancel a running upload.
        localSyncTask = Task { [weak self] in
            do { try await scheduler.sleep(.milliseconds(250), .localChange(cursor: cursor)) }
            catch { return }
            await self?.localWindowElapsed(generation: generation)
        }
    }

    private func localWindowElapsed(generation: Int) {
        guard generation == lifecycle else { return }
        localSyncTask = nil
        request(.upload, .statistics)
    }

    private func withLocalWork(
        generation: Int, _ action: @Sendable @escaping () async throws -> Void
    ) async throws {
        let previous = localWork
        let next = Task {
            await previous?.value
            try self.checkLifecycle(generation)
            try await action()
        }
        localWork = Task { _ = await next.result }
        try await next.value
    }

    private func stageLocalChanges(generation: Int) async throws {
        let metadata = try await metadataStore.load()
        let highWater = try await repository.currentChangeCursor()
        guard highWater > metadata.outboundCursor else { return }
        var latest: [String: LibraryChange] = [:]
        var cursor = metadata.outboundCursor
        while cursor < highWater {
            try checkLifecycle(generation)
            let page = try await repository.changes(after: cursor, limit: 1_000).prefix { $0.cursor <= highWater }
            guard let last = page.last else { break }
            for change in page { latest["\(change.resourceType):\(change.resourceID)"] = change }
            cursor = last.cursor
        }
        let changes = latest.values.sorted { $0.cursor < $1.cursor }
        if let mediaAdapter = adapter as? any MediaSyncAdapter,
           transport is any IncrementalLibraryTransport {
            let outbound = try await mediaAdapter.encodeForIncrementalSync(changes: changes, deviceID: metadata.deviceID,
                baseline: metadata.serverBaseline ?? [:])
            try checkLifecycle(generation)
            try await metadataStore.appendOutgoing(outbound, cursor: cursor)
        } else {
            let outbound = try await encodeLegacyChanges(changes, metadata: metadata)
            try checkLifecycle(generation)
            try await metadataStore.appendOutgoing(outbound, cursor: cursor)
        }
    }

    private func encodeLegacyChanges(_ changes: [LibraryChange], metadata: SyncMetadata) async throws -> [SyncRecordEnvelope] {
        guard let mediaAdapter = adapter as? any MediaSyncAdapter else {
            return try await adapter.encode(changes: changes, deviceID: metadata.deviceID)
        }
        let staged = Dictionary(metadata.stagedInbound.filter(\.isMedia).map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest })
        var knownMedia: [String: SyncAssetDescriptor] = [:]
        for change in changes where change.resourceKind == .media && !change.isTombstone {
            let record = staged[change.resourceID] ?? metadata.serverBaseline?["media:\(change.resourceID)"]
            if let record, !record.isTombstone { knownMedia[change.resourceID] = record.asset }
        }
        return try await mediaAdapter.encode(changes: changes, deviceID: metadata.deviceID, knownMedia: knownMedia)
    }

    private func uploadLibrary(generation: Int) async throws {
        try await withLocalWork(generation: generation) { try await self.stageLocalChanges(generation: generation) }
        let separatesMedia = transport is any IncrementalLibraryTransport
        let candidates = try await metadataStore.load().pendingOutbound ?? []
        let pending = candidates.filter { !separatesMedia || !$0.isMedia }
        if separatesMedia, candidates.contains(where: \.isMedia) { request(.media) }
        // Keep later versions of a resource queued until its in-flight
        // version has been acknowledged. CKSyncEngine keys writes by ID.
        var sentKeys: Set<String> = []
        var batch: [SyncRecordEnvelope] = []
        for record in pending where sentKeys.insert(record.syncKey).inserted {
            batch.append(record)
            if batch.count == 200 { break }
        }
        guard !batch.isEmpty else { return }
        CKSyncEngineTransport.latencyLog.info("Library upload started records=\(batch.count)")
        if separatesMedia { try await metadataStore.beginUpload(batch) }
        do {
            try await transport.enqueue(batch)
            try checkLifecycle(generation)
            try await metadataStore.finishOutgoing(batch)
        } catch {
            if separatesMedia { await metadataStore.endUpload(batch) }
            throw error
        }
        if separatesMedia { await metadataStore.endUpload(batch) }
        let metadata = try await metadataStore.load()
        if !metadata.stagedInbound.isEmpty { request(.download) }
        if pending.count > batch.count { request(.upload) }
    }

    private func downloadLibrary(generation: Int) async throws {
        let incremental = transport as? any IncrementalLibraryTransport
        await metadataStore.beginZoneRead()
        do {
            if let incremental {
                try await incremental.fetchLibraryChanges { [weak self] in
                    try await self?.processInbox(generation: generation, allowMissingDependencies: true)
                }
            } else {
                let incoming = try await transport.fetchPendingChanges()
                try checkLifecycle(generation)
                try await metadataStore.receive(incoming)
            }
        } catch {
            await metadataStore.endZoneRead()
            throw error
        }
        await metadataStore.endZoneRead()
        try checkLifecycle(generation)
        try await processInbox(generation: generation, allowMissingDependencies: false)
    }

    private func processInbox(generation: Int, allowMissingDependencies: Bool) async throws {
        let metadata = try await metadataStore.load()
        if metadata.stagedInbound.isEmpty && !metadata.issues.contains(where: { $0.conflictCopy != nil }) { return }
        if let incremental = transport as? any IncrementalLibraryTransport {
            let blocked = Set((metadata.pendingOutbound ?? []).map(\.syncKey))
            let confirmation = metadata.stagedInbound.filter {
                !$0.isMedia && !blocked.contains($0.syncKey)
                    && metadata.inboundNeedingConfirmation?.contains($0.syncKey) == true
            }
            if !confirmation.isEmpty {
                let confirmed = try await incremental.confirmLibraryChanges(confirmation)
                try checkLifecycle(generation)
                try await metadataStore.confirmIncoming(confirmation, current: confirmed)
            }
        }
        try await withLocalWork(generation: generation) {
            try await self.applyInbox(generation: generation, allowMissingDependencies: allowMissingDependencies)
        }
    }

    private func applyInbox(generation: Int, allowMissingDependencies: Bool) async throws {
        let incremental = transport as? any IncrementalLibraryTransport
        var metadata = try await metadataStore.load()
        if incremental != nil, metadata.stagedInbound.contains(where: \.isMedia) { request(.media) }
        if metadata.stagedInbound.contains(where: { incremental == nil || !$0.isMedia }) {
            try await stageLocalChanges(generation: generation)
            metadata = try await metadataStore.load()
        }
        let blocked = Set((metadata.pendingOutbound ?? []).map(\.syncKey))
        let incoming = metadata.stagedInbound.filter { record in
            !blocked.contains(record.syncKey) && (incremental == nil || (!record.isMedia
                && metadata.inboundNeedingConfirmation?.contains(record.syncKey) != true))
        }
        if !incoming.isEmpty {
            let baseline = metadata.serverBaseline ?? [:]
            let changes = incoming.filter { record in
                guard let prior = baseline[record.syncKey] else { return true }
                return !SyncMetadataStore.sameContent(prior, record)
            }
            var journalCursor: Int64?
            do {
                if !changes.isEmpty {
                    if let mediaAdapter = adapter as? any MediaSyncAdapter, !changes.contains(where: \.isMedia) {
                        journalCursor = try await mediaAdapter.applyLibraryChanges(changes, expectedCursor: metadata.outboundCursor)
                    } else {
                        try await adapter.applyRemote(changes, origin: .cloud)
                    }
                }
            } catch is SynchronizedSnapshotChanged {
                request(.upload, .download)
                return
            } catch let error as DatabaseError {
                guard isMissingDependency(error) else { throw error }
                // A page may carry a new item before its parent. Its missing
                // dependency must not delay reviews of cards already here.
                if let mediaAdapter = adapter as? any MediaSyncAdapter {
                    let ready = try await mediaAdapter.reviewsWithLocalDependencies(changes)
                    if !ready.isEmpty {
                        do {
                            let cursor = try await mediaAdapter.applyLibraryChanges(ready, expectedCursor: metadata.outboundCursor)
                            try await completeReceived(ready, changed: ready.count, cursor: cursor, generation: generation)
                        } catch is SynchronizedSnapshotChanged {
                            request(.upload, .download)
                            return
                        }
                    }
                }
                if allowMissingDependencies || !blocked.isEmpty { return }
                throw error
            }
            try await completeReceived(incoming, changed: changes.count, cursor: journalCursor, generation: generation)
        }
        try await resolveConflictsAutomatically(generation: generation)
        metadata = try await metadataStore.load()
        currentIssues = metadata.issues
        if incremental != nil, metadata.stagedInbound.contains(where: \.isMedia) { request(.media) }
        if workers[.upload] == nil, !failedWork.contains(.upload),
           (metadata.pendingOutbound ?? []).contains(where: { incremental == nil || !$0.isMedia }) {
            request(.upload)
        }
    }

    private func completeReceived(_ incoming: [SyncRecordEnvelope], changed: Int, cursor: Int64?, generation: Int) async throws {
        try checkLifecycle(generation)
        try await metadataStore.finishApplying(incoming, journalCursor: cursor)
        if changed > 0 {
            appliedGenerations[.download, default: 0] += 1
            await libraryChangeEvents.publish()
            CKSyncEngineTransport.latencyLog.info("Receiver SQLite applied records=\(changed)")
        }
    }

    private func isMissingDependency(_ error: DatabaseError) -> Bool {
        switch error {
        case .deckNotFound, .itemNotFound, .itemTypeNotFound, .cardNotFound, .reviewLogNotFound: true
        case let .executeFailed(message): message.contains("FOREIGN KEY constraint failed")
        default: false
        }
    }

    private func transferMedia(generation: Int) async throws {
        guard let incremental = transport as? any IncrementalLibraryTransport,
              let mediaAdapter = adapter as? any MediaSyncAdapter else { return }
        var metadata = try await metadataStore.load()
        let outgoing = (metadata.pendingOutbound ?? []).filter(\.isMedia)
        if let uploaded = outgoing.first {
            // A newer deletion or replacement makes an older unmaterialized
            // descriptor unnecessary, even after local garbage collection.
            if outgoing.dropFirst().contains(where: { $0.syncKey == uploaded.syncKey }) {
                try await metadataStore.finishOutgoing([uploaded])
            } else {
                let withFile = try await mediaAdapter.materializeUpload(uploaded)
                defer {
                    if uploaded.stagedFileURL == nil, let url = withFile.stagedFileURL {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
                try checkLifecycle(generation)
                try await metadataStore.beginUpload([uploaded])
                do {
                    try await incremental.enqueueMedia(withFile)
                    try checkLifecycle(generation)
                    try await metadataStore.finishOutgoing([uploaded])
                } catch {
                    await metadataStore.endUpload([uploaded])
                    throw error
                }
                await metadataStore.endUpload([uploaded])
            }
            metadata = try await metadataStore.load()
        }
        let locallyQueued = Set((metadata.pendingOutbound ?? []).map(\.syncKey))
        let ready = metadata.stagedInbound.filter { $0.isMedia && !locallyQueued.contains($0.syncKey) }
        if let record = try await mediaAdapter.orderedMedia(ready).first {
            var installed = record
            if !record.isTombstone {
                let baseline = metadata.serverBaseline?[record.syncKey]
                let confirmed = await mediaAdapter.hasLocalMedia(record)
                if !confirmed || baseline.map({ !SyncMetadataStore.sameContent($0, record) }) != false {
                    if record.stagedFileURL == nil {
                        guard let downloaded = try await incremental.fetchMediaAsset(record) else { return }
                        try checkLifecycle(generation)
                        guard let staged = try await metadataStore.stageDownloadedMedia(downloaded, replacing: record) else { return }
                        installed = staged
                    }
                    try checkLifecycle(generation)
                    try await mediaAdapter.applyRemote([installed], origin: .cloud)
                }
            }
            try checkLifecycle(generation)
            try await metadataStore.finishApplying([installed])
        }
        if outgoing.count > 1 || ready.count > 1 { request(.media) }
    }

    private func checkLifecycle(_ generation: Int) throws {
        guard generation == lifecycle, !Task.isCancelled else { throw CancellationError() }
    }

    private func resolveConflictsAutomatically(generation: Int) async throws {
        let snapshot = try await metadataStore.load()
        // Recover dependencies before items that may reference them.
        let priority = ["itemType": 0, "deck": 1, "item": 2]
        let issues = snapshot.issues.sorted {
            (priority[$0.conflictCopy?.resourceKind ?? ""] ?? 3) < (priority[$1.conflictCopy?.resourceKind ?? ""] ?? 3)
        }
        var archiveOnly: [SyncIssue] = []
        let stillStaged = Set(snapshot.stagedInbound.map(\.syncKey))
        for issue in issues {
            guard let copy = issue.conflictCopy else { continue }
            try checkLifecycle(generation)
            guard LibraryResourceKind(rawValue: copy.resourceKind) != nil else { continue }
            if stillStaged.contains("\(copy.resourceKind):\(copy.originalResourceID)") { continue }
            guard copy.isRestorable else {
                archiveOnly.append(issue)
                continue
            }
            // The adapter uses the copy's stable identity. A crash between
            // the domain commit and metadata commit cannot duplicate it.
            try await adapter.restoreConflictCopy(copy)
            try checkLifecycle(generation)
            let latest = try await metadataStore.completeConflicts([issue])
            currentIssues = latest.issues
        }
        if !archiveOnly.isEmpty {
            let latest = try await metadataStore.completeConflicts(archiveOnly)
            currentIssues = latest.issues
        }
    }

    public func stop() async {
        lifecycle += 1
        isStarted = false
        automaticSyncTask?.cancel()
        automaticSyncTask = nil
        activityPollTask?.cancel()
        activityPollTask = nil
        localChangeMonitor?.cancel()
        localChangeMonitor = nil
        knownWordsMonitor?.cancel()
        knownWordsMonitor = nil
        learningTimeMonitor?.cancel()
        learningTimeMonitor = nil
        localSyncTask?.cancel()
        localSyncTask = nil
        networkMonitor?.cancel()
        networkMonitor = nil
        networkAvailable = nil
        preparation?.cancel()
        preparation = nil
        localWork?.cancel()
        localWork = nil
        for worker in workers.values { worker.cancel() }
        for task in retryTasks.values { task.cancel() }
        workers.removeAll()
        retryTasks.removeAll()
        retryUntil.removeAll()
        retryAttempts.removeAll()
        failures.removeAll()
        failedWork.removeAll()
        appliedGenerations.removeAll()
        requested.removeAll()
        finishWaiters()
        transportStarted = false
        libraryReady = false
        currentStatus = .offline
        await transport.stop()
        await knownWords?.stop()
        await learningTime?.stop()
        await statistics?.stop()
    }

    public func status() async -> SyncStatus { currentStatus }
    public func issues() async -> [SyncIssue] { currentIssues }

    public func retryIssue(id: UUID) async {
        await removeIssue(id)
        for work in Work.allCases where retryAttempts[work] != nil { retryUntil[work] = nil }
        await synchronize()
    }

    public func dismissIssue(id: UUID) async {
        await removeIssue(id)
        currentStatus = currentIssues.isEmpty ? .current(lastSync: timing.now()) : .needsAttention(issueCount: currentIssues.count)
    }

    public func restoreConflictCopy(forIssueID id: UUID) async throws {
        guard let issue = currentIssues.first(where: { $0.id == id }), let copy = issue.conflictCopy else {
            throw UserFacingError(title: "Conflict Can’t Be Restored", message: "The preserved copy is no longer available.")
        }
        try await adapter.restoreConflictCopy(copy)
        await removeIssue(id)
        await synchronize()
    }

    private func removeIssue(_ id: UUID) async {
        do {
            currentIssues = try await metadataStore.updateIssues { $0.removeAll { $0.id == id } }
        } catch { currentIssues.removeAll { $0.id == id } }
    }

    private func conflictKind(_ resourceKind: String) -> SyncIssueKind {
        switch resourceKind {
        case LibraryResourceKind.deck.rawValue: .deckConflict
        case LibraryResourceKind.itemType.rawValue: .itemTypeConflict
        default: .itemConflict
        }
    }

    private func conflictKind(_ copy: SyncConflictCopy) -> SyncIssueKind {
        if copy.wasTombstone || copy.acceptedWasTombstone { return .deleteVersusEdit }
        return conflictKind(copy.resourceKind)
    }

    private func consumeIncoming(
        _ records: [SyncRecordEnvelope],
        metadata: inout SyncMetadata
    ) async throws {
        if metadata.didCompleteInitialMerge != true {
            let merged = try await adapter.initialMerge(
                remote: records,
                deviceID: metadata.deviceID
            )
            let copies = await adapter.preservedConflictCopies()
            for copy in copies where !currentIssues.contains(where: { $0.conflictCopy?.id == copy.id }) {
                currentIssues.append(SyncIssue(
                    kind: conflictKind(copy),
                    resourceID: copy.originalResourceID,
                    summary: "A change from another device was accepted. Your prior version is preserved.",
                    conflictCopy: copy
                ))
            }
            metadata.pendingOutbound = (metadata.pendingOutbound ?? []) + (try await metadataStore.stageOutbound(merged))
            metadata.didCompleteInitialMerge = true
        } else {
            try await adapter.applyRemote(records, origin: .cloud)
        }
    }

    private func preserveFailure(_ error: any Error, for work: Work, generation: Int) async {
        failedWork.insert(work)
        let cloud = error as? CKError
        let partial = cloud?.partialErrorsByItemID?.values.compactMap { ($0 as? CKError)?.retryAfterSeconds }.max()
        let serverDelay = max(cloud?.retryAfterSeconds ?? 0, partial ?? 0)
        if serverDelay > 0 {
            let affected = work.usesLibraryTransport ? [Work.upload, .download, .media] : [work]
            for operation in affected {
                retryAttempts[operation] = nil
                scheduleRetry(operation, after: serverDelay, generation: generation)
            }
        } else if isStarted, cloud?.code != .notAuthenticated {
            let attempt = min(retryAttempts[work, default: 0] + 1, 5)
            retryAttempts[work] = attempt
            scheduleRetry(work, after: Double(1 << attempt), generation: generation)
        }
        if cloud?.code == .internalError {
            switch work {
            case .statistics: await statistics?.stop()
            case .knownWords: await knownWords?.stop()
            case .learningTime: await learningTime?.stop()
            default:
                libraryReady = false
                let otherLibraryWork = Work.allCases.filter { $0.usesLibraryTransport && $0 != work }
                requested.subtract(otherLibraryWork + [work])
                for operation in otherLibraryWork { workers[operation]?.cancel() }
                if transportStarted {
                    transportStarted = false
                    await transport.stop()
                }
            }
        }
        guard generation == lifecycle else { return }
        if let status = cloudStatus(for: error) {
            failures[work] = status
            return
        }
        let identifier = failureID(for: work)
        let isMediaFailure: Bool
        if case .invalidAsset? = error as? SQLiteLibrarySyncError { isMediaFailure = true }
        else { isMediaFailure = work == .media }
        let issue = SyncIssue(
            kind: isMediaFailure ? .mediaFailure : .invalidRemoteChange,
            resourceID: identifier,
            summary: "Sync work was preserved for recovery: \(String(describing: error))"
        )
        do {
            currentIssues = try await metadataStore.updateIssues {
                $0.removeAll { $0.resourceID == identifier && $0.conflictCopy == nil }
                $0.append(issue)
            }
        } catch {
            currentIssues.removeAll { $0.resourceID == identifier && $0.conflictCopy == nil }
            currentIssues.append(issue)
        }
    }

    private func failureID(for work: Work) -> String {
        switch work {
        case .download: "sync-batch"
        case .media: "sync-media"
        default: "sync-\(work)"
        }
    }

    private func scheduleRetry(_ work: Work, after delay: TimeInterval, generation: Int) {
        let deadline = timing.now().addingTimeInterval(delay)
        guard retryUntil[work].map({ $0 < deadline }) ?? true else { return }
        retryUntil[work] = deadline
        retryTasks[work]?.cancel()
        let scheduler = timing
        retryTasks[work] = Task { [weak self] in
            do { try await scheduler.sleep(.seconds(delay), .retry) }
            catch { return }
            await self?.retryDue(work, generation: generation)
        }
    }

    private func retryDue(_ work: Work, generation: Int) {
        guard generation == lifecycle else { return }
        retryTasks[work] = nil
        retryUntil[work] = nil
        if foreground, isStarted { request(work) }
    }

    private func cloudStatus(for error: any Error) -> SyncStatus? {
        let nsError = error as NSError
        if nsError.domain == CKErrorDomain,
           let code = CKError.Code(rawValue: nsError.code) {
            switch code {
            case .networkUnavailable, .networkFailure, .serviceUnavailable, .serverResponseLost,
                 .requestRateLimited, .zoneBusy:
                return .offline
            case .notAuthenticated, .accountTemporarilyUnavailable,
                 .permissionFailure, .managedAccountRestricted:
                return .accountUnavailable
            default:
                break
            }
        }
        return nil
    }
}
