import Foundation
import NeoAnkiCore
import NeoAnkiTestSupport
import Testing

@testable import NeoAnki2

// One measured user interaction per flow. Library seeded once outside all timings.
// Run: NEOANKI_PERF_SCALE=large ./Scripts/run-interaction-performance.sh

private func requireInteractionScale() -> PerformanceScale? {
    PerformanceScale.require(flow: nil)
}

@MainActor
private func makeInteractionStore(label: String) async throws -> (store: ItemStore, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-interaction-perf-\(label)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = try ItemStore(databaseURL: directory.appendingPathComponent("library.sqlite"))
    try await store.bootstrap()
    return (store, directory)
}

@MainActor
private struct InteractionFixture {
    let store: ItemStore
    let directory: URL
    let scale: PerformanceScale
    let decks: [Deck]
    let itemsModel: ItemsModel
    let decksModel: DecksModel
    let itemType: ItemType
    let sampleItemID: UUID
    let leafDeck: Deck

    static func prepare(scale: PerformanceScale, label: String) async throws -> InteractionFixture {
        let (store, directory) = try await makeInteractionStore(label: label)
        let decks = try await PerformanceFixtures.seedDecksAtScale(scale, in: store)
        _ = try await PerformanceFixtures.seedBasicItems(count: scale.itemCount, in: store)
        try await PerformanceFixtures.assignItemsRoundRobin(to: decks, in: store)
        let itemsModel = ItemsModel(store: store, mediaStore: await store.media)
        let decksModel = DecksModel(store: store)
        await decksModel.load()
        await itemsModel.load(scope: .allDecks)
        let itemType = try await store.defaultItemType()
        let sampleItemID = itemsModel.items[0].id
        let leafDeck = PerformanceFixtures.leafDecks(in: decks).first ?? decks[0]
        return InteractionFixture(
            store: store,
            directory: directory,
            scale: scale,
            decks: decks,
            itemsModel: itemsModel,
            decksModel: decksModel,
            itemType: itemType,
            sampleItemID: sampleItemID,
            leafDeck: leafDeck
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

@Test @MainActor func perfAllUserInteractions() async throws {
    guard let scale = requireInteractionScale() else { return }
    let fixture = try await InteractionFixture.prepare(scale: scale, label: "all-interactions")
    defer { fixture.cleanup() }

    let meta = ["item_count": "\(scale.itemCount)", "interactions": "1"]
    let frontID = fixture.itemType.fields[0].id
    let backID = fixture.itemType.fields[1].id

    let coldStore = try ItemStore(
        databaseURL: fixture.directory.appendingPathComponent("library.sqlite")
    )
    try await coldStore.bootstrap()
    let coldItemsModel = ItemsModel(store: coldStore, mediaStore: await coldStore.media)
    let coldDecksModel = DecksModel(store: coldStore)
    let coldLoad = try await PerformanceHarness.measure(
        flow: "interaction-cold-library-load",
        layer: "app",
        metadata: meta
    ) {
        let now = Date.now
        let snapshot = try await coldStore.coldLibrarySnapshot(scope: .allDecks, asOf: now)
        coldDecksModel.applyColdSnapshot(snapshot)
        coldItemsModel.applyColdSnapshot(snapshot, scope: .allDecks)
        #expect(coldItemsModel.items.count == scale.itemCount)
        #expect(coldDecksModel.summaries.count == scale.deckCount)
        return [:]
    }
    // A first launch reads the browse list, the per-deck counts, and the
    // all-decks and unassigned summaries. Those are separate aggregate scans on
    // one actor, so this budget is deliberately looser than the warm reloads
    // below, which reuse the caches this measurement populates.
    if scale == .large {
        #expect(coldLoad.durationSeconds < 0.3)
    }

    _ = try await PerformanceHarness.measure(
        flow: "interaction-load-scope-home",
        layer: "app",
        metadata: meta
    ) {
        await fixture.itemsModel.load(scope: .allDecks)
        return [:]
    }

    if scale == .large {
        let switchDeck = try await PerformanceHarness.measure(
            flow: "interaction-switch-deck",
            layer: "app",
            metadata: meta.merging(["deck_count": "\(scale.deckCount)"]) { current, _ in current }
        ) {
            await fixture.itemsModel.load(scope: .deck(fixture.leafDeck.id, name: fixture.leafDeck.name))
            return [:]
        }
        #expect(switchDeck.durationSeconds < 0.1)
    } else {
        _ = try await PerformanceHarness.measure(
            flow: "interaction-switch-deck",
            layer: "app",
            metadata: meta.merging(["deck_count": "\(scale.deckCount)"]) { current, _ in current }
        ) {
            await fixture.itemsModel.load(scope: .deck(fixture.leafDeck.id, name: fixture.leafDeck.name))
            return [:]
        }
    }

    _ = try await PerformanceHarness.measure(
        flow: "interaction-switch-unassigned",
        layer: "app",
        metadata: meta
    ) {
        await fixture.itemsModel.load(scope: .unassigned)
        return [:]
    }

    _ = try await PerformanceHarness.measure(
        flow: "interaction-search",
        layer: "app",
        metadata: meta
    ) {
        fixture.itemsModel.searchText = "Question 42"
        await fixture.itemsModel.waitForPendingSearch()
        _ = fixture.itemsModel.visibleItems
        fixture.itemsModel.searchText = ""
        _ = fixture.itemsModel.visibleItems
        return [:]
    }

    let studyModel = StudyModel(store: fixture.store)

    _ = try await PerformanceHarness.measure(
        flow: "interaction-start-study",
        layer: "app",
        metadata: meta
    ) {
        await studyModel.startSession(scope: .deck(fixture.leafDeck.id, name: fixture.leafDeck.name))
        return ["queue_count": "\(studyModel.queue.count)"]
    }

    _ = try await PerformanceHarness.measure(
        flow: "interaction-grade-one-card",
        layer: "app",
        metadata: meta
    ) {
        studyModel.revealAnswer()
        await studyModel.grade(.good)
        return [:]
    }

    if scale == .large {
        let studiedItemIDs = studyModel.reviewedItemIDs
        let afterStudy = try await PerformanceHarness.measure(
            flow: "interaction-refresh-after-study",
            layer: "app",
            metadata: meta
        ) {
            let now = Date.now
            await fixture.decksModel.refreshCounts(asOf: now)
            await fixture.itemsModel.refreshSchedules(for: studiedItemIDs, asOf: now)
            // Ending a session now also considers refitting, so the budget has
            // to cover the gate that decides against it.
            await SchedulingModel(store: fixture.store).optimizeIfNeeded()
            return [:]
        }
        #expect(afterStudy.durationSeconds < 0.15)
    } else {
        let studiedItemIDs = studyModel.reviewedItemIDs
        _ = try await PerformanceHarness.measure(
            flow: "interaction-refresh-after-study",
            layer: "app",
            metadata: meta
        ) {
            let now = Date.now
            await fixture.decksModel.refreshCounts(asOf: now)
            await fixture.itemsModel.refreshSchedules(for: studiedItemIDs, asOf: now)
            // Ending a session now also considers refitting, so the budget has
            // to cover the gate that decides against it.
            await SchedulingModel(store: fixture.store).optimizeIfNeeded()
            return [:]
        }
    }

    _ = try await PerformanceHarness.measure(
        flow: "interaction-undo-one-grade",
        layer: "app",
        metadata: meta
    ) {
        await studyModel.undoLastGrade()
        return [:]
    }

    _ = try await PerformanceHarness.measure(
        flow: "interaction-open-item-detail",
        layer: "app",
        metadata: meta
    ) {
        let item = try await fixture.store.fetchItem(id: fixture.sampleItemID)
        #expect(item != nil)
        return [:]
    }

    _ = try await PerformanceHarness.measure(
        flow: "interaction-add-one-item",
        layer: "app",
        metadata: meta
    ) {
        #expect(await fixture.itemsModel.addItem(fieldSpans: [
            frontID: [Span("New question")],
            backID: [Span("New answer")],
        ], deckID: fixture.leafDeck.id))
        return [:]
    }

