import Foundation
import NeoAnkiCore
import NeoAnkiTestSupport
import Testing

private func requirePerformanceScale(flow: String? = nil) -> PerformanceScale? {
    PerformanceScale.require(flow: flow)
}

@Test func perfFetchDueCardsScoped() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let itemCount = scale.itemCount

    let (store, directory) = try await PerformanceFixtures.makeStore(label: "fetch-due-scoped")
    defer { try? FileManager.default.removeItem(at: directory) }
    let decks = try await PerformanceFixtures.seedDecksAtScale(scale, in: store)
    _ = try await PerformanceFixtures.seedBasicItems(count: itemCount, in: store)
    try await PerformanceFixtures.assignItemsRoundRobin(to: decks, in: store)
    guard let deck = PerformanceFixtures.leafDecks(in: decks).first else { return }

    _ = try await PerformanceHarness.measure(
        flow: "fetch-due-cards-scoped",
        metadata: ["item_count": "\(itemCount)", "deck_count": "\(scale.deckCount)"]
    ) {
        let due = try await store.fetchDueCards(scope: .deck(deck.id, includeDescendants: true))
        #expect(!due.isEmpty)
        return ["due_cards": "\(due.count)"]
    }
}

@Test func perfScopeSummaryUnassigned() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let itemCount = min(scale.itemCount, 500)

    let (store, directory) = try await PerformanceFixtures.makeStore(label: "scope-unassigned")
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await PerformanceFixtures.seedBasicItems(count: itemCount, in: store)

    _ = try await PerformanceHarness.measure(
        flow: "scope-summary-unassigned",
        metadata: ["unassigned_items": "\(itemCount)"]
    ) {
        let summary = try await store.scopeSummary(scope: .unassigned)
        #expect(summary.itemCount == itemCount)
        return ["total_items": "\(summary.itemCount)", "due_now": "\(summary.dueNow)"]
    }
}

@Test func perfUnassignedScopeSwitchCore() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let itemCount = scale.itemCount

    let (store, directory) = try await PerformanceFixtures.makeStore(label: "switch-unassigned")
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await PerformanceFixtures.seedBasicItems(count: itemCount, in: store)

    _ = try await PerformanceHarness.measure(
        flow: "unassigned-scope-switch-core",
        metadata: ["item_count": "\(itemCount)"]
    ) {
        _ = try await store.loadItemTypes()
        _ = try await store.listItems(scope: .unassigned, sort: .createdAscending)
        _ = try await store.scopeSummary(scope: .unassigned)
        return [:]
    }
}

@Test func perfFetchItemDetailBatch() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let itemCount = scale.itemCount
    let sampleCount = scale.batchSampleSize

    let (store, directory) = try await PerformanceFixtures.makeStore(label: "fetch-item")
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await PerformanceFixtures.seedBasicItems(count: itemCount, in: store)
    let summaries = try await store.listItems()

    _ = try await PerformanceHarness.measure(
        flow: "fetch-item-detail-batch",
        metadata: ["item_count": "\(itemCount)", "sample_count": "\(sampleCount)"]
    ) {
        var fetched = 0
        for summary in summaries.prefix(sampleCount) {
            let detail = try await store.fetchItem(id: summary.id)
            if detail != nil { fetched += 1 }
        }
        #expect(fetched == sampleCount)
        return ["fetched_items": "\(fetched)"]
    }
}

@Test func perfCreateItemCore() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let createCount = min(scale.batchSampleSize, 50)

    let (store, directory) = try await PerformanceFixtures.makeStore(label: "create-item")
    defer { try? FileManager.default.removeItem(at: directory) }
    let itemType = try await store.defaultItemType()

    _ = try await PerformanceHarness.measure(
        flow: "create-item-core",
        metadata: ["create_count": "\(createCount)"]
    ) {
        for index in 0..<createCount {
            _ = try await store.createItem(
                Item(
                    itemTypeID: itemType.id,
                    fields: [
                        FieldValue(fieldID: itemType.fields[0].id, value: .text("New \(index)")),
                        FieldValue(fieldID: itemType.fields[1].id, value: .text("Answer \(index)")),
                    ]
                )
            )
        }
        return ["created_items": "\(createCount)"]
    }
}

@Test func perfDeleteItemsSample() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let libraryCount = scale.itemCount
    let deleteCount = scale.batchSampleSize

    let (store, directory) = try await PerformanceFixtures.makeStore(label: "delete-items")
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await PerformanceFixtures.seedBasicItems(count: libraryCount, in: store)
    let summaries = try await store.listItems()

    _ = try await PerformanceHarness.measure(
        flow: "delete-items-sample",
        metadata: ["item_count": "\(libraryCount)", "delete_count": "\(deleteCount)"]
    ) {
        var deleted = 0
        for summary in summaries.prefix(deleteCount) {
            if try await store.deleteItem(id: summary.id) {
                deleted += 1
            }
        }
        #expect(deleted == deleteCount)
        return ["deleted_items": "\(deleted)"]
    }
}

