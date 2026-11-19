import Foundation
import NeoAnkiCore

public protocol LibraryNativeReadSupporting: Sendable {
    func nativeHomeSnapshot(scope: DeckScope, asOf: Date) async throws -> (ColdLibraryHomeSnapshot, String?)
    func nativeScopeSummary(scope: DeckScope, asOf: Date) async throws -> (ScopeSummary, String?)
}

extension SQLiteLibraryRepository: LibraryNativeReadSupporting {
    public func nativeHomeSnapshot(scope: DeckScope, asOf: Date) async throws -> (ColdLibraryHomeSnapshot, String?) {
        do { return (try await store.coldLibraryHomeSnapshot(scope: scope, asOf: asOf), nil) }
        catch let issue as MaturityReadError {
            return (try await store.coldLibraryHomeSnapshot(scope: scope, asOf: asOf, includingMaturity: false), issue.localizedDescription)
        }
    }
    public func nativeScopeSummary(scope: DeckScope, asOf: Date) async throws -> (ScopeSummary, String?) {
        do { return (try await store.scopeSummary(scope: scope, asOf: asOf), nil) }
        catch let issue as MaturityReadError {
            return (try await store.scopeSummary(scope: scope, asOf: asOf, includingMaturity: false), issue.localizedDescription)
        }
    }
}

public enum NativeLibraryReadDemand: Hashable, Sendable { case home, summary, browse, catalog }

/// Immutable data and query identity travel together to the publication boundary.
public struct NativeLibrarySnapshot: Sendable {
    public let scope: DeckScope
    public let sort: ItemSortOrder
    public let asOf: Date
    public let sourceRevision: Int64?
    public let home: ColdLibraryHomeSnapshot?
    public let summary: ScopeSummary?
    public let items: [SavedItemSummary]?
    public let catalog: ItemTypeCatalog?
    public let maturityIssue: String?
}

/// Shared demand/read policy. Presentation adapters retain navigation, selection,
/// platform comparators and generation checks. Browse/catalog are never implicit.
public actor NativeLibraryReadCoordinator {
    private let library: any LibraryBrowsing
    public init(library: any LibraryBrowsing) { self.library = library }

    public func invalidations() async -> AsyncStream<Int64> {
        guard let journal = library as? any LibraryChangePersisting else { return AsyncStream { $0.finish() } }
        return await journal.changeNotifications()
    }

    public func load(scope: DeckScope, sort: ItemSortOrder = .createdAscending,
        demand: Set<NativeLibraryReadDemand>, asOf: Date) async throws -> NativeLibrarySnapshot {
        let journal = library as? any LibraryChangePersisting
        // A snapshot spanning an awaited mutation is retried before publication.
        // Bound the work during continuous imports; callers can retain old data.
        for _ in 0..<3 {
            try Task.checkCancellation()
            let before = try await journal?.currentChangeCursor()
            var home: ColdLibraryHomeSnapshot?
            var summary: ScopeSummary?
            var issue: String?
            if demand.contains(.home) {
                if let native = library as? any LibraryNativeReadSupporting {
                    (home, issue) = try await native.nativeHomeSnapshot(scope: scope, asOf: asOf)
                } else if let boot = library as? any LibraryBootstrapping {
                    home = try await boot.coldHomeSnapshot(scope: scope, asOf: asOf)
                } else if let decks = library as? any LibraryDeckManaging {
                    home = try await ColdLibraryHomeSnapshot(itemTypes: library.loadItemTypes(),
                        deckSummaries: decks.deckSummaries(asOf: asOf),
                        allDecksSummary: library.scopeSummary(scope: .allDecks, asOf: asOf),
                        unassignedSummary: library.scopeSummary(scope: .unassigned, asOf: asOf),
                        selectedScopeSummary: library.scopeSummary(scope: scope, asOf: asOf))
                }
                summary = home?.selectedScopeSummary
            }
            if demand.contains(.summary), summary == nil {
                if let native = library as? any LibraryNativeReadSupporting {
                    (summary, issue) = try await native.nativeScopeSummary(scope: scope, asOf: asOf)
                } else { summary = try await library.scopeSummary(scope: scope, asOf: asOf) }
            }
            let rows = demand.contains(.browse) ? try await library.items(scope: scope, sort: sort, search: "") : nil
            let catalog = demand.contains(.catalog) ? try await library.loadItemTypeCatalog() : nil
            let after = try await journal?.currentChangeCursor()
            try Task.checkCancellation()
            guard before == after else { continue }
            return NativeLibrarySnapshot(scope: scope, sort: sort, asOf: asOf, sourceRevision: after,
                home: home, summary: summary, items: rows, catalog: catalog, maturityIssue: issue)
        }
        throw DatabaseError.invalidItem("The library is changing. Refresh again when the current operation finishes.")
    }
}
