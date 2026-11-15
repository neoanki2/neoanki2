import CloudKit
import Foundation
import NeoAnkiApplication
@testable import NeoAnkiCloudSync

// The fake server's identity/content rules must not reuse the production
// comparator: otherwise mutating that comparator also mutates our oracle.
private func syncContractSameContent(_ lhs: SyncRecordEnvelope, _ rhs: SyncRecordEnvelope) -> Bool {
    lhs.id == rhs.id && lhs.resourceKind == rhs.resourceKind
        && lhs.isTombstone == rhs.isTombstone && lhs.payload == rhs.payload && lhs.asset == rhs.asset
}

/// A server owns its bytes. Client URLs and transient download leases never
/// become server state, so moving or deleting a replica cannot repair this fake.
actor SyncContractCloud {
    private struct Version: Codable, Sendable {
        let generation: Int
        let record: SyncRecordEnvelope
        let blob: String?
    }
    private struct State: Codable {
        var generation = 0
        var versions: [String: Version] = [:]
    }
    private struct PushTarget {
        let events = SyncLibraryChanges()
        var enabled = true
    }
    struct Download: Sendable {
        let records: [SyncRecordEnvelope]
        let token: Data
        let moreComing: Bool
        let lease: URL
    }
    enum Commit: Sendable {
        case accepted
        case conflict(SyncRecordEnvelope)
    }
    enum FixtureError: Error {
        case invalidToken
        case missingUploadBytes(String)
        case missingServerBytes(String)
    }

    private let directory: URL
    private let blobs: URL
    private let leases: URL
    private let pageSize: Int
    private var state: State
    private var targets: [String: PushTarget] = [:]
    private let activityEvents = SyncLibraryChanges()

    init(directory: URL, pageSize: Int = 3) throws {
        self.directory = directory
        self.pageSize = max(1, pageSize)
        blobs = directory.appendingPathComponent("blobs", isDirectory: true)
        leases = directory.appendingPathComponent("download-leases", isDirectory: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: leases, withIntermediateDirectories: true)
        let manifest = directory.appendingPathComponent("server.json")
        state = FileManager.default.fileExists(atPath: manifest.path)
            ? try JSONDecoder().decode(State.self, from: Data(contentsOf: manifest)) : State()
    }

    func pushes(for deviceID: String) async -> AsyncStream<Void> {
        if targets[deviceID] == nil { targets[deviceID] = PushTarget() }
        return await targets[deviceID]!.events.stream()
    }

    func setPushesEnabled(_ enabled: Bool, for deviceID: String) {
        if targets[deviceID] == nil { targets[deviceID] = PushTarget() }
        targets[deviceID]!.enabled = enabled
    }

    /// A coalesced wake-up hint contains no records and does not bypass the
    /// production fetcher. Useful after deliberately dropping earlier hints.
    func deliverPush(to deviceID: String) async {
        if targets[deviceID] == nil { targets[deviceID] = PushTarget() }
        await targets[deviceID]!.events.publish()
    }

    /// Unlike pushes, this observation is never dropped. Tests use it to await
    /// evidence of attempts rather than sleeping and hoping a task has run.
    func activity() async -> AsyncStream<Void> { await activityEvents.stream() }
    func didActivity() async { await activityEvents.publish() }
    func revision() -> Int { state.generation }
    func records() -> [SyncRecordEnvelope] {
        state.versions.values.sorted { $0.generation < $1.generation }.map(\.record)
    }
    func assetData(id: String) throws -> Data? {
        guard let blob = state.versions["media:\(id)"]?.blob else { return nil }
        return try Data(contentsOf: blobs.appendingPathComponent(blob))
    }
    func activeLeaseCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(at: leases, includingPropertiesForKeys: nil).count
    }

    private func key(_ record: SyncRecordEnvelope) -> String { "\(record.resourceKind):\(record.id)" }
    private func withoutURL(_ record: SyncRecordEnvelope) -> SyncRecordEnvelope {
        SyncRecordEnvelope(id: record.id, resourceKind: record.resourceKind, revision: record.revision,
            deviceID: record.deviceID, order: record.order, isTombstone: record.isTombstone,
            payload: record.payload, asset: record.asset)
    }

    /// Conditional updates use the last acknowledged/read server content,
    /// independent of a client's local journal revision and order numbers.
    func commit(_ record: SyncRecordEnvelope, baseline: SyncRecordEnvelope?, sender: String) async throws -> Commit {
        let resource = key(record)
        if let current = state.versions[resource]?.record {
            if syncContractSameContent(record, current) { return .accepted }
            if baseline == nil || !syncContractSameContent(baseline!, current) {
                return .conflict(current)
            }
        }
        var blob: String?
        if record.asset != nil, !record.isTombstone {
            guard let source = record.stagedFileURL else { throw FixtureError.missingUploadBytes(record.id) }
            let filename = UUID().uuidString
            try FileManager.default.copyItem(at: source, to: blobs.appendingPathComponent(filename))
            blob = filename
        }
        var next = state
        next.generation += 1
        next.versions[resource] = Version(generation: next.generation, record: withoutURL(record), blob: blob)
        do {
            try JSONEncoder().encode(next).write(to: directory.appendingPathComponent("server.json"), options: .atomic)
        } catch {
            if let blob { try? FileManager.default.removeItem(at: blobs.appendingPathComponent(blob)) }
            throw error
        }
        state = next
        let receivers = targets.filter { $0.key != sender && $0.value.enabled }.map(\.value.events)
        for receiver in receivers { await receiver.publish() }
        await activityEvents.publish()
        return .accepted
    }

    func page(after token: Data?) throws -> Download {
        let cursor: Int
        if let token {
            guard let text = String(data: token, encoding: .utf8), let decoded = Int(text) else {
                throw FixtureError.invalidToken
            }
            cursor = decoded
        } else { cursor = 0 }
        let changed = state.versions.values.filter { $0.generation > cursor }
            .sorted { $0.generation < $1.generation }
        let selected = Array(changed.prefix(pageSize))
        let nextCursor = selected.last?.generation ?? max(cursor, state.generation)
        return try download(selected, token: Data(String(nextCursor).utf8), moreComing: changed.count > selected.count)
    }

    func conflictDownload(_ record: SyncRecordEnvelope) throws -> Download {
        guard let version = state.versions[key(record)] else { throw FixtureError.missingServerBytes(record.id) }
        return try download([version], token: Data(), moreComing: false)
    }

    private func download(_ versions: [Version], token: Data, moreComing: Bool) throws -> Download {
        let lease = leases.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: lease, withIntermediateDirectories: true)
        do {
            var records: [SyncRecordEnvelope] = []
            for version in versions.reversed() {
                let record = version.record
                var url: URL?
                if let blob = version.blob {
                    let destination = lease.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.copyItem(at: blobs.appendingPathComponent(blob), to: destination)
                    url = destination
                }
                records.append(SyncRecordEnvelope(id: record.id, resourceKind: record.resourceKind,
                    revision: record.revision, deviceID: record.deviceID, order: record.order,
                    isTombstone: record.isTombstone, payload: record.payload, asset: record.asset, stagedFileURL: url))
            }
            // Delivery order and duplicate records must not change the result.
            if let duplicate = records.first { records.append(duplicate) }
            return Download(records: records, token: token, moreComing: moreComing, lease: lease)
        } catch {
            try? FileManager.default.removeItem(at: lease)
            throw error
        }
    }
}

