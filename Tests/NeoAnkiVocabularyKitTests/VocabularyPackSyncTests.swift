import Foundation
import Observation
import Testing
@testable import NeoAnkiVocabularyKit

private actor MemoryPackCloud: VocabularyPackCloudTransport {
    var packs: [String: CloudVocabularyPack] = [:]
    var chunks: [String: Data] = [:]
    var reads: [String: Int] = [:]
    var failedDownload: String?
    var failedUpload: String?
    var account = "account-one"
    var pauseCatalog = false
    var catalogRequests = 0
    var gate: CheckedContinuation<Void, Never>?
    private var catalogObservers: [CheckedContinuation<Void, Never>] = []
    private var publicationObservers: [CheckedContinuation<Void, Never>] = []
    func accountIdentifier() -> String { account }
    func catalog() async -> [CloudVocabularyPack] {
        catalogRequests += 1
        let observers = catalogObservers; catalogObservers = []
        for observer in observers { observer.resume() }
        if pauseCatalog { await withCheckedContinuation { gate = $0 } }
        return Array(packs.values)
    }
    func publish(_ pack: CloudVocabularyPack) throws {
        try pack.validate(); packs[pack.id] = pack
        let observers = publicationObservers; publicationObservers = []
        for observer in observers { observer.resume() }
    }
    func waitForCatalogRequests(_ count: Int) async {
        while catalogRequests < count {
            await withCheckedContinuation { catalogObservers.append($0) }
        }
    }
    func waitForPublishedPacks(_ count: Int) async {
        while packs.count < count {
            await withCheckedContinuation { publicationObservers.append($0) }
        }
    }
    func uploadChunk(id: String, data: Data) throws {
        if id == failedUpload { throw TestCloudError.offline }
        if let prior = chunks[id] { #expect(prior == data) }
        chunks[id] = data
    }
    func downloadChunk(id: String, maximumBytes: Int) throws -> Data {
        if id == failedDownload { throw TestCloudError.offline }
        reads[id, default: 0] += 1
        let data = try #require(chunks[id])
        #expect(data.count <= maximumBytes)
        return data
    }
    func failDownload(_ id: String?) { failedDownload = id }
    func failUpload(_ id: String?) { failedUpload = id }
    func setPauseCatalog(_ value: Bool) { pauseCatalog = value }
    func releaseCatalog() { pauseCatalog = false; gate?.resume(); gate = nil }
    func changeAccount() { account = "account-two"; packs = [:]; chunks = [:] }
}
private enum TestCloudError: Error { case offline }

private func fixturePack(at root: URL, large: Bool = false, definition: String = "Одиниця мови.") throws -> URL {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let jsonl = root.appendingPathComponent("entries.jsonl")
    let media = root.appendingPathComponent("source-media")
    try FileManager.default.createDirectory(at: media.appendingPathComponent("speaker"), withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: media.appendingPathComponent("speaker/word.ogg"))
    var lines = Data()
    for index in 0..<(large ? 500 : 1) {
        let entry = LexicalEntry(id: "word-\(index)", language: "uk", canonicalForm: .init(text: .init("слово\(index)")),
            pronunciations: [.init(scheme: "stress", representations: [.text(.init("сло\u{301}во\(index)")), .audio(.init(path: "speaker/word.ogg"))])],
            senses: [.init(id: "sense", definitions: [.init(text: .init(large ? String(repeating: "meaning ", count: 3_000) : definition))])])
        lines += try JSONEncoder().encode(entry); lines.append(0x0A)
    }
    try lines.write(to: jsonl)
    let url = root.appendingPathComponent("Fixture.neovocab")
    _ = try VocabularyPackCompiler.compile(jsonlURL: jsonl, to: url,
        descriptor: .init(id: "fixture.uk", title: "My dictionary", languages: ["uk"], capabilities: [.lexicon, .pronunciation]),
        options: .init(mediaDirectoryURL: media))
    return url
}

private func workspace() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pack-sync-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@MainActor private func waitForPackState(_ condition: () -> Bool) async {
    // The model and both condition reads run on MainActor, so no mutation can
    // fall between the initial check and registering the observation. onChange
    // fires before mutation; the resumed task rechecks after the setter returns.
    while !condition() {
        await withCheckedContinuation { continuation in
            withObservationTracking { _ = condition() } onChange: { continuation.resume() }
        }
    }
}

@Test @MainActor func packCatalogSyncsAutomaticallyButBytesDownloadOnlyOnDemand() async throws {
    let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
    let source = try fixturePack(at: root.appendingPathComponent("source"))
    let cloud = MemoryPackCloud()
    let first = VocabularyPackSyncModel(rootURL: root.appendingPathComponent("first"), transport: cloud)
    let secondRoot = root.appendingPathComponent("second")
    let second = VocabularyPackSyncModel(rootURL: secondRoot, transport: cloud)
    defer { first.setEnabled(false); second.setEnabled(false) }
    _ = try await first.installLocal(from: source)
    #expect(await cloud.packs.isEmpty)
    first.setEnabled(true)
    await cloud.waitForPublishedPacks(1)
    second.setEnabled(true)
    await waitForPackState { second.catalog.count == 1 && !second.isRefreshing }
    #expect(second.localPacks.isEmpty)
    #expect(await cloud.reads.isEmpty)
    let descriptor = try #require(second.catalog.first)
    second.download(descriptor)
    await waitForPackState { second.localPacks.count == 1 && second.transfers.isEmpty }
    #expect(second.errors.isEmpty)
    let installed = try #require(second.localPacks.first)
    let opened = try await VocabularyPack.open(at: installed.packageURL)
    let result = try #require(try await opened.search(query: "слово0", mode: .exact).first)
    #expect(DictionaryEntryText.render(result).contains("сло\u{301}во0"))
    #expect(try Data(contentsOf: await opened.mediaURL(for: .init(path: "speaker/word.ogg"))) == Data([1, 2, 3]))
    let readCount = await cloud.reads.values.reduce(0, +)
    await second.removeDownload(packID: installed.id)
    #expect(second.localPacks.isEmpty)
    #expect(second.catalog.count == 1)
    #expect(await cloud.packs.count == 1)
    second.setEnabled(false)
    let restarted = VocabularyPackSyncModel(rootURL: secondRoot, transport: cloud)
    #expect(restarted.catalog == second.catalog)
    #expect(!restarted.isEnabled)
    await restarted.refresh()
    #expect(await cloud.reads.values.reduce(0, +) == readCount)
}

@Test func interruptedPackTransfersResumeWithoutPublishingPartialPacks() async throws {
    let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
    let source = try fixturePack(at: root.appendingPathComponent("source"), large: true)
    let transfer = VocabularyPackCloudTransfer()
    let pack = try await transfer.describe(at: source)
    #expect(pack.files[1].byteCount > Int64(CloudVocabularyPack.chunkBytes))
    let cloud = MemoryPackCloud()
    let interruption = pack.chunkID(file: 1, chunk: 1)
    await cloud.failUpload(interruption)
    await #expect(throws: TestCloudError.offline) {
        try await transfer.upload(pack, from: source, transport: cloud) { _, _ in }
    }
    #expect(await cloud.packs.isEmpty)
    await cloud.failUpload(nil)
    try await transfer.upload(pack, from: source, transport: cloud) { _, _ in }
    #expect(await cloud.packs.count == 1)
    await cloud.failDownload(interruption)
    let downloads = root.appendingPathComponent("downloads")
    await #expect(throws: TestCloudError.offline) {
        _ = try await transfer.download(pack, into: downloads, transport: cloud) { _, _ in }
    }
    #expect(try await InstalledVocabularyPackStore(rootURL: downloads).installedPacks().isEmpty)
    await cloud.failDownload(nil)
    let completed = try await transfer.download(pack, into: downloads, transport: cloud) { _, _ in }
    #expect(await cloud.reads[pack.chunkID(file: 1, chunk: 0)] == 1)
    #expect(try await VocabularyPack.open(at: completed).manifest.id == pack.manifest.id)
}

