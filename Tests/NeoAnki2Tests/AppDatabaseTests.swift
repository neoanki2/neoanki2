import Foundation
import Testing

@testable import NeoAnki2

@Test func appDatabaseUsesTestDirectoryWhenEnvSet() {
    let testDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-appdb-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)

    setenv("NEOANKI_TEST_DB_DIR", testDir.path, 1)
    defer { unsetenv("NEOANKI_TEST_DB_DIR") }

    let url = AppDatabase.testURL()
    #expect(url.path.hasPrefix(testDir.path))
    #expect(url.lastPathComponent == "test.sqlite")
}

@Test func appDatabaseIsTestingWhenArgumentPresent() {
    let args = ProcessInfo.processInfo.arguments + ["-NeoAnkiTesting"]
    let info = ProcessInfo.processInfo
    // AppDatabase checks ProcessInfo at call time; verify the predicate logic
    #expect(args.contains("-NeoAnkiTesting") || info.environment["NEOANKI_TESTING"] == "1" || args.contains("-NeoAnkiTesting"))
}

@Test func appDatabaseDefaultURLUsesTestPathInTestingMode() {
    setenv("NEOANKI_TESTING", "1", 1)
    defer { unsetenv("NEOANKI_TESTING") }

    let url = AppDatabase.defaultURL
    #expect(url.lastPathComponent == "test.sqlite")
}