/// Uses the production paged reader and durable inbox. Downloads expire before
/// the service sees the fetch completion, just as transport-owned asset leases
/// must not be used as the application's durable source of truth.
actor SyncContractTransport: CloudSyncTransport {
    enum Fault: Sendable { case none, fetch, beforeSend, afterPartialSend, afterFetchStaged }
    private let cloud: SyncContractCloud
    private let deviceID: String
    private let metadata: SyncMetadataStore
    private var online = true
    private var fault = Fault.none
    private var fetches = 0
    private var sends = 0

    init(cloud: SyncContractCloud, deviceID: String, metadata: SyncMetadataStore) {
        self.cloud = cloud
        self.deviceID = deviceID
        self.metadata = metadata
    }
    func setOnline(_ value: Bool) { online = value }
    func inject(_ value: Fault) { fault = value }
    func fetchCount() -> Int { fetches }
    func sendCount() -> Int { sends }
    private func networkFailure() -> NSError {
        NSError(domain: CKErrorDomain, code: CKError.Code.networkFailure.rawValue)
    }
    func start() async throws {
        guard online else { throw networkFailure() }
        await cloud.didActivity()
    }
    func stop() async {}

    func enqueue(_ records: [SyncRecordEnvelope]) async throws {
        sends += 1
        await cloud.didActivity()
        guard online else { throw networkFailure() }
        if fault == .beforeSend { fault = .none; throw networkFailure() }
        let loseAcknowledgement = fault == .afterPartialSend
        if loseAcknowledgement { fault = .none }
        let committedPrefix = max(1, (records.count + 1) / 2)
        for (index, record) in records.enumerated() {
            let baseline = try await metadata.load().serverBaseline?["\(record.resourceKind):\(record.id)"]
            let result = try await cloud.commit(record, baseline: baseline, sender: deviceID)
            switch result {
            case .accepted:
                if loseAcknowledgement && index + 1 == committedPrefix {
                    // The server commit survives; this acknowledgement never
                    // reaches client bookkeeping. Retrying must be idempotent.
                    throw networkFailure()
                }
                try await metadata.acknowledge([record])
            case let .conflict(server):
                if baseline == nil || !syncContractSameContent(baseline!, record) {
                    try await metadata.preserveConflict(local: record, server: server)
                }
                let download = try await cloud.conflictDownload(server)
                do {
                    try await metadata.receive(download.records)
                    try FileManager.default.removeItem(at: download.lease)
                } catch {
                    try? FileManager.default.removeItem(at: download.lease)
                    throw error
                }
            }
        }
        await cloud.didActivity()
    }

    func fetchPendingChanges() async throws -> [SyncRecordEnvelope] {
        fetches += 1
        await cloud.didActivity()
        guard online else { throw networkFailure() }
        if fault == .fetch { fault = .none; throw networkFailure() }
        let interruptAfterStaging = fault == .afterFetchStaged
        if interruptAfterStaging { fault = .none }
        let downloads = SyncContractDownloads(cloud: cloud)
        do {
            _ = try await LibraryZoneChangeFetcher(metadataStore: metadata).fetch { token in
                try await downloads.page(after: token)
            }
            try await downloads.expire()
            if interruptAfterStaging { throw networkFailure() }
            await cloud.didActivity()
            return []
        } catch {
            try? await downloads.expire()
            await cloud.didActivity()
            throw error
        }
    }
}

private actor SyncContractDownloads {
    private let cloud: SyncContractCloud
    private var leases: [URL] = []
    init(cloud: SyncContractCloud) { self.cloud = cloud }
    func page(after token: Data?) async throws -> LibraryZoneChangeFetcher.Page {
        let download = try await cloud.page(after: token)
        leases.append(download.lease)
        return LibraryZoneChangeFetcher.Page(records: download.records, token: download.token, moreComing: download.moreComing)
    }
    func expire() throws {
        for lease in leases { try FileManager.default.removeItem(at: lease) }
        leases = []
    }
}
