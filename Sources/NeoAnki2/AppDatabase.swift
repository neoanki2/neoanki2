import Foundation
import NeoAnkiCore

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
