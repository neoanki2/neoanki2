import CloudKit
import Foundation
import NeoAnkiApplication
import NeoAnkiCore

public struct SyncMetadata: Codable, Sendable {
    public var engineState: CKSyncEngine.State.Serialization?
    /// Independent cursor for explicit library reads, including missed pushes.
    public var libraryZoneChangeToken: Data?
    public var deviceID: String
    public var outboundCursor: Int64
    public var stagedInbound: [SyncRecordEnvelope]
    public var pendingOutbound: [SyncRecordEnvelope]?
    public var serverBaseline: [String: SyncRecordEnvelope]?
    public var issues: [SyncIssue]
    /// Losing versions remain recoverable after automatic conflict resolution.
    /// Optional for backward compatibility with metadata written by older apps.
    public var resolvedConflictCopies: [SyncConflictCopy]?
    public var didCreateInitialBackup: Bool?
    public var didCompleteInitialMerge: Bool?
    /// The receive may have overlapped an upload of this key. Recheck the
    /// current server value before applying the staged version.
    var inboundNeedingConfirmation: Set<String>?

    public init(
        engineState: CKSyncEngine.State.Serialization? = nil,
        libraryZoneChangeToken: Data? = nil,
        deviceID: String = UUID().uuidString,
        outboundCursor: Int64 = 0,
        stagedInbound: [SyncRecordEnvelope] = [],
        pendingOutbound: [SyncRecordEnvelope]? = nil,
        serverBaseline: [String: SyncRecordEnvelope]? = nil,
        issues: [SyncIssue] = [],
        resolvedConflictCopies: [SyncConflictCopy]? = nil,
        didCreateInitialBackup: Bool? = nil,
        didCompleteInitialMerge: Bool? = nil
    ) {
        self.engineState = engineState
        self.libraryZoneChangeToken = libraryZoneChangeToken
        self.deviceID = deviceID
        self.outboundCursor = outboundCursor
        self.stagedInbound = stagedInbound
        self.pendingOutbound = pendingOutbound
        self.serverBaseline = serverBaseline
        self.issues = issues
        self.resolvedConflictCopies = resolvedConflictCopies
        self.didCreateInitialBackup = didCreateInitialBackup
        self.didCompleteInitialMerge = didCompleteInitialMerge
    }
}

