import Foundation
import NeoAnkiApplication
import NeoAnkiFeatures
import Testing

private actor StartupSyncService: SyncService {
    private(set) var starts = 0
    private var entered = false
    private var observer: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func start() async {
        starts += 1
        guard starts == 1 else { return }
        await withCheckedContinuation { continuation in
            release = continuation
            entered = true
            observer?.resume(); observer = nil
        }
    }
    func waitUntilStarted() async {
        if entered { return }
        await withCheckedContinuation { observer = $0 }
    }
    func finish() { release?.resume(); release = nil }
    func synchronize() async {}
    func stop() async {}
    func status() async -> SyncStatus { .current(lastSync: nil) }
    func issues() async -> [SyncIssue] { [] }
}

@MainActor
@Test func backgroundPushAndSceneBootstrapShareOneInitialization() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
    let service = StartupSyncService()
    let model = LibraryFeatureModel(library: repository, syncService: service)
    let scene = Task { await model.bootstrap(startSync: true) }
    await service.waitUntilStarted()
    var backgroundEntered = false
    let background = Task {
        backgroundEntered = true
        await model.bootstrap(startSync: true)
    }
    while !backgroundEntered { await Task.yield() }
    await service.finish()
    await scene.value
    await background.value
    #expect(await service.starts == 1)
    #expect(model.loadState == .ready)
}
