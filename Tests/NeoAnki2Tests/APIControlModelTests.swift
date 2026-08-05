import Foundation
import Network
import NeoAnkiAPI
import NeoAnkiCore
import Testing
@testable import NeoAnki2

@MainActor
@Test func localAPIDefaultsOffAndReportsTheConfiguredPortConflict() async throws {
    AppPreferences.resetForTesting()
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-api-control-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ItemStore(databaseURL: directory.appendingPathComponent("library.sqlite"))
    try await store.bootstrap()
    let model = APIControlModel(
        store: store,
        vocabularyRootURL: directory.appendingPathComponent(
            "Vocabulary Packs", isDirectory: true
        )
    )
    await model.restore()
    #expect(!model.isEnabled)
    #expect(!model.isRunning)

    let port = try #require(NWEndpoint.Port(rawValue: UInt16.random(in: 30_000 ... 50_000)))
    let occupyingService = NeoAnkiAPIService(
        store: store,
        authorization: APIAuthorizationStore(
            persistence: InMemoryAPICredentialPersistence()
        ),
        applicationVersion: "test",
        authority: "127.0.0.1:\(port.rawValue)"
    )
    let occupyingServer = NeoAnkiLocalAPIServer(
        service: occupyingService,
        configuration: .init(host: "127.0.0.1", port: port)
    )
    try await occupyingServer.start()
    defer { Task { await occupyingServer.stop() } }

    await model.applyPort(Int(port.rawValue))
    await model.setEnabled(true)
    #expect(!model.isEnabled)
    #expect(!model.isRunning)
    #expect(model.port == Int(port.rawValue))
    #expect(model.diagnostic == "Port \(port.rawValue) is unavailable. NeoAnki did not try another port.")
}