    _ = try await PerformanceHarness.measure(
        flow: "interaction-update-one-item",
        layer: "app",
        metadata: meta
    ) {
        #expect(await fixture.itemsModel.updateItem(
            id: fixture.sampleItemID,
            fieldSpans: [
                frontID: [Span("Edited question")],
                backID: [Span("Edited answer")],
            ]
        ))
        return [:]
    }

    let deleteID = fixture.itemsModel.items.last!.id
    _ = try await PerformanceHarness.measure(
        flow: "interaction-delete-one-item",
        layer: "app",
        metadata: meta
    ) {
        #expect(await fixture.itemsModel.deleteItem(id: deleteID))
        return [:]
    }

    if fixture.decks.count >= 2 {
        let targetDeck = fixture.decks[1]
        _ = try await PerformanceHarness.measure(
            flow: "interaction-move-one-item",
            layer: "app",
            metadata: meta
        ) {
            #expect(await fixture.itemsModel.moveItem(id: fixture.sampleItemID, to: targetDeck.id))
            return [:]
        }
    }

    _ = try await PerformanceHarness.measure(
        flow: "interaction-refresh-counts",
        layer: "app",
        metadata: meta
    ) {
        let now = Date.now
        await fixture.decksModel.refreshCounts(asOf: now)
        await fixture.itemsModel.refreshCounts(asOf: now)
        return [:]
    }

    let refreshLibrary = try await PerformanceHarness.measure(
        flow: "interaction-refresh-library",
        layer: "app",
        metadata: meta
    ) {
        let now = Date.now
        await fixture.decksModel.refreshCounts(asOf: now)
        await fixture.itemsModel.load(scope: fixture.decksModel.studyScope, asOf: now)
        return [:]
    }
    if scale == .large {
        #expect(refreshLibrary.durationSeconds < 0.1)
    }

    let batchSize = min(scale.itemCount, ImportLimits.maxRows)
    let fileURL = fixture.directory.appendingPathComponent("one-import.json")
    try PerformanceFixtures.makeJSONImportPayload(rowCount: batchSize, startIndex: scale.itemCount)
        .write(to: fileURL)
    let importModel = ImportModel(itemsModel: fixture.itemsModel)

    _ = try await PerformanceHarness.measure(
        flow: "interaction-import-one-json-file",
        layer: "app",
        metadata: [
            "library_item_count": "\(scale.itemCount)",
            "import_rows": "\(batchSize)",
            "interactions": "1",
        ]
    ) {
        #expect(await importModel.selectFile(fileURL))
        #expect(await importModel.importSelected(scope: .allDecks))
        return [:]
    }

    var clock = TestClock(start: Date(timeIntervalSince1970: 1_700_000_000))
    _ = try await PerformanceFixtures.seedFSRSOptimizationHistory(
        in: fixture.store,
        cardCount: min(scale.fsrsLibraryItemCount, 100),
        clock: &clock
    )
    let schedulingModel = SchedulingModel(store: fixture.store)

    _ = try await PerformanceHarness.measure(
        flow: "interaction-optimize-scheduling",
        layer: "app",
        metadata: meta
    ) {
        await schedulingModel.optimizeIfNeeded()
        return [:]
    }

    _ = try await PerformanceHarness.measure(
        flow: "interaction-create-deck",
        layer: "app",
        metadata: meta
    ) {
        #expect(await fixture.decksModel.createDeck(name: "New perf deck") != nil)
        return [:]
    }

    if scale.includesPortableDeckTransfer {
        let exportURL = fixture.directory.appendingPathComponent("export.neodeck")
        let transfer = PortableDeckTransferModel(store: fixture.store)

        _ = try await PerformanceHarness.measure(
            flow: "interaction-portable-export-deck",
            layer: "app",
            metadata: [
                "library_item_count": "\(scale.itemCount)",
                "interactions": "1",
            ]
        ) {
            #expect(await transfer.exportDeck(id: fixture.leafDeck.id, to: exportURL))
            return [:]
        }

        let importStore = try ItemStore(databaseURL: fixture.directory.appendingPathComponent("dest.sqlite"))
        try await importStore.bootstrap()
        let importTransfer = PortableDeckTransferModel(store: importStore)

        _ = try await PerformanceHarness.measure(
            flow: "interaction-portable-import-deck",
            layer: "app",
            metadata: ["interactions": "1"]
        ) {
            let result = await importTransfer.importDeck(from: exportURL)
            #expect(result != nil)
            return ["imported_items": "\(result?.itemCount ?? 0)"]
        }
    }
}
