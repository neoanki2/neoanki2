import Foundation
import NeoAnkiCore

public enum PerformanceFixtures {
    public static var repoRoot: URL {
        if let root = ProcessInfo.processInfo.environment["NEOANKI_REPO_ROOT"] {
            return URL(fileURLWithPath: root, isDirectory: true)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    public static func makeStore(
        label: String = UUID().uuidString,
        scheduler: any Scheduler = FSRSScheduler()
    ) async throws -> (store: ItemStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoanki-perf-\(label)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try ItemStore(
            databaseURL: directory.appendingPathComponent("library.sqlite"),
            scheduler: scheduler,
            mediaStore: MediaStore(rootDirectory: directory)
        )
        try await store.bootstrap()
        return (store, directory)
    }

    @discardableResult
    public static func seedBasicItems(
        count: Int,
        in store: ItemStore,
        now: Date = .now
    ) async throws -> Int {
        try await importBasicItems(count: count, in: store, now: now)
    }

    /// Chunked JSON import respecting production import limits.
    @discardableResult
    public static func importBasicItems(
        count: Int,
        in store: ItemStore,
        now: Date = .now
    ) async throws -> Int {
        var imported = 0
        var startIndex = 0
        while imported < count {
            let batchSize = min(count - imported, ImportLimits.maxRows)
            let batchImported = try await store.importItems(
                from: makeJSONImportPayload(rowCount: batchSize, startIndex: startIndex),
                adapter: JSONImportAdapter(),
                now: now
            )
            imported += batchImported
            startIndex += batchSize
        }
        return imported
    }

    @discardableResult
    public static func importBasicItemsCSV(
        count: Int,
        in store: ItemStore,
        now: Date = .now
    ) async throws -> Int {
        var imported = 0
        var startIndex = 0
        while imported < count {
            let batchSize = min(count - imported, ImportLimits.maxRows)
            let batchImported = try await store.importItems(
                from: makeCSVImportPayload(rowCount: batchSize, startIndex: startIndex),
                adapter: CSVImportAdapter(itemTypeName: "Basic"),
                now: now
            )
            imported += batchImported
            startIndex += batchSize
        }
        return imported
    }

    public static func importBatchCount(for itemCount: Int) -> Int {
        (itemCount + ImportLimits.maxRows - 1) / ImportLimits.maxRows
    }

    public static func seedNestedDecks(
        count: Int,
        depth: Int,
        in store: ItemStore
    ) async throws -> [Deck] {
        var decks: [Deck] = []
        decks.reserveCapacity(count)
        var parentID: UUID?
        var remaining = count
        while remaining > 0 {
            let levelCount = min(depth, remaining)
            for _ in 0..<levelCount {
                let deck = Deck(name: "Deck \(decks.count)", parentID: parentID)
                _ = try await store.createDeck(deck)
                decks.append(deck)
                parentID = deck.id
                remaining -= 1
                if remaining == 0 { break }
            }
            parentID = decks.first?.id
        }
        return decks
    }

    /// Many independent subtrees (each depth levels) instead of one mega-tree.
    public static func seedForestDecks(
        count: Int,
        depth: Int,
        in store: ItemStore
    ) async throws -> [Deck] {
        var decks: [Deck] = []
        decks.reserveCapacity(count)
        var chainParent: UUID?
        var chainLength = 0
        for index in 0..<count {
            if chainLength >= depth {
                chainParent = nil
                chainLength = 0
            }
            let deck = Deck(name: "Deck \(index)", parentID: chainParent)
            _ = try await store.createDeck(deck)
            decks.append(deck)
            chainParent = deck.id
            chainLength += 1
        }
        return decks
    }

    public static func seedDecksAtScale(_ scale: PerformanceScale, in store: ItemStore) async throws -> [Deck] {
        if scale == .large || scale == .stress {
            return try await seedForestDecks(
                count: scale.deckCount,
                depth: scale.nestedDeckDepth,
                in: store
            )
        }
        return try await seedNestedDecks(
            count: scale.deckCount,
            depth: scale.nestedDeckDepth,
            in: store
        )
    }

    public static func leafDecks(in decks: [Deck]) -> [Deck] {
        decks.filter { deck in
            !decks.contains(where: { $0.parentID == deck.id })
        }
    }

    public static func subtreeRootDecks(in decks: [Deck], depth: Int) -> [Deck] {
        stride(from: 0, to: decks.count, by: depth).map { decks[$0] }
    }

    public static func seedReviewHistory(
        in store: ItemStore,
        targetObservations: Int = 100,
        clock: inout TestClock
    ) async throws -> Int {
        try await seedFSRSOptimizationHistory(
            in: store,
            cardCount: targetObservations,
            clock: &clock
        )
    }

    /// Seeds repeated reviews without re-querying the due queue between passes.
    public static func seedFSRSOptimizationHistory(
        in store: ItemStore,
        cardCount: Int = 100,
        clock: inout TestClock
    ) async throws -> Int {
        let due = try await store.fetchDueCards(asOf: clock.now())
        let cards = Array(due.prefix(cardCount))
        var reviewCount = 0
        let now = clock.now()

        let initialRatings = ReviewRating.allCases
        for (index, entry) in cards.enumerated() {
            _ = try await store.submitReview(
                cardID: entry.card.id,
                rating: initialRatings[index % initialRatings.count],
                now: now
            )
            reviewCount += 1
        }
        // Optimizer targets are interday outcomes, and promotion eligibility
        // deliberately requires representative failures across 30 study days.
        // Distribute deterministic outcomes instead of weakening production
        // optimizer or promotion thresholds for a benchmark fixture.
        let studyDayCount = 30
        for (index, entry) in cards.enumerated() {
            let day = index % studyDayCount + 1
            let followUp = now.addingTimeInterval(TimeInterval(day) * 86_400)
            _ = try await store.submitReview(
                cardID: entry.card.id,
                rating: index.isMultiple(of: 5) ? .again : .good,
                now: followUp
            )
            reviewCount += 1
        }
        clock.advance(by: TimeInterval(studyDayCount) * 86_400)

        return reviewCount
    }

    public static func makeJSONImportPayload(rowCount: Int, startIndex: Int = 0) -> Data {
        var rows: [String] = []
        rows.reserveCapacity(rowCount)
        for offset in 0..<rowCount {
            let index = startIndex + offset
            rows.append(#"{"Front":"Question \#(index)","Back":"Answer \#(index)"}"#)
        }
        let json = """
        {
          "itemType": "Basic",
          "rows": [
            \(rows.joined(separator: ",\n    "))
          ]
        }
        """
        return Data(json.utf8)
    }

    public static func makeCSVImportPayload(rowCount: Int, startIndex: Int = 0) -> Data {
        var lines = ["Front,Back,tags"]
        lines.reserveCapacity(rowCount + 1)
        for offset in 0..<rowCount {
            let index = startIndex + offset
            lines.append("Question \(index),Answer \(index),tag\(index % 10)")
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    public static func exampleAuthoredDeckURL(name: String) -> URL {
        repoRoot.appendingPathComponent("docs/examples/\(name).neoanki", isDirectory: true)
    }

    /// Assign every item in `store` to `deck` outside timed sections.
    public static func assignItems(to deckID: UUID, in store: ItemStore) async throws {
        for item in try await store.listItems() {
            _ = try await store.updateItemDeck(itemID: item.id, deckID: deckID)
        }
    }

    /// Spread items evenly across `decks` (round-robin by list order).
    public static func assignItemsRoundRobin(to decks: [Deck], in store: ItemStore) async throws {
        guard !decks.isEmpty else { return }
        for (index, item) in try await store.listItems().enumerated() {
            _ = try await store.updateItemDeck(itemID: item.id, deckID: decks[index % decks.count].id)
        }
    }
}
