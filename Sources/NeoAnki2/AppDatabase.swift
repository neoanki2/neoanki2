import Foundation
import NeoAnkiCore

/// Opt-in fresh-process launch tracing for isolated performance tests. Normal
/// launches do no file work because the environment key is absent.
enum AppStartupTrace {
    static func mark(_ event: String) {
        recorder.mark(event)
    }

    private static let recorder = Recorder()

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [(String, TimeInterval)] = []

        func mark(_ event: String) {
            guard let path = ProcessInfo.processInfo.environment["NEOANKI_STARTUP_TRACE_PATH"],
                  !path.isEmpty
            else { return }

            let timestamp = Date.now.timeIntervalSince1970
            lock.lock()
            defer { lock.unlock() }
            events.append((event, timestamp))
            guard event == "home_ready" || event == "browse_ready" else { return }
            let contents = events
                .map { "\($0.0)\t\($0.1)\n" }
                .joined()
            do {
                try Data(contents.utf8).write(
                    to: URL(fileURLWithPath: path),
                    options: .atomic
                )
            } catch {
                // Performance tracing must never alter startup behavior.
            }
        }
    }
}

enum AppDatabase {
    static var isTesting: Bool {
        ProcessInfo.processInfo.arguments.contains("-NeoAnkiTesting")
            || ProcessInfo.processInfo.environment["NEOANKI_TESTING"] == "1"
    }

    static var defaultURL: URL {
        if isTesting {
            return testURL()
        }
        return productionURL
    }

    static var productionURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("neoanki2", isDirectory: true)
            .appendingPathComponent("neoanki2.sqlite")
    }

    static func testURL() -> URL {
        let base = ProcessInfo.processInfo.environment["NEOANKI_TEST_DB_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("neoanki2-ui-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("test.sqlite")
    }
}
