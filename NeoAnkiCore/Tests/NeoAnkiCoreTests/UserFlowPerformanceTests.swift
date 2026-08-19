import Foundation
import NeoAnkiCore
import NeoAnkiTestSupport
import Testing

// Opt-in baseline suite (≤5 minutes total via ./Scripts/run-performance-tests.sh):
//   NEOANKI_RUN_PERFORMANCE_TESTS=1 ./Scripts/run-performance-tests.sh
// Extended large/stress: ./Scripts/run-performance-tests-slow.sh

private func requirePerformanceScale(flow: String? = nil) -> PerformanceScale? {
    PerformanceScale.require(flow: flow)
}

@Test func perfBootstrapFreshLibrary() async throws {
    guard let scale = requirePerformanceScale() else { return }

    _ = try await PerformanceHarness.measure(flow: "bootstrap-fresh-library", metadata: ["item_count": "0"]) {
        let (store, directory) = try await PerformanceFixtures.makeStore(label: "bootstrap")
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try await store.listItems().isEmpty)
        return [:]
    }
    _ = scale
}

@Test func perfBulkJSONImport() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let itemCount = scale.itemCount

    let (store, directory) = try await PerformanceFixtures.makeStore(label: "json-import")
    defer { try? FileManager.default.removeItem(at: directory) }

    let measurement = try await PerformanceHarness.measure(
        flow: "import-json-items",
        metadata: [
            "item_count": "\(itemCount)",
            "import_batches": "\(PerformanceFixtures.importBatchCount(for: itemCount))",
        ]
    ) {
        let imported = try await PerformanceFixtures.importBasicItems(count: itemCount, in: store)
        #expect(imported == itemCount)
        return ["imported_items": "\(imported)"]
    }
    #expect(measurement.metadata["imported_items"] == "\(itemCount)")
}

@Test func perfBulkCSVImport() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let itemCount = scale.itemCount

    let (store, directory) = try await PerformanceFixtures.makeStore(label: "csv-import")
    defer { try? FileManager.default.removeItem(at: directory) }

    _ = try await PerformanceHarness.measure(
        flow: "import-csv-items",
        metadata: [
            "item_count": "\(itemCount)",
            "import_batches": "\(PerformanceFixtures.importBatchCount(for: itemCount))",
        ]
    ) {
        let imported = try await PerformanceFixtures.importBasicItemsCSV(count: itemCount, in: store)
        #expect(imported == itemCount)
        return ["imported_items": "\(imported)"]
    }
}

@Test func perfListItemsAtScale() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let itemCount = scale.itemCount

    let (store, directory) = try await PerformanceFixtures.makeStore(label: "list-items")
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await PerformanceFixtures.seedBasicItems(count: itemCount, in: store)

    _ = try await PerformanceHarness.measure(
        flow: "list-items",
        metadata: ["item_count": "\(itemCount)"]
    ) {
        let items = try await store.listItems()
        #expect(items.count == itemCount)
        return ["listed_items": "\(items.count)"]
    }
}

@Test func perfFetchDueCardsAtScale() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let itemCount = scale.itemCount

    let (store, directory) = try await PerformanceFixtures.makeStore(label: "fetch-due")
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await PerformanceFixtures.seedBasicItems(count: itemCount, in: store)

    _ = try await PerformanceHarness.measure(
        flow: "fetch-due-cards",
        metadata: ["item_count": "\(itemCount)"]
    ) {
        let due = try await store.fetchDueCards()
        #expect(due.count == itemCount)
        return ["due_cards": "\(due.count)"]
    }
}

@Test func perfStudyGradeLoop() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let libraryCount = scale.itemCount
    let studyCount = scale.studyLoopItemCount

    let (store, directory) = try await PerformanceFixtures.makeStore(label: "study-grade")
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await PerformanceFixtures.seedBasicItems(count: libraryCount, in: store)

    _ = try await PerformanceHarness.measure(
        flow: "study-grade-loop",
        metadata: ["item_count": "\(libraryCount)", "study_count": "\(studyCount)"]
    ) {
        let due = try await store.fetchDueCards()
        var graded = 0
        for entry in due.prefix(studyCount) {
            _ = try await store.submitReview(cardID: entry.card.id, rating: .good)
            graded += 1
        }
        #expect(graded == studyCount)
        return ["graded_cards": "\(graded)"]
    }
}