/// Stores engine state and sync bookkeeping beside, never inside, domain tables.
public actor SyncMetadataStore {
    typealias Conflict = (local: SyncRecordEnvelope?, server: SyncRecordEnvelope)

    private let fileURL: URL
    private let stagedAssetDirectory: URL
    private let outboundAssetDirectory: URL
    private let writeMetadata: @Sendable (Data, URL) throws -> Void
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()
    private struct FileVersion: Equatable {
        let inode: UInt64
        let modified: Date
        let size: UInt64
    }
    private var cached: (version: FileVersion, metadata: SyncMetadata)?
    private var activeUploads: Set<String> = []
    private var uploadsDuringRead: Set<String> = []
    private var readingZone = false

    public init(directory: URL) {
        self.init(directory: directory, writeMetadata: { data, url in
            try data.write(to: url, options: .atomic)
        })
    }

    init(directory: URL, writeMetadata: @escaping @Sendable (Data, URL) throws -> Void) {
        fileURL = directory.appendingPathComponent("cloud-sync-metadata.plist", isDirectory: false)
        stagedAssetDirectory = directory.appendingPathComponent("inbound-assets", isDirectory: true)
        outboundAssetDirectory = directory.appendingPathComponent("outbound-assets", isDirectory: true)
        self.writeMetadata = writeMetadata
    }

    public func load() throws -> SyncMetadata {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return SyncMetadata()
        }
        let version: FileVersion? = if let inode = attributes[.systemFileNumber] as? NSNumber,
            let modified = attributes[.modificationDate] as? Date, let size = attributes[.size] as? NSNumber {
            FileVersion(inode: inode.uint64Value, modified: modified, size: size.uint64Value)
        } else { nil }
        if let cached, version == cached.version { return cached.metadata }
        var metadata = try decoder.decode(SyncMetadata.self, from: Data(contentsOf: fileURL))
        metadata.stagedInbound = metadata.stagedInbound.map(resolveAssetLocation)
        metadata.pendingOutbound = metadata.pendingOutbound?.map(resolveAssetLocation)
        cached = version.map { ($0, metadata) }
        return metadata
    }

    public func save(_ metadata: SyncMetadata) throws {
        var metadata = metadata
        // CKSyncEngine emits state updates while a service awaits a network
        // operation. Preserve that newer serialization during bookkeeping.
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let current = try load()
            metadata.engineState = current.engineState
            metadata.libraryZoneChangeToken = current.libraryZoneChangeToken
            // Only completeIncoming may remove delivered records. A stale
            // service snapshot cannot erase a concurrent transport callback.
            metadata.stagedInbound = current.stagedInbound
            metadata.serverBaseline = current.serverBaseline
            metadata.resolvedConflictCopies = mergedArchive(current, metadata)
        }
        try persist(metadata)
    }

    /// Finish conflicts against the latest metadata so a concurrent transport
    /// callback cannot lose another newly preserved conflict.
    func completeConflicts(_ issues: [SyncIssue]) throws -> SyncMetadata {
        var metadata = try load()
        let resolved = issues.filter { $0.conflictCopy != nil }
        guard !resolved.isEmpty else { return metadata }
        archiveConflicts(resolved, in: &metadata)
        try persist(metadata)
        return metadata
    }

    private func archiveConflicts(_ resolved: [SyncIssue], in metadata: inout SyncMetadata) {
        let resolvedIDs = Set(resolved.map(\.id))
        var archive = metadata.resolvedConflictCopies ?? []
        var archivedIDs = Set(archive.map(\.id))
        for copy in resolved.compactMap(\.conflictCopy) where archivedIDs.insert(copy.id).inserted {
            archive.append(copy)
        }
        metadata.resolvedConflictCopies = archive
        metadata.issues.removeAll { resolvedIDs.contains($0.id) }
    }

    func saveEngineState(_ state: CKSyncEngine.State.Serialization) throws {
        var metadata = try load()
        metadata.engineState = state
        try persist(metadata)
    }

    func resetLibraryZoneChangeToken() throws {
        var metadata = try load()
        metadata.libraryZoneChangeToken = nil
        try persist(metadata)
    }

    /// Commit delivered records before the engine may persist its next fetch
    /// token. On process death, the service can replay this durable inbox.
    func receive(_ records: [SyncRecordEnvelope]) throws {
        guard !records.isEmpty else { return }
        try receiveZonePage(records, token: nil)
    }

    /// Stage payloads and advance the explicit fetch cursor in the same write.
    /// A failed page (including asset staging) must leave the old cursor intact.
    func receiveZonePage(_ records: [SyncRecordEnvelope], token: Data?) throws {
        try receive(records, token: token, conflicts: [])
    }

    func beginZoneRead() {
        readingZone = true
        uploadsDuringRead = activeUploads
    }

    func endZoneRead() {
        readingZone = false
        uploadsDuringRead.removeAll()
    }

    func beginUpload(_ records: [SyncRecordEnvelope]) throws {
        let keys = Set(records.map(\.syncKey))
        var metadata = try load()
        let overlap = keys.intersection(metadata.stagedInbound.map(\.syncKey))
        if !overlap.isEmpty {
            metadata.inboundNeedingConfirmation = (metadata.inboundNeedingConfirmation ?? []).union(overlap)
            try persist(metadata)
        }
        activeUploads.formUnion(keys)
        if readingZone { uploadsDuringRead.formUnion(keys) }
    }

    func endUpload(_ records: [SyncRecordEnvelope]) {
        activeUploads.subtract(records.map(\.syncKey))
    }

    func confirmIncoming(_ original: [SyncRecordEnvelope], current: [SyncRecordEnvelope]) throws {
        var metadata = try load()
        let confirmed = Dictionary(current.map { ($0.syncKey, $0) }, uniquingKeysWith: { _, latest in latest })
        let originals = Dictionary(original.map { ($0.syncKey, $0) }, uniquingKeysWith: { _, latest in latest })
        let replaced = metadata.stagedInbound.filter { originals[$0.syncKey] == $0 && !activeUploads.contains($0.syncKey) }
        guard !replaced.isEmpty else { return }
        let replacing = Set(replaced.map(\.syncKey))
        metadata.stagedInbound = metadata.stagedInbound.map { record in
            guard replacing.contains(record.syncKey), let newer = confirmed[record.syncKey] else { return record }
            return record.isSameVersion(as: newer) ? record : newer
        }
        metadata.inboundNeedingConfirmation?.subtract(replaced.map(\.syncKey))
        try persist(metadata)
        removeStagedAssets(in: replaced.filter { old in
            confirmed[old.syncKey].map { !old.isSameVersion(as: $0) } ?? false
        })
    }

    func appendOutgoing(_ records: [SyncRecordEnvelope], cursor: Int64) throws {
        var metadata = try load()
        guard cursor > metadata.outboundCursor else { return }
        let staged = try stageOutbound(records)
        metadata.pendingOutbound = (metadata.pendingOutbound ?? []) + staged
        metadata.outboundCursor = cursor
        do { try persist(metadata) }
        catch { removeStagedAssets(in: staged); throw error }
    }

    func finishOutgoing(_ records: [SyncRecordEnvelope]) throws {
        guard !records.isEmpty else { return }
        var metadata = try load()
        let sent = Dictionary(grouping: records, by: \.syncKey)
        let previousCount = metadata.pendingOutbound?.count
        metadata.pendingOutbound?.removeAll { sent[$0.syncKey]?.contains($0) == true }
        if previousCount != metadata.pendingOutbound?.count { try persist(metadata) }
        removeStagedAssets(in: records)
    }

    func finishApplying(_ records: [SyncRecordEnvelope], journalCursor: Int64? = nil) throws {
        guard !records.isEmpty else { return }
        var metadata = try load()
        if let journalCursor { metadata.outboundCursor = max(journalCursor, metadata.outboundCursor) }
        let applied = Dictionary(records.map { ($0.syncKey, $0) }, uniquingKeysWith: { _, latest in latest })
        let completed = Set(metadata.stagedInbound.filter { applied[$0.syncKey] == $0 }.map(\.syncKey))
        let archived = metadata.issues.filter { issue in
            guard let copy = issue.conflictCopy, !copy.isRestorable,
                  LibraryResourceKind(rawValue: copy.resourceKind) != nil else { return false }
            return completed.contains("\(copy.resourceKind):\(copy.originalResourceID)")
        }
        if !archived.isEmpty { archiveConflicts(archived, in: &metadata) }
        _ = try completeIncoming(records, metadata: metadata)
    }

    func stageDownloadedMedia(_ downloaded: SyncRecordEnvelope,
                              replacing original: SyncRecordEnvelope) throws -> SyncRecordEnvelope? {
        var metadata = try load()
        guard let index = metadata.stagedInbound.firstIndex(of: original) else { return nil }
        guard let staged = try stageAssets(in: [downloaded]).first else { return nil }
        metadata.stagedInbound[index] = staged
        do { try persist(metadata) }
        catch { removeStagedAssets(in: [staged]); throw error }
        return staged
    }

    func updateIssues(_ update: @Sendable (inout [SyncIssue]) -> Void) throws -> [SyncIssue] {
        var metadata = try load()
        let before = metadata.issues
        update(&metadata.issues)
        if before != metadata.issues { try persist(metadata) }
        return metadata.issues
    }

    /// Persist the losing copies and stage their server replacements together
    /// before the transport removes any corresponding outgoing records.
    func receiveConflicts(_ conflicts: [Conflict]) throws {
        guard !conflicts.isEmpty else { return }
        try receive(conflicts.map(\.server), token: nil, conflicts: conflicts)
    }

    private func receive(_ records: [SyncRecordEnvelope], token: Data?, conflicts: [Conflict]) throws {
        var metadata = try load()
        let issueCount = metadata.issues.count
        recordConflicts(conflicts, metadata: &metadata)
        var latest: [String: SyncRecordEnvelope] = [:]
        for record in metadata.stagedInbound {
            latest["\(record.resourceKind):\(record.id)"] = record
        }
        let delivered = Dictionary(records.map { ("\($0.resourceKind):\($0.id)", $0) },
            uniquingKeysWith: { _, newest in newest })
        if token != nil {
            let overlap = activeUploads.union(uploadsDuringRead).intersection(delivered.keys)
            if !overlap.isEmpty {
                metadata.inboundNeedingConfirmation = (metadata.inboundNeedingConfirmation ?? []).union(overlap)
            }
        }
        let recoveringMedia = metadata.issues.contains { $0.kind == .mediaFailure }
        let unstaged = delivered.compactMap { key, record -> SyncRecordEnvelope? in
            if record.asset == nil, latest[key] == record { return nil }
            guard !recoveringMedia, let existing = latest[key], let asset = existing.asset,
                  let file = existing.stagedFileURL, file.isFileURL,
                  existing.revision == record.revision, existing.deviceID == record.deviceID,
                  existing.order == record.order, Self.sameContent(existing, record),
                  let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  Int64(size) == asset.byteSize else { return record }
            return nil
        }
        if unstaged.isEmpty, token == nil, metadata.issues.count == issueCount { return }
        let staged = unstaged.isEmpty ? [] : try stageAssets(in: unstaged)
        for record in staged { latest["\(record.resourceKind):\(record.id)"] = record }
        let obsolete = (metadata.stagedInbound + staged).filter { old in
            latest["\(old.resourceKind):\(old.id)"]?.stagedFileURL != old.stagedFileURL
        }
        metadata.stagedInbound = Array(latest.values)
        if let token { metadata.libraryZoneChangeToken = token }
        try persist(metadata)
        removeStagedAssets(in: obsolete)
    }

    func completeIncoming(_ consumed: [SyncRecordEnvelope], metadata: SyncMetadata) throws -> SyncMetadata {
        var committed = metadata
        let current = try load()
        committed.engineState = current.engineState
        committed.libraryZoneChangeToken = current.libraryZoneChangeToken
        let consumedByResource = Dictionary(grouping: consumed) { "\($0.resourceKind):\($0.id)" }
        committed.stagedInbound = current.stagedInbound.filter { record in
            consumedByResource["\(record.resourceKind):\(record.id)"]?.contains(record) != true
        }
        committed.serverBaseline = current.serverBaseline
        committed.inboundNeedingConfirmation = current.inboundNeedingConfirmation
        let remaining = Set(committed.stagedInbound.map(\.syncKey))
        committed.inboundNeedingConfirmation = committed.inboundNeedingConfirmation?.intersection(remaining)
        committed.resolvedConflictCopies = mergedArchive(current, committed)
        for record in consumed { setBaseline(record, metadata: &committed) }
        try persist(committed)
        removeStagedAssets(in: consumed)
        return committed
    }

    func stageOutbound(_ records: [SyncRecordEnvelope]) throws -> [SyncRecordEnvelope] {
        try stageAssets(in: records, directory: outboundAssetDirectory)
    }

    func acknowledge(_ records: [SyncRecordEnvelope], outgoing: [SyncRecordEnvelope] = []) throws {
        guard !records.isEmpty else { return }
        var metadata = try load()
        for record in records { setBaseline(record, metadata: &metadata) }
        if !outgoing.isEmpty {
            let sent = Dictionary(grouping: outgoing, by: \.syncKey)
            metadata.pendingOutbound?.removeAll { sent[$0.syncKey]?.contains($0) == true }
        }
        try persist(metadata)
        removeStagedAssets(in: outgoing)
    }

    private func setBaseline(_ record: SyncRecordEnvelope, metadata: inout SyncMetadata) {
        if metadata.serverBaseline == nil { metadata.serverBaseline = [:] }
        metadata.serverBaseline?["\(record.resourceKind):\(record.id)"] = SyncRecordEnvelope(
            id: record.id, resourceKind: record.resourceKind, revision: record.revision,
            deviceID: record.deviceID, order: record.order, isTombstone: record.isTombstone,
            payload: record.payload, asset: record.asset
        )
    }

    static func sameContent(_ a: SyncRecordEnvelope, _ b: SyncRecordEnvelope) -> Bool {
        a.id == b.id && a.resourceKind == b.resourceKind && a.payload == b.payload
            && a.asset == b.asset && a.isTombstone == b.isTombstone
    }

    func preserveConflict(local: SyncRecordEnvelope, server: SyncRecordEnvelope) throws {
        var metadata = try load()
        let issueCount = metadata.issues.count
        recordConflicts([(local, server)], metadata: &metadata)
        guard metadata.issues.count != issueCount else { return }
        try persist(metadata)
    }

    private func recordConflicts(_ conflicts: [Conflict], metadata: inout SyncMetadata) {
        guard !conflicts.isEmpty else { return }
        // Retries and duplicate deliveries preserve one copy of each losing version.
        var preserved = Dictionary(grouping:
            metadata.issues.compactMap(\.conflictCopy) + (metadata.resolvedConflictCopies ?? []),
            by: \.originalResourceID)
        for (local, server) in conflicts {
            guard let local, !Self.sameContent(local, server),
                  preserved[local.id]?.contains(where: {
                      $0.resourceKind == local.resourceKind && $0.payload == local.payload
                          && $0.wasTombstone == local.isTombstone
                  }) != true else { continue }
            let kind: SyncIssueKind = local.isTombstone || server.isTombstone ? .deleteVersusEdit
                : local.resourceKind == "deck" ? .deckConflict
                : local.resourceKind == "itemType" ? .itemTypeConflict : .itemConflict
            let copy = SyncConflictCopy(resourceKind: local.resourceKind, originalResourceID: local.id,
                sourceDeviceID: local.deviceID, payload: local.payload,
                wasTombstone: local.isTombstone, acceptedWasTombstone: server.isTombstone)
            metadata.issues.append(SyncIssue(kind: kind, resourceID: local.id,
                summary: "A change from another device was accepted. Your prior version is preserved.", conflictCopy: copy))
            preserved[local.id, default: []].append(copy)
        }
    }

    private func persist(_ metadata: SyncMetadata) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var stored = metadata
        // iOS can relocate the entire data container during an app update. Queue
        // owned filenames, never the installation-specific absolute sandbox URL.
        stored.stagedInbound = stored.stagedInbound.map(relativeAssetLocation)
        stored.pendingOutbound = stored.pendingOutbound?.map(relativeAssetLocation)
        try writeMetadata(encoder.encode(stored), fileURL)
        cached = nil
    }

    /// Recognizes only opaque files created by this store, including absolute
    /// paths from older installations. Remote asset names never select a path.
    private func ownedAssetLocation(_ url: URL) -> (directory: URL, filename: String)? {
        let filename = url.lastPathComponent
        guard UUID(uuidString: filename) != nil else { return nil }
        let parent = url.deletingLastPathComponent().lastPathComponent
        let directory: URL
        switch parent {
        case "inbound-assets": directory = stagedAssetDirectory
        case "outbound-assets": directory = outboundAssetDirectory
        default: return nil
        }
        if url.scheme == nil {
            guard url.relativeString == "\(parent)/\(filename)" else { return nil }
        } else {
            // Legacy absolute locations must have our metadata-directory layout.
            // Do not reinterpret arbitrary external files as queue-owned assets.
            guard url.isFileURL,
                  url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
                    == fileURL.deletingLastPathComponent().lastPathComponent else { return nil }
        }
        return (directory, filename)
    }

    private func replacingAssetLocation(_ record: SyncRecordEnvelope, with url: URL) -> SyncRecordEnvelope {
        SyncRecordEnvelope(
            id: record.id, resourceKind: record.resourceKind, revision: record.revision,
            deviceID: record.deviceID, order: record.order, isTombstone: record.isTombstone,
            payload: record.payload, asset: record.asset, stagedFileURL: url
        )
    }

    private func resolveAssetLocation(_ record: SyncRecordEnvelope) -> SyncRecordEnvelope {
        guard let url = record.stagedFileURL, let location = ownedAssetLocation(url) else { return record }
        return replacingAssetLocation(record, with: location.directory.appendingPathComponent(location.filename))
    }

    private func relativeAssetLocation(_ record: SyncRecordEnvelope) -> SyncRecordEnvelope {
        guard let url = record.stagedFileURL, let location = ownedAssetLocation(url),
              let relative = URL(string: "\(location.directory.lastPathComponent)/\(location.filename)")
        else { return record }
        return replacingAssetLocation(record, with: relative)
    }

    private func mergedArchive(_ current: SyncMetadata, _ incoming: SyncMetadata) -> [SyncConflictCopy]? {
        guard current.resolvedConflictCopies != nil || incoming.resolvedConflictCopies != nil else { return nil }
        let existing = current.resolvedConflictCopies ?? []
        let ids = Set(existing.map(\.id))
        return existing + (incoming.resolvedConflictCopies ?? []).filter { !ids.contains($0.id) }
    }

    public func stageAssets(in records: [SyncRecordEnvelope]) throws -> [SyncRecordEnvelope] {
        try stageAssets(in: records, directory: stagedAssetDirectory)
    }

    private func stageAssets(in records: [SyncRecordEnvelope], directory: URL) throws -> [SyncRecordEnvelope] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var created: [URL] = []
        do { return try records.map { record in
            try Task.checkCancellation()
            guard let source = record.stagedFileURL, let asset = record.asset else { return record }
            // Remote hash/extension strings are untrusted path components.
            // Validation happens in the adapter; staging uses an opaque name.
            let destination = directory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: source, to: destination)
            created.append(destination)
            #if os(iOS)
            // Like the library database, the private queue needs to remain
            // available to background sync after the first device unlock.
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path)
            #endif
            return SyncRecordEnvelope(
                id: record.id,
                resourceKind: record.resourceKind,
                revision: record.revision,
                deviceID: record.deviceID,
                order: record.order,
                isTombstone: record.isTombstone,
                payload: record.payload,
                asset: asset,
                stagedFileURL: destination
            )
        } } catch {
            for url in created { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    public func removeStagedAssets(in records: [SyncRecordEnvelope]) {
        let roots = [stagedAssetDirectory, outboundAssetDirectory].map { $0.standardizedFileURL.path + "/" }
        for record in records {
            guard let url = record.stagedFileURL,
                  roots.contains(where: { url.standardizedFileURL.path.hasPrefix($0) })
            else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

extension SyncRecordEnvelope {
    var syncKey: String { "\(resourceKind):\(id)" }
    var isMedia: Bool { resourceKind == LibraryResourceKind.media.rawValue }

    func isSameVersion(as other: Self) -> Bool {
        revision == other.revision && deviceID == other.deviceID && order == other.order
            && SyncMetadataStore.sameContent(self, other)
    }
}
