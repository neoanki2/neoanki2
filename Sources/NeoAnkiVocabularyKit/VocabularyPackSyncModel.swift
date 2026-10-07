import Foundation
import Observation

public struct VocabularyPackTransferProgress: Sendable, Equatable {
    public var isUploading: Bool
    public var completedBytes: Int64
    public var totalBytes: Int64
}

/// Shared presentation state for independently synchronized, immutable offline dictionaries.
@MainActor @Observable
public final class VocabularyPackSyncModel {
    public private(set) var catalog: [CloudVocabularyPack] = []
    public private(set) var localPacks: [InstalledVocabularyPack] = []
    public private(set) var localKeys: [String: String] = [:]
    public private(set) var localSizes: [String: Int64] = [:]
    public private(set) var isEnabled = false
    public private(set) var isRefreshing = false
    public private(set) var transfers: [String: VocabularyPackTransferProgress] = [:]
    public private(set) var errors: [String: String] = [:]
    public private(set) var catalogError: String?
    public var isAvailable: Bool { transport != nil }
    private let rootURL: URL
    private let store: InstalledVocabularyPackStore
    private let transport: (any VocabularyPackCloudTransport)?
    private let transfer = VocabularyPackCloudTransfer()
    private var accountID: String?
    private var generation = 0
    private var automaticTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var downloads: [String: Task<Void, Never>] = [:]
    private let refreshInterval: Duration

    public init(rootURL: URL, transport: (any VocabularyPackCloudTransport)? = nil, refreshInterval: Duration = .seconds(60)) {
        self.rootURL = rootURL
        store = InstalledVocabularyPackStore(rootURL: rootURL)
        self.transport = transport
        self.refreshInterval = refreshInterval
        let cache = rootURL.appendingPathComponent(".cloud-catalog.json")
        if let size = try? cache.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8_000_000,
           let data = try? Data(contentsOf: cache), let saved = try? JSONDecoder().decode(Cache.self, from: data) {
            accountID = saved.accountID
            catalog = saved.packs.filter { (try? $0.validate()) != nil }
        }
    }