@Test func perfDeckSwitchCoreQueries() async throws {
    guard let scale = requirePerformanceScale(flow: "deck-switch-core") else { return }
    let itemCount = scale.itemCount
    let deckCount = scale.deckCount
    let switchCount = scale.deckSwitchMeasureCount

    let (store, directory) = try await PerformanceFixtures.makeStore(label: "deck-switch")
    defer { try? FileManager.default.removeItem(at: directory) }
    let decks = try await PerformanceFixtures.seedDecksAtScale(scale, in: store)
    _ = try await PerformanceFixtures.seedBasicItems(count: itemCount, in: store)
    try await PerformanceFixtures.assignItemsRoundRobin(to: decks, in: store)

    let switchTargets = Array(decks.prefix(switchCount))
    let itemsPerDeck = itemCount / max(decks.count, 1)

    _ = try await PerformanceHarness.measure(
        flow: "deck-switch-core",
        metadata: [
            "item_count": "\(itemCount)",
            "deck_count": "\(deckCount)",
            "switch_count": "\(switchCount)",
            "items_per_deck_avg": "\(itemsPerDeck)",
        ]
    ) {
        for deck in switchTargets {
            _ = try await store.loadItemTypes()
            _ = try await store.listItems(
                scope: .deck(deck.id, includeDescendants: true),
                sort: .createdAscending
            )
            _ = try await store.scopeSummary(
                scope: .deck(deck.id, includeDescendants: true)
            )
        }
        return ["switches": "\(switchCount)"]
    }
}

@Test func perfDeckSwitchLeafCore() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let itemCount = scale.itemCount
    let deckCount = scale.deckCount

    let (store, directory) = try await PerformanceFixtures.makeStore(label: "deck-switch-leaf")
    defer { try? FileManager.default.removeItem(at: directory) }
    let decks = try await PerformanceFixtures.seedDecksAtScale(scale, in: store)
    _ = try await PerformanceFixtures.seedBasicItems(count: itemCount, in: store)
    try await PerformanceFixtures.assignItemsRoundRobin(to: decks, in: store)

    let leafDecks = decks.filter { deck in
        !decks.contains(where: { $0.parentID == deck.id })
    }
    guard leafDecks.count >= 2 else { return }
    let deckA = leafDecks[0]
    let deckB = leafDecks[1]
    let itemsPerDeck = itemCount / max(decks.count, 1)

    _ = try await PerformanceHarness.measure(
        flow: "deck-switch-leaf-core",
        metadata: [
            "item_count": "\(itemCount)",
            "deck_count": "\(deckCount)",
            "items_per_deck_avg": "\(itemsPerDeck)",
        ]
    ) {
        for deck in [deckA, deckB, deckA] {
            _ = try await store.loadItemTypes()
            _ = try await store.listItems(
                scope: .deck(deck.id, includeDescendants: true),
                sort: .createdAscending
            )
            _ = try await store.scopeSummary(
                scope: .deck(deck.id, includeDescendants: true)
            )
        }
        return ["switches": "3"]
    }
}

@Test func perfScopeSummaryAtScale() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let itemCount = scale.itemCount

    let (store, directory) = try await PerformanceFixtures.makeStore(label: "scope-summary")
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await PerformanceFixtures.seedBasicItems(count: itemCount, in: store)

    _ = try await PerformanceHarness.measure(
        flow: "scope-summary-all-decks",
        metadata: ["item_count": "\(itemCount)"]
    ) {
        let summary = try await store.scopeSummary(scope: .allDecks)
        #expect(summary.itemCount == itemCount)
        return [
            "total_items": "\(summary.itemCount)",
            "due_now": "\(summary.dueNow)",
        ]
    }
}

@Test func perfDeckSummariesWithNestedDecks() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let deckCount = scale.deckCount
    let itemCount = scale.itemCount

    let (store, directory) = try await PerformanceFixtures.makeStore(label: "deck-summaries")
    defer { try? FileManager.default.removeItem(at: directory) }
    let decks = try await PerformanceFixtures.seedDecksAtScale(scale, in: store)
    _ = try await PerformanceFixtures.seedBasicItems(count: itemCount, in: store)
    if let leafDeck = decks.last {
        let itemType = try await store.defaultItemType()
        _ = try await store.createItem(
            Item(
                itemTypeID: itemType.id,
                fields: [
                    FieldValue(fieldID: itemType.fields[0].id, value: .text("Scoped")),
                    FieldValue(fieldID: itemType.fields[1].id, value: .text("Card")),
                ],
                deckID: leafDeck.id
            )
        )
    }

    _ = try await PerformanceHarness.measure(
        flow: "deck-summaries",
        metadata: ["deck_count": "\(deckCount)", "item_count": "\(itemCount + 1)"]
    ) {
        let summaries = try await store.deckSummaries(asOf: .now)
        #expect(summaries.count >= deckCount)
        return ["deck_summaries": "\(summaries.count)"]
    }
}

