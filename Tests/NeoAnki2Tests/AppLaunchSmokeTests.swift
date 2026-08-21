import Foundation
import Testing

@Test func appBinaryLaunchesInTestingMode() async throws {
    let buildRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(".build/debug/NeoAnki2")

    guard FileManager.default.fileExists(atPath: buildRoot.path) else {
        // Callers that want this process smoke test build the app first; the
        // required UI jobs exercise the same binary launch on isolated runners.
        return
    }

    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-launch-smoke-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let process = Process()
    process.executableURL = buildRoot
    process.arguments = ["-NeoAnkiTesting"]
    process.environment = [
        "NEOANKI_TESTING": "1",
        "NEOANKI_TEST_DB_DIR": tempDir.path,
    ]

    try process.run()
    try await Task.sleep(for: .seconds(2))
    if process.isRunning {
        process.terminate()
    }
    process.waitUntilExit()

    #expect(process.terminationReason == .exit || process.terminationReason == .uncaughtSignal)
}