@Test func perfDeckCRUDCore() async throws {
    guard let scale = requirePerformanceScale() else { return }
    _ = scale

    let (store, directory) = try await PerformanceFixtures.makeStore(label: "deck-crud")
    defer { try? FileManager.default.removeItem(at: directory) }

    _ = try await PerformanceHarness.measure(flow: "deck-crud-core") {
        let created = try await store.createDeck(Deck(name: "Perf Deck"))
        var deck = try await store.deck(id: created.id)
        deck.name = "Renamed Perf Deck"
        deck.newCardsPerDay = 20
        _ = try await store.updateDeck(deck)
        #expect(try await store.deleteDeck(id: created.id))
        return ["operations": "create-rename-limit-delete"]
    }
}

@Test func perfRefreshCountsCore() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let itemCount = scale.itemCount

    let (store, directory) = try await PerformanceFixtures.makeStore(label: "refresh-counts")
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await PerformanceFixtures.seedBasicItems(count: itemCount, in: store)

    _ = try await PerformanceHarness.measure(
        flow: "refresh-counts-core",
        metadata: ["item_count": "\(itemCount)"]
    ) {
        _ = try await store.deckSummaries(asOf: .now)
        _ = try await store.dueCount(scope: .allDecks, asOf: .now)
        _ = try await store.unassignedDueCount(asOf: .now)
        _ = try await store.unassignedItemCount()
        _ = try await store.scopeSummary(scope: .allDecks, asOf: .now)
        return [:]
    }
}

@Test func perfMultiSubtreeDeckSwitchStress() async throws {
    guard let scale = requirePerformanceScale(flow: "multi-subtree-deck-switch-stress") else { return }
    guard scale == .stress else { return }
    let itemCount = scale.itemCount
    let switchCount = scale.deckSwitchMeasureCount

    let (store, directory) = try await PerformanceFixtures.makeStore(label: "multi-subtree-switch")
    defer { try? FileManager.default.removeItem(at: directory) }
    let decks = try await PerformanceFixtures.seedForestDecks(
        count: scale.deckCount,
        depth: scale.nestedDeckDepth,
        in: store
    )
    _ = try await PerformanceFixtures.seedBasicItems(count: itemCount, in: store)
    try await PerformanceFixtures.assignItemsRoundRobin(to: decks, in: store)

    let roots = PerformanceFixtures.subtreeRootDecks(in: decks, depth: scale.nestedDeckDepth)
    let switchTargets = Array(roots.prefix(switchCount))

    _ = try await PerformanceHarness.measure(
        flow: "multi-subtree-deck-switch-stress",
        metadata: [
            "item_count": "\(itemCount)",
            "deck_count": "\(scale.deckCount)",
            "subtree_count": "\(scale.deckSubtreeCount)",
            "switch_count": "\(switchCount)",
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
        return ["switches": "\(switchTargets.count)"]
    }
}

@Test func perfMultiDeckPortableExportStress() async throws {
    guard let scale = requirePerformanceScale(flow: "multi-deck-portable-export-stress") else { return }
    guard scale == .stress else { return }
    let itemCount = scale.itemCount
    let exportCount = min(5, scale.deckSubtreeCount)

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("multi-portable-stress-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let sourceRoot = directory.appendingPathComponent("source", isDirectory: true)
    let source = try ItemStore(
        databaseURL: sourceRoot.appendingPathComponent("library.sqlite"),
        mediaStore: MediaStore(rootDirectory: sourceRoot)
    )
    try await source.bootstrap()
    let decks = try await PerformanceFixtures.seedForestDecks(
        count: scale.deckCount,
        depth: scale.nestedDeckDepth,
        in: source
    )
    _ = try await PerformanceFixtures.seedBasicItems(count: itemCount, in: source)
    try await PerformanceFixtures.assignItemsRoundRobin(to: decks, in: source)

    let roots = PerformanceFixtures.subtreeRootDecks(in: decks, depth: scale.nestedDeckDepth)
    let exportTargets = Array(roots.prefix(exportCount))

    _ = try await PerformanceHarness.measure(
        flow: "multi-deck-portable-export-stress",
        metadata: [
            "item_count": "\(itemCount)",
            "deck_count": "\(scale.deckCount)",
            "export_count": "\(exportTargets.count)",
        ]
    ) {
        for (index, deck) in exportTargets.enumerated() {
            let packageURL = directory.appendingPathComponent("branch-\(index).neodeck")
            try await PortableDeck.export(deckID: deck.id, from: source, to: packageURL)
        }
        return ["exported_decks": "\(exportTargets.count)"]
    }
}