@Test func perfItemBrowseFilter() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let itemCount = scale.itemCount

    let (store, directory) = try await PerformanceFixtures.makeStore(label: "browse-filter")
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await PerformanceFixtures.seedBasicItems(count: itemCount, in: store)
    let items = try await store.listItems()

    _ = try await PerformanceHarness.measure(
        flow: "item-browse-filter",
        metadata: ["item_count": "\(itemCount)"]
    ) {
        let filtered = ItemBrowsing.filter(items, search: "Question 1")
        #expect(!filtered.isEmpty)
        return ["matches": "\(filtered.count)"]
    }
}

@Test func perfFSRSOptimizeFromReviewHistory() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let fsrsCount = scale.fsrsLibraryItemCount
    let libraryCount = max(scale.itemCount, fsrsCount)

    let (store, directory) = try await PerformanceFixtures.makeStore(label: "fsrs-optimize")
    defer { try? FileManager.default.removeItem(at: directory) }
    var clock = TestClock(start: Date(timeIntervalSince1970: 1_700_000_000))
    _ = try await PerformanceFixtures.seedBasicItems(
        count: libraryCount,
        in: store,
        now: clock.now()
    )
    let reviewCount = try await PerformanceFixtures.seedFSRSOptimizationHistory(
        in: store,
        cardCount: fsrsCount,
        clock: &clock
    )

    _ = try await PerformanceHarness.measure(
        flow: "fsrs-optimize",
        metadata: [
            "item_count": "\(libraryCount)",
            "fsrs_seed_count": "\(fsrsCount)",
            "review_count": "\(reviewCount)",
        ]
    ) {
        let result = try await store.optimizeScheduling()
        #expect(result.observationCount > 0)
        return [
            "observation_count": "\(result.observationCount)",
            "improved": result.improved ? "true" : "false",
        ]
    }
}

@Test func perfPortableDeckExportImport() async throws {
    guard let scale = requirePerformanceScale() else { return }
    guard scale.includesPortableDeckTransfer else { return }
    let itemCount = scale.itemCount

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("portable-perf-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let sourceRoot = directory.appendingPathComponent("source", isDirectory: true)
    let source = try ItemStore(
        databaseURL: sourceRoot.appendingPathComponent("library.sqlite"),
        mediaStore: MediaStore(rootDirectory: sourceRoot)
    )
    try await source.bootstrap()
    let deck = try await source.createDeck(Deck(name: "Portable Benchmark"))
    _ = try await PerformanceFixtures.seedBasicItems(count: itemCount, in: source)
    try await PerformanceFixtures.assignItems(to: deck.id, in: source)

    let packageURL = directory.appendingPathComponent("benchmark.neodeck")

    let exportMeasurement = try await PerformanceHarness.measure(
        flow: "portable-deck-export",
        metadata: ["item_count": "\(itemCount)"]
    ) {
        try await PortableDeck.export(deckID: deck.id, from: source, to: packageURL)
        let packageBytes = try packageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return ["package_bytes": "\(packageBytes)"]
    }

    let destinationRoot = directory.appendingPathComponent("destination", isDirectory: true)
    let destination = try ItemStore(
        databaseURL: destinationRoot.appendingPathComponent("library.sqlite"),
        mediaStore: MediaStore(rootDirectory: destinationRoot)
    )
    try await destination.bootstrap()

    _ = try await PerformanceHarness.measure(
        flow: "portable-deck-import",
        metadata: [
            "item_count": "\(itemCount)",
            "package_bytes": exportMeasurement.metadata["package_bytes"] ?? "0",
        ]
    ) {
        let result = try await PortableDeck.importDeck(from: packageURL, into: destination)
        #expect(result.itemCount == itemCount)
        return ["imported_items": "\(result.itemCount)"]
    }
}

@Test func perfAuthoredDeckImport() async throws {
    guard requirePerformanceScale() != nil else { return }

    let bundle = PerformanceFixtures.exampleAuthoredDeckURL(name: "Biology")
    guard FileManager.default.fileExists(atPath: bundle.path) else {
        Issue.record("Missing example authored deck at \(bundle.path)")
        return
    }

    let (store, directory) = try await PerformanceFixtures.makeStore(label: "authored-import")
    defer { try? FileManager.default.removeItem(at: directory) }

    _ = try await PerformanceHarness.measure(flow: "authored-deck-import") {
        let result = try await AuthoredDeck.importDeck(from: bundle, into: store)
        #expect(result.itemCount > 0)
        return [
            "imported_items": "\(result.itemCount)",
            "imported_decks": "\(result.deckIDs.count)",
        ]
    }
}

@Test func perfRevertReviewBatch() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let libraryCount = scale.itemCount
    let batchSize = scale.batchSampleSize

    let (store, directory) = try await PerformanceFixtures.makeStore(label: "revert-review")
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await PerformanceFixtures.seedBasicItems(count: libraryCount, in: store)

    _ = try await PerformanceHarness.measure(
        flow: "revert-review-batch",
        metadata: ["item_count": "\(libraryCount)", "batch_size": "\(batchSize)"]
    ) {
        let due = try await store.fetchDueCards()
        var reverted = 0
        for entry in due.prefix(batchSize) {
            let receipt = try await store.submitReviewWithReceipt(
                cardID: entry.card.id,
                rating: .good
            )
            try await store.revertReview(reviewLogID: receipt.reviewLogID)
            reverted += 1
        }
        #expect(reverted == batchSize)
        return ["reverted_reviews": "\(reverted)"]
    }
}