    public func setEnabled(_ enabled: Bool) {
        let enabled = enabled && isAvailable
        guard enabled != isEnabled else { return }
        generation += 1
        isEnabled = enabled
        automaticTask?.cancel(); automaticTask = nil
        uploadTask?.cancel(); uploadTask = nil
        for task in downloads.values { task.cancel() }
        downloads = [:]; transfers = [:]; isRefreshing = false
        guard enabled else { return }
        automaticTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: self.refreshInterval) } catch { return }
                await self.refresh()
            }
        }
    }

    public func reloadLocal() async {
        do {
            let packs = try await store.installedPacks()
            var keys: [String: String] = [:]
            var sizes: [String: Int64] = [:]
            for pack in packs {
                // Reading a small manifest avoids rehashing large, already installed dictionaries.
                do {
                    let descriptor = try await transfer.describe(at: pack.packageURL)
                    keys[pack.id] = descriptor.id; sizes[pack.id] = descriptor.byteCount
                }
                catch { errors[pack.id] = error.localizedDescription }
            }
            localPacks = packs; localKeys = keys; localSizes = sizes
        } catch { catalogError = error.localizedDescription }
    }

    public func refresh() async {
        guard isEnabled, !isRefreshing, let transport else { return }
        let epoch = generation
        isRefreshing = true
        defer { if epoch == generation { isRefreshing = false } }
        do {
            let account = try await transport.accountIdentifier()
            try check(epoch)
            if account != accountID {
                if accountID != nil {
                    setEnabled(false)
                    catalog = []; accountID = account
                    try saveCache()
                    setEnabled(true)
                    return
                }
                catalog = []; accountID = account
                try saveCache()
            }
            let incoming = try await transport.catalog()
            try check(epoch)
            for pack in incoming { try pack.validate() }
            guard Set(incoming.map(\.id)).count == incoming.count else {
                throw VocabularyPackError.invalidPackage("The dictionary catalog contains duplicate versions.")
            }
            catalog = sorted(incoming); catalogError = nil
            try saveCache()
            await reloadLocal()
            try check(epoch)
            startUploads(epoch: epoch)
        } catch {
            if epoch == generation, !(error is CancellationError) { catalogError = error.localizedDescription }
        }
    }

    public func localPacksChanged() async {
        await reloadLocal()
        await refresh()
    }

    public func installLocal(from url: URL) async throws -> InstalledVocabularyPack {
        let installed = try await store.install(from: url)
        await reloadLocal()
        Task { [weak self] in await self?.refresh() }
        return installed
    }

    public func isDownloaded(_ pack: CloudVocabularyPack) -> Bool { localKeys[pack.manifest.id] == pack.id }

    public func download(_ pack: CloudVocabularyPack) {
        guard isEnabled, let transport, catalog.contains(pack), downloads[pack.id] == nil, !isDownloaded(pack),
              !isTransferring(packID: pack.manifest.id) else { return }
        do { try pack.validate() }
        catch { errors[pack.id] = error.localizedDescription; return }
        let epoch = generation
        errors[pack.id] = nil
        transfers[pack.id] = .init(isUploading: false, completedBytes: 0, totalBytes: pack.byteCount)
        downloads[pack.id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if epoch == self.generation { self.transfers[pack.id] = nil; self.downloads[pack.id] = nil }
            }
            do {
                try pack.validate()
                let account = try await transport.accountIdentifier()
                try self.check(epoch)
                guard account == self.accountID else {
                    await self.refresh()
                    throw VocabularyPackError.ioFailure("The iCloud account changed. Refresh the dictionary list and try again.")
                }
                let staging = try await self.transfer.download(pack, into: self.rootURL, transport: transport,
                    progress: self.progress(for: pack.id, uploading: false, epoch: epoch))
                try self.check(epoch)
                _ = try await self.store.install(from: staging, replacingExisting: true)
                try? FileManager.default.removeItem(at: staging)
                await self.reloadLocal()
            } catch {
                if epoch == self.generation, !(error is CancellationError) { self.errors[pack.id] = error.localizedDescription }
            }
        }
    }

    public func cancelDownload(id: String) { downloads[id]?.cancel() }

    public func isTransferring(packID: String) -> Bool {
        if let key = localKeys[packID], transfers[key] != nil { return true }
        return catalog.contains { $0.manifest.id == packID && transfers[$0.id] != nil }
    }

    public func removeDownload(packID: String) async {
        if let key = localKeys[packID], transfers[key] != nil { return }
        guard !transfers.keys.contains(where: { key in catalog.first { $0.id == key }?.manifest.id == packID }) else { return }
        do { try await store.remove(id: packID); await reloadLocal() }
        catch { errors[packID] = error.localizedDescription }
    }

    private func startUploads(epoch: Int) {
        guard uploadTask == nil, let transport else { return }
        uploadTask = Task { [weak self] in
            guard let self else { return }
            defer { if epoch == self.generation { self.uploadTask = nil } }
            var attempted = Set<String>()
            while !Task.isCancelled, epoch == self.generation,
                  let local = self.localPacks.first(where: { pack in
                      guard let key = self.localKeys[pack.id] else { return false }
                      return !attempted.contains(key) && !self.catalog.contains { $0.id == key }
                  }), let key = self.localKeys[local.id] {
                attempted.insert(key)
                self.errors[local.id] = nil
                do {
                    let pack = try await self.transfer.describe(at: local.packageURL)
                    try self.check(epoch)
                    self.transfers[key] = .init(isUploading: true, completedBytes: 0, totalBytes: pack.byteCount)
                    try await self.transfer.upload(pack, from: local.packageURL, transport: transport,
                        progress: self.progress(for: key, uploading: true, epoch: epoch))
                    try self.check(epoch)
                    self.catalog = self.sorted(self.catalog.filter { $0.id != pack.id } + [pack])
                    try self.saveCache()
                } catch {
                    if epoch == self.generation, !(error is CancellationError) { self.errors[local.id] = error.localizedDescription }
                }
                if epoch == self.generation { self.transfers[key] = nil }
            }
        }
    }

    private func progress(for id: String, uploading: Bool, epoch: Int) -> @Sendable (Int64, Int64) -> Void {
        { [weak self] completed, total in
            Task { @MainActor in
                guard let self, self.generation == epoch, self.transfers[id] != nil else { return }
                self.transfers[id] = .init(isUploading: uploading, completedBytes: completed, totalBytes: total)
            }
        }
    }

    private func check(_ epoch: Int) throws {
        guard epoch == generation, isEnabled, !Task.isCancelled else { throw CancellationError() }
    }
    private func sorted(_ packs: [CloudVocabularyPack]) -> [CloudVocabularyPack] {
        packs.sorted { $0.manifest.title == $1.manifest.title ? $0.id < $1.id : $0.manifest.title.localizedStandardCompare($1.manifest.title) == .orderedAscending }
    }
    private struct Cache: Codable { let accountID: String?; let packs: [CloudVocabularyPack] }
    private func saveCache() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(Cache(accountID: accountID, packs: catalog)).write(to: rootURL.appendingPathComponent(".cloud-catalog.json"), options: .atomic)
    }
}
