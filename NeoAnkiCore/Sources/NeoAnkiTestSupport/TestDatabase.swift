import Foundation
import NeoAnkiCore

public enum TestDatabase {
    /// Creates an isolated SQLite file in a temporary directory.
    public static func makeURL(label: String = UUID().uuidString) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoanki2-tests-\(label)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("test.sqlite")
    }

    public static func makeStore(
        label: String = UUID().uuidString,
        scheduler: any Scheduler = FSRSScheduler(),
        now: Date? = nil
    ) async throws -> (store: ItemStore, context: ScenarioContext) {
        let url = makeURL(label: label)
        let store = try ItemStore(databaseURL: url, scheduler: scheduler)
        try await store.bootstrap()
        let clock = TestClock(start: now ?? Date(timeIntervalSince1970: 1_700_000_000))
        let context = ScenarioContext(store: store, clock: clock)
        return (store, context)
    }
}
