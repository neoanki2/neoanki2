import Foundation
import NeoAnkiApplication
import NeoAnkiCore

struct VersionedStatisticsSource: Sendable {
    let revision: String
    let source: StatisticsSource
}

private enum StatisticsReadFailure: LocalizedError {
    case unavailable, changing
    var errorDescription: String? {
        switch self {
        case .unavailable: "Statistics are unavailable for this library."
        case .changing: "The library changed while preparing statistics. Try again when the current operation finishes."
        }
    }
}

/// Shares immutable evidence between Home and reports. A revision check never
/// hydrates card/history data, and concurrent cold requests share one read.
actor StatisticsSourceCache {
    private let capability: (any LibraryStatistics)?
    private var cached: VersionedStatisticsSource?
    private var loading: Task<VersionedStatisticsSource, Error>?

    init(_ capability: (any LibraryStatistics)?) { self.capability = capability }

    func revision() async throws -> String {
        guard let capability else { throw StatisticsReadFailure.unavailable }
        return try await capability.statisticsRevision()
    }

    func load(revision: String, force: Bool) async throws -> VersionedStatisticsSource {
        if !force, !revision.isEmpty, let cached, cached.revision == revision { return cached }
        if let loading { return try await loading.value }
        guard let capability else { throw StatisticsReadFailure.unavailable }
        // Model-owned evidence loading survives a screen's task cancellation.
        // Returning to a destination must not cancel and restart the same scan.
        let task = Task {
            for _ in 0..<3 {
                let before = try await capability.statisticsRevision()
                let source = try await capability.statisticsSource()
                let after = try await capability.statisticsRevision()
                if before.isEmpty || after.isEmpty || before == after {
                    return VersionedStatisticsSource(revision: before.isEmpty ? "" : after, source: source)
                }
            }
            throw StatisticsReadFailure.changing
        }
        loading = task
        defer { loading = nil }
        let result = try await task.value
        if !result.revision.isEmpty { cached = result }
        return result
    }
}

/// Scene-owned presentation models, separate for the Home panels and complete
/// reports so their periods, filters, and selected sections cannot interfere.
@MainActor
public final class StatisticsWorkspace {
    private struct Key: Hashable {
        let scope: DeckScope
        let sessionID: UUID?
        let home: Bool
    }
    private let reads: StatisticsSourceCache
    private let capacity: Int
    private var models: [Key: StatisticsFeatureModel] = [:]
    private var recency: [Key: UInt64] = [:]
    private var access: UInt64 = 0

    public init(library: any LibraryRepository, statistics: (any LibraryStatistics)? = nil, capacity: Int = 8) {
        reads = StatisticsSourceCache(statistics ?? (library as? any LibraryStatistics))
        self.capacity = max(2, capacity)
    }

    public func report(scope: DeckScope = .allDecks, sessionID: UUID? = nil) -> StatisticsFeatureModel {
        model(for: Key(scope: scope, sessionID: sessionID, home: false))
    }

    public func home(scope: DeckScope = .allDecks) -> StatisticsFeatureModel {
        model(for: Key(scope: scope, sessionID: nil, home: true))
    }

    private func model(for key: Key) -> StatisticsFeatureModel {
        access &+= 1
        recency[key] = access
        if let model = models[key] { return model }
        let model = StatisticsFeatureModel(scope: key.scope, sessionID: key.sessionID, reads: reads)
        if key.home { model.query.period = .today }
        models[key] = model
        if models.count > capacity,
           let oldest = recency.filter({ $0.key != key }).min(by: { $0.value < $1.value })?.key {
            models.removeValue(forKey: oldest)
            recency.removeValue(forKey: oldest)
        }
        return model
    }
}
