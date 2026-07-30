import Foundation
import NeoAnkiCore
import NeoAnkiTestSupport
import Testing

@testable import NeoAnki2

private struct AppStartupSample {
    let totalSeconds: Double
    let bootstrapSeconds: Double
    let libraryLoadSeconds: Double
    let launchToAppInitSeconds: Double
    let appInitToContentSeconds: Double
    let contentToReadySeconds: Double
    let events: [String: Double]
}

@Test func perfFreshProcessAppStartup() async throws {
    guard ProcessInfo.processInfo.environment["NEOANKI_RUN_APP_STARTUP_BENCHMARK"] == "1"
    else { return }

    let executable = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(".build/release/NeoAnki2")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
        Issue.record("Build the release app before running the startup benchmark.")
        return
    }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-startup-perf-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    var itemCounts = [0, 25_000]
    if ProcessInfo.processInfo.environment["NEOANKI_STARTUP_INCLUDE_100K"] == "1" {
        itemCounts.append(100_000)
    }
    for itemCount in itemCounts {
        let databaseDirectory = root.appendingPathComponent(
            "library-\(itemCount)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: databaseDirectory,
            withIntermediateDirectories: true
        )
        let store = try ItemStore(
            databaseURL: databaseDirectory.appendingPathComponent("test.sqlite")
        )
        try await store.bootstrap()
        if itemCount > 0 {
            _ = try await PerformanceFixtures.seedBasicItems(count: itemCount, in: store)
        }

        let cold = try await launchAndMeasure(
            executable: executable,
            databaseDirectory: databaseDirectory,
            traceURL: root.appendingPathComponent("cold-\(itemCount).trace"),
            readyEvent: "home_ready"
        )
        let warm = try await launchAndMeasure(
            executable: executable,
            databaseDirectory: databaseDirectory,
            traceURL: root.appendingPathComponent("warm-\(itemCount).trace"),
            readyEvent: "home_ready"
        )
        reportStartup(cold, temperature: "cold", ready: "home", itemCount: itemCount)
        reportStartup(warm, temperature: "warm", ready: "home", itemCount: itemCount)

        #expect(cold.events["content_appeared"] != nil)
        #expect(cold.events["home_ready"] != nil)
        #expect(warm.events["home_ready"] != nil)

        if itemCount > 0 {
            let browse = try await launchAndMeasure(
                executable: executable,
                databaseDirectory: databaseDirectory,
                traceURL: root.appendingPathComponent("browse-\(itemCount).trace"),
                readyEvent: "browse_ready",
                environment: ["NEOANKI_TEST_INITIAL_ROUTE": "browse"]
            )
            reportStartup(
                browse,
                temperature: "warm",
                ready: "browse",
                itemCount: itemCount
            )
            #expect(browse.events["home_ready"] != nil)
            #expect(browse.events["browse_ready"] != nil)
        }
    }
}

private func launchAndMeasure(
    executable: URL,
    databaseDirectory: URL,
    traceURL: URL,
    readyEvent: String,
    environment overrides: [String: String] = [:]
) async throws -> AppStartupSample {
    try? FileManager.default.removeItem(at: traceURL)
    let process = Process()
    process.executableURL = executable
    process.arguments = ["-NeoAnkiTesting"]
    var environment = ProcessInfo.processInfo.environment
    environment["NEOANKI_TESTING"] = "1"
    environment["NEOANKI_TEST_DB_DIR"] = databaseDirectory.path
    environment["NEOANKI_STARTUP_TRACE_PATH"] = traceURL.path
    for (key, value) in overrides {
        environment[key] = value
    }
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    let launchedAt = Date.now.timeIntervalSince1970
    try process.run()
    defer {
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
    }

    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    var events: [String: Double] = [:]
    while ContinuousClock.now < deadline {
        events = readStartupEvents(traceURL)
        if events[readyEvent] != nil { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let readyAt = try #require(events[readyEvent])
    let appInitAt = try #require(events["app_init"])
    let bootstrapAt = try #require(events["bootstrap_begin"])
    let modelsAt = try #require(events["models_ready"])
    let contentAt = try #require(events["content_appeared"])
    return AppStartupSample(
        totalSeconds: readyAt - launchedAt,
        bootstrapSeconds: modelsAt - bootstrapAt,
        libraryLoadSeconds: readyAt - modelsAt,
        launchToAppInitSeconds: appInitAt - launchedAt,
        appInitToContentSeconds: contentAt - appInitAt,
        contentToReadySeconds: readyAt - contentAt,
        events: events
    )
}

private func readStartupEvents(_ url: URL) -> [String: Double] {
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
    var events: [String: Double] = [:]
    for line in contents.split(separator: "\n") {
        let parts = line.split(separator: "\t", maxSplits: 1)
        guard parts.count == 2, let timestamp = Double(parts[1]) else { continue }
        let name = String(parts[0])
        if events[name] == nil {
            events[name] = timestamp
        }
    }
    return events
}

private func reportStartup(
    _ sample: AppStartupSample,
    temperature: String,
    ready: String,
    itemCount: Int
) {
    print(
        "neoanki-perf layer=app flow=fresh-process-startup "
            + "temperature=\(temperature) ready=\(ready) item_count=\(itemCount) "
            + "duration_s=\(sample.totalSeconds.formatted(.number.precision(.fractionLength(4)))) "
            + "bootstrap_s=\(sample.bootstrapSeconds.formatted(.number.precision(.fractionLength(4)))) "
            + "library_load_s=\(sample.libraryLoadSeconds.formatted(.number.precision(.fractionLength(4)))) "
            + "launch_to_init_s=\(sample.launchToAppInitSeconds.formatted(.number.precision(.fractionLength(4)))) "
            + "init_to_content_s=\(sample.appInitToContentSeconds.formatted(.number.precision(.fractionLength(4)))) "
            + "content_to_ready_s=\(sample.contentToReadySeconds.formatted(.number.precision(.fractionLength(4))))"
    )
}