@Test @MainActor func disablingPackSyncRejectsLateCatalogAndDoesNotUpload() async throws {
    let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
    let source = try fixturePack(at: root.appendingPathComponent("source"))
    let cloud = MemoryPackCloud()
    await cloud.setPauseCatalog(true)
    let model = VocabularyPackSyncModel(rootURL: root.appendingPathComponent("installed"), transport: cloud)
    _ = try await model.installLocal(from: source)
    // Call refresh in the same MainActor turn as enabling. It takes ownership
    // before the automatic task can enter, so we can join this exact late work.
    let refresh = Task { @MainActor in
        model.setEnabled(true)
        await model.refresh()
    }
    await cloud.waitForCatalogRequests(1)
    model.setEnabled(false)
    await cloud.releaseCatalog()
    await refresh.value
    #expect(!model.isEnabled)
    #expect(model.catalog.isEmpty)
    #expect(await cloud.chunks.isEmpty)
    #expect(model.localPacks.count == 1)
}

@Test func unsafePackCatalogAndFailedReplacementKeepLocalPackIntact() async throws {
    let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
    let source = try fixturePack(at: root.appendingPathComponent("source"))
    let transfer = VocabularyPackCloudTransfer()
    let valid = try await transfer.describe(at: source)
    var invalid = valid
    invalid.files[1].path = "../escape.sqlite"
    #expect(throws: (any Error).self) { try invalid.validate() }
    invalid = valid; invalid.files[1].byteCount = .max
    #expect(throws: (any Error).self) { try invalid.validate() }
    let store = InstalledVocabularyPackStore(rootURL: root.appendingPathComponent("installed"))
    let original = try await store.install(from: source)
    let corrupt = root.appendingPathComponent("Corrupt.neovocab")
    try FileManager.default.copyItem(at: source, to: corrupt)
    try Data("corrupt".utf8).write(to: corrupt.appendingPathComponent("lexicon.sqlite"))
    await #expect(throws: (any Error).self) { _ = try await store.install(from: corrupt, replacingExisting: true) }
    let retained = try await store.installedPacks()
    #expect(retained.map(\.id) == [original.id])
    #expect(retained.first?.packageURL.resolvingSymlinksInPath().path == original.packageURL.resolvingSymlinksInPath().path)
    #expect(try await VocabularyPack.open(at: original.packageURL).manifest.id == valid.manifest.id)
}

