import Darwin
import Foundation

public enum PerformanceScale: String, Sendable, CaseIterable {
    case small
    case medium
    case large
    case stress

    public var itemCount: Int {
        switch self {
        case .small: 100
        case .medium: 1_000
        case .large: 25_000
        case .stress: 100_000
        }
    }

    public var deckCount: Int {
        switch self {
        case .small: 5
        case .medium: 20
        case .large: 100
        case .stress: 500
        }
    }

    public var nestedDeckDepth: Int {
        switch self {
        case .small: 2
        case .medium: 3
        case .large: 5
        case .stress: 8
        }
    }

    /// Independent subtrees in the deck forest (stress: dozens of deep hierarchies).
    public var deckSubtreeCount: Int {
        switch self {
        case .stress: max(1, deckCount / nestedDeckDepth)
        default: 1
        }
    }

    public var deckSwitchCount: Int {
        switch self {
        case .small: 5
        case .medium: 10
        case .large: 10
        case .stress: 20
        }
    }

    /// Switches timed in one measurement.
    public var deckSwitchMeasureCount: Int {
        min(deckSwitchCount, 10)
    }

    /// Full study-session length. Stress uses a 10k-card session on a larger library.
    public var studyLoopItemCount: Int {
        switch self {
        case .stress: 10_000
        default: itemCount
        }
    }

    /// Library size for FSRS optimize fixtures (optimizer needs ≥100 two-review histories).
    public var fsrsLibraryItemCount: Int {
        switch self {
        case .small, .medium: itemCount
        case .large: 2_500
        case .stress: 10_000
        }
    }

    /// Batch size for revert/update/editor sample flows.
    public var batchSampleSize: Int {
        switch self {
        case .small: 100
        case .medium: 250
        case .large: 2_500
        case .stress: 5_000
        }
    }

    /// Cards exercised in interaction-support benchmarks.
    public var interactionSampleSize: Int {
        switch self {
        case .small: 200
        case .medium: 500
        case .large: 5_000
        case .stress: 10_000
        }
    }

    public var includesPortableDeckTransfer: Bool {
        self != .stress
    }

    /// Wall-clock budget for the default fast perf script (`run-performance-tests.sh`).
    public static let suiteBudgetSeconds: Int = 300

    public static var current: PerformanceScale? {
        guard ProcessInfo.processInfo.environment["NEOANKI_RUN_PERFORMANCE_TESTS"] != nil else {
            return nil
        }
        let raw = ProcessInfo.processInfo.environment["NEOANKI_PERF_SCALE"] ?? "small"
        return PerformanceScale(rawValue: raw)
    }

    /// Opt-in guard for perf tests. Pass `flow` to skip flows disabled by `PerformanceFlowPolicy`.
    public static func require(flow: String? = nil) -> PerformanceScale? {
        guard let scale = current else { return nil }
        guard PerformanceFlowPolicy.isEnabled(flow: flow, scale: scale) else { return nil }
        return scale
    }
}

public struct PerformanceMeasurement: Sendable, Codable, Equatable {
    public let flow: String
    public let layer: String
    public let scale: String
    public let durationSeconds: Double
    public let peakRSSBytes: Int64
    public let metadata: [String: String]

    public init(
        flow: String,
        layer: String,
        scale: String,
        durationSeconds: Double,
        peakRSSBytes: Int64,
        metadata: [String: String] = [:]
    ) {
        self.flow = flow
        self.layer = layer
        self.scale = scale
        self.durationSeconds = durationSeconds
        self.peakRSSBytes = peakRSSBytes
        self.metadata = metadata
    }
}

@MainActor
public enum PerformanceHarness {
    public static var isEnabled: Bool {
        PerformanceScale.current != nil
    }

    public static var scale: PerformanceScale {
        PerformanceScale.current ?? .small
    }

    public static func measure(
        flow: String,
        layer: String = "core",
        metadata: [String: String] = [:],
        _ body: () async throws -> [String: String] = { [:] }
    ) async throws -> PerformanceMeasurement {
        let scale = scale
        resetPeakRSS()
        let start = ContinuousClock.now
        let resultMetadata = try await body()
        let duration = start.duration(to: .now)
        let measurement = PerformanceMeasurement(
            flow: flow,
            layer: layer,
            scale: scale.rawValue,
            durationSeconds: Double(duration.components.seconds)
                + Double(duration.components.attoseconds) / 1e18,
            peakRSSBytes: peakRSSBytes(),
            metadata: metadata.merging(resultMetadata) { current, _ in current }
        )
        report(measurement)
        return measurement
    }

    public static func report(_ measurement: PerformanceMeasurement) {
        let metadataSummary = measurement.metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let metadataSuffix = metadataSummary.isEmpty ? "" : " \(metadataSummary)"
        print(
            "neoanki-perf layer=\(measurement.layer) flow=\(measurement.flow) "
                + "scale=\(measurement.scale) "
                + "duration_s=\(measurement.durationSeconds.formatted(.number.precision(.fractionLength(4)))) "
                + "peak_rss_bytes=\(measurement.peakRSSBytes)"
                + metadataSuffix
        )
        appendNDJSON(measurement)
    }

    private static func appendNDJSON(_ measurement: PerformanceMeasurement) {
        guard let path = ProcessInfo.processInfo.environment["NEOANKI_PERF_JSON"], !path.isEmpty else {
            return
        }
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(measurement),
              let line = String(data: data, encoding: .utf8)
        else { return }
        let payload = line + "\n"
        PerformanceReportWriter.shared.append(payload, to: url)
    }

    private static func resetPeakRSS() {
        var usage = rusage()
        _ = getrusage(RUSAGE_SELF, &usage)
    }

    private static func peakRSSBytes() -> Int64 {
        var usage = rusage()
        _ = getrusage(RUSAGE_SELF, &usage)
        return Int64(usage.ru_maxrss)
    }
}

private enum PerformanceReportWriter {
    static let shared = LockedFileWriter()
}

private final class LockedFileWriter: @unchecked Sendable {
    private let lock = NSLock()

    func append(_ payload: String, to url: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            FileManager.default.createFile(atPath: url.path, contents: payload.data(using: .utf8))
            return
        }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(payload.utf8))
    }
}