@Test func perfUpdateItemsSample() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let itemCount = scale.itemCount
    let updateCount = scale.batchSampleSize

    let (store, directory) = try await PerformanceFixtures.makeStore(label: "update-items")
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await PerformanceFixtures.seedBasicItems(count: itemCount, in: store)
    let items = try await store.listItems()
    let itemType = try await store.defaultItemType()

    _ = try await PerformanceHarness.measure(
        flow: "update-items-sample",
        metadata: ["item_count": "\(itemCount)", "update_count": "\(updateCount)"]
    ) {
        var updated = 0
        for summary in items.prefix(updateCount) {
            guard let detail = try await store.fetchItem(id: summary.id) else { continue }
            var item = detail.item
            item.fields = [
                FieldValue(fieldID: itemType.fields[0].id, value: .text("Updated \(updated)")),
                FieldValue(fieldID: itemType.fields[1].id, value: .text("Revised \(updated)")),
            ]
            _ = try await store.updateItem(item)
            updated += 1
        }
        return ["updated_items": "\(updated)"]
    }
}

@Test func perfPortableDeckStressImport() async throws {
    guard let scale = requirePerformanceScale(), scale == .stress else { return }

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("portable-stress-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let itemCount = scale.itemCount
    let sourceRoot = directory.appendingPathComponent("source", isDirectory: true)
    let source = try ItemStore(
        databaseURL: sourceRoot.appendingPathComponent("library.sqlite"),
        mediaStore: MediaStore(rootDirectory: sourceRoot)
    )
    try await source.bootstrap()
    let deck = try await source.createDeck(Deck(name: "Stress"))
    _ = try await PerformanceFixtures.seedBasicItems(count: itemCount, in: source)
    try await PerformanceFixtures.assignItems(to: deck.id, in: source)

    let packageURL = directory.appendingPathComponent("stress.neodeck")
    _ = try await PerformanceHarness.measure(
        flow: "portable-deck-export-stress",
        metadata: ["item_count": "\(itemCount)"]
    ) {
        try await PortableDeck.export(deckID: deck.id, from: source, to: packageURL)
        let packageBytes = try packageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return ["package_bytes": "\(packageBytes)"]
    }

    let destinationRoot = directory.appendingPathComponent("destination", isDirectory: true)
    let destination = try ItemStore(
        databaseURL: destinationRoot.appendingPathComponent("library.sqlite"),
        mediaStore: MediaStore(rootDirectory: destinationRoot)
    )
    try await destination.bootstrap()

    let measurement = try await PerformanceHarness.measure(
        flow: "portable-deck-import-stress",
        metadata: ["item_count": "\(itemCount)"]
    ) {
        let result = try await PortableDeck.importDeck(from: packageURL, into: destination)
        #expect(result.itemCount == itemCount)
        return ["imported_items": "\(result.itemCount)"]
    }
    #expect(measurement.durationSeconds < Double(itemCount) / 500.0 + 5.0)
}