@Test @MainActor func onDemandReplacementRetainsOfflineVersionUntilDownloadSucceeds() async throws {
    let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
    let original = try fixturePack(at: root.appendingPathComponent("original"))
    let updated = try fixturePack(at: root.appendingPathComponent("updated"), definition: "Updated definition.")
    let cloud = MemoryPackCloud()
    let transfer = VocabularyPackCloudTransfer()
    let replacement = try await transfer.describe(at: updated)
    try await transfer.upload(replacement, from: updated, transport: cloud) { _, _ in }
    let model = VocabularyPackSyncModel(rootURL: root.appendingPathComponent("installed"), transport: cloud)
    _ = try await model.installLocal(from: original)
    let oldKey = try #require(model.localKeys["fixture.uk"])
    model.setEnabled(true)
    defer { model.setEnabled(false) }
    // Finish the automatic upload of the existing offline version as well as
    // catalog refresh before starting the competing version's download.
    await waitForPackState {
        model.catalog.contains(replacement) && model.catalog.contains { $0.id == oldKey }
            && !model.isRefreshing && model.transfers.isEmpty
    }
    await cloud.failDownload(replacement.chunkID(file: 1, chunk: 0))
    model.download(replacement)
    await waitForPackState { model.errors[replacement.id] != nil && model.transfers.isEmpty }
    #expect(model.localKeys["fixture.uk"] == oldKey)
    await cloud.failDownload(nil)
    model.download(replacement)
    await waitForPackState { model.isDownloaded(replacement) && model.transfers.isEmpty }
    #expect(model.localPacks.count == 1)
    let installed = try #require(model.localPacks.first)
    let pack = try await VocabularyPack.open(at: installed.packageURL)
    #expect(try await pack.search(query: "слово0", mode: .exact).first?.senses.first?.definitions.first?.text.value == "Updated definition.")
}

@Test @MainActor func changingICloudAccountInvalidatesCachedPackCatalogAndStaleDownload() async throws {
    let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
    let source = try fixturePack(at: root.appendingPathComponent("source"))
    let cloud = MemoryPackCloud()
    let transfer = VocabularyPackCloudTransfer()
    let original = try await transfer.describe(at: source)
    try await transfer.upload(original, from: source, transport: cloud) { _, _ in }
    let installedRoot = root.appendingPathComponent("installed")
    let model = VocabularyPackSyncModel(rootURL: installedRoot, transport: cloud)
    model.setEnabled(true)
    defer { model.setEnabled(false) }
    // Catalog publication precedes local-pack scanning. Wait for that refresh to
    // finish so the explicit account-change refresh below is not coalesced away.
    await waitForPackState { model.catalog.count == 1 && !model.isRefreshing }
    let initialCatalogRequests = await cloud.catalogRequests
    await cloud.changeAccount()
    await model.refresh()
    await cloud.waitForCatalogRequests(initialCatalogRequests + 1)
    await waitForPackState { model.catalog.isEmpty && !model.isRefreshing }
    let restarted = VocabularyPackSyncModel(rootURL: installedRoot, transport: cloud)
    #expect(restarted.catalog.isEmpty, "Account invalidation must also replace the persisted catalog cache.")
    model.download(original)
    #expect(model.transfers.isEmpty)
    #expect(await cloud.reads.isEmpty)
}
