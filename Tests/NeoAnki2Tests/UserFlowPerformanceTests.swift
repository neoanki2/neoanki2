import Foundation
import NeoAnkiCore
import NeoAnkiTestSupport
import Testing

@testable import NeoAnki2

// Opt-in ViewModel baseline suite (no UI):
//   NEOANKI_RUN_PERFORMANCE_TESTS=1 ./Scripts/run-performance-tests.sh

private func requirePerformanceScale(flow: String? = nil) -> PerformanceScale? {
    PerformanceScale.require(flow: flow)
}

@MainActor
private func makeAppStore(label: String) async throws -> (store: ItemStore, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-app-perf-\(label)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = try ItemStore(databaseURL: directory.appendingPathComponent("library.sqlite"))
    try await store.bootstrap()
    return (store, directory)
}

@Test @MainActor func perfItemsModelLoadAtScale() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let itemCount = scale.itemCount

    let (store, directory) = try await makeAppStore(label: "items-load")
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await PerformanceFixtures.seedBasicItems(count: itemCount, in: store)

    let model = ItemsModel(store: store, mediaStore: await store.media)

    _ = try await PerformanceHarness.measure(
        flow: "items-model-load",
        layer: "app",
        metadata: ["item_count": "\(itemCount)"]
    ) {
        await model.load()
        #expect(model.items.count == itemCount)
        #expect(model.scopeSummary.itemCount == itemCount)
        return [
            "loaded_items": "\(model.items.count)",
            "due_now": "\(model.scopeSummary.dueNow)",
        ]
    }
}

@Test @MainActor func perfItemsModelSearchRefresh() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let itemCount = scale.itemCount

    let (store, directory) = try await makeAppStore(label: "items-search")
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await PerformanceFixtures.seedBasicItems(count: itemCount, in: store)

    let model = ItemsModel(store: store, mediaStore: await store.media)
    await model.load()

    _ = try await PerformanceHarness.measure(
        flow: "items-model-search",
        layer: "app",
        metadata: ["item_count": "\(itemCount)"]
    ) {
        model.searchText = "Question 42"
        #expect(!model.visibleItems.isEmpty)
        model.searchText = ""
        #expect(model.visibleItems.count == itemCount)
        return ["visible_items": "\(model.visibleItems.count)"]
    }
}

@Test @MainActor func perfDecksModelLoadWithNestedDecks() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let deckCount = scale.deckCount
    let itemCount = scale.itemCount

    let (store, directory) = try await makeAppStore(label: "decks-load")
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await PerformanceFixtures.seedDecksAtScale(scale, in: store)
    _ = try await PerformanceFixtures.seedBasicItems(count: itemCount, in: store)

    let model = DecksModel(store: store)

    _ = try await PerformanceHarness.measure(
        flow: "decks-model-load",
        layer: "app",
        metadata: ["deck_count": "\(deckCount)", "item_count": "\(itemCount)"]
    ) {
        await model.load()
        #expect(model.deckTree.count >= 1)
        return [
            "root_decks": "\(model.deckTree.count)",
            "scope_due_count": "\(model.scopeDueCount)",
        ]
    }
}

@Test @MainActor func perfDeckSwitchItemsModelLoad() async throws {
    guard let scale = requirePerformanceScale(flow: "deck-switch-items-model-load") else { return }
    let itemCount = scale.itemCount
    let deckCount = scale.deckCount
    let switchCount = scale.deckSwitchMeasureCount

    let (store, directory) = try await makeAppStore(label: "deck-switch")
    defer { try? FileManager.default.removeItem(at: directory) }
    let decks = try await PerformanceFixtures.seedDecksAtScale(scale, in: store)
    _ = try await PerformanceFixtures.seedBasicItems(count: itemCount, in: store)
    try await PerformanceFixtures.assignItemsRoundRobin(to: decks, in: store)

    let model = ItemsModel(store: store, mediaStore: await store.media)
    await model.load(scope: .allDecks)

    let switchTargets = Array(decks.prefix(switchCount))
    let itemsPerDeck = itemCount / max(decks.count, 1)

    _ = try await PerformanceHarness.measure(
        flow: "deck-switch-items-model-load",
        layer: "app",
        metadata: [
            "item_count": "\(itemCount)",
            "deck_count": "\(deckCount)",
            "switch_count": "\(switchCount)",
            "items_per_deck_avg": "\(itemsPerDeck)",
        ]
    ) {
        for deck in switchTargets {
            await model.load(scope: .deck(deck.id, name: deck.name))
        }
        return ["switches": "\(switchCount)"]
    }
}

@Test @MainActor func perfStudyModelFullSession() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let libraryCount = scale.itemCount
    let studyCount = scale.studyLoopItemCount

    let (store, directory) = try await makeAppStore(label: "study-session")
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await PerformanceFixtures.seedBasicItems(count: libraryCount, in: store)

    let model = StudyModel(store: store)

    _ = try await PerformanceHarness.measure(
        flow: "study-model-full-session",
        layer: "app",
        metadata: ["item_count": "\(libraryCount)", "study_count": "\(studyCount)"]
    ) {
        await model.startSession()
        #expect(model.queue.count == libraryCount)

        var reviewed = 0
        while !model.isFinished, reviewed < studyCount {
            model.revealAnswer()
            await model.grade(.good)
            reviewed += 1
        }

        #expect(reviewed == studyCount)
        return [
            "reviewed_count": "\(model.reviewedCount)",
            "cards_reviewed": "\(model.reviewedCardIDs.count)",
        ]
    }
}

@Test @MainActor func perfStudyModelTypedInteractionEvaluation() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let libraryCount = scale.itemCount
    let sampleCount = scale.interactionSampleSize

    let (store, directory) = try await makeAppStore(label: "study-typed")
    defer { try? FileManager.default.removeItem(at: directory) }

    var itemType = try await store.defaultItemType()
    itemType.templates[0].interaction = .type
    _ = try await store.updateItemType(itemType)

    _ = try await PerformanceFixtures.seedBasicItems(count: libraryCount, in: store)
    let model = StudyModel(store: store)
    await model.startSession()

    _ = try await PerformanceHarness.measure(
        flow: "study-model-typed-interaction",
        layer: "app",
        metadata: ["item_count": "\(libraryCount)", "sample_count": "\(sampleCount)"]
    ) {
        var evaluations = 0
        while let card = model.currentCard, !model.isFinished, evaluations < sampleCount {
            let accepted = StudySupport.acceptedAnswers(for: card).first ?? ""
            _ = StudySupport.evaluate(accepted, for: card)
            evaluations += 1
            model.revealAnswer()
            await model.grade(.good)
        }
        return ["evaluations": "\(evaluations)"]
    }
}

@Test @MainActor func perfImportModelJSONImport() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let itemCount = scale.itemCount

    let (store, directory) = try await makeAppStore(label: "import-model")
    defer { try? FileManager.default.removeItem(at: directory) }
    let itemsModel = ItemsModel(store: store, mediaStore: await store.media)
    await itemsModel.load()

    let batchCount = PerformanceFixtures.importBatchCount(for: itemCount)
    var fileURLs: [URL] = []
    fileURLs.reserveCapacity(batchCount)
    var startIndex = 0
    for batch in 0..<batchCount {
        let batchSize = min(itemCount - startIndex, ImportLimits.maxRows)
        let fileURL = directory.appendingPathComponent("import-\(batch).json")
        try PerformanceFixtures.makeJSONImportPayload(rowCount: batchSize, startIndex: startIndex)
            .write(to: fileURL)
        fileURLs.append(fileURL)
        startIndex += batchSize
    }

    let model = ImportModel(itemsModel: itemsModel)

    _ = try await PerformanceHarness.measure(
        flow: "import-model-json",
        layer: "app",
        metadata: [
            "item_count": "\(itemCount)",
            "import_batches": "\(batchCount)",
        ]
    ) {
        for fileURL in fileURLs {
            #expect(await model.selectFile(fileURL))
            let imported = await model.importSelected(scope: .allDecks)
            #expect(imported)
        }
        #expect(itemsModel.items.count == itemCount)
        return ["loaded_items": "\(itemsModel.items.count)"]
    }
}

@Test @MainActor func perfSchedulingModelOptimize() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let libraryCount = scale.itemCount
    let fsrsCount = scale.fsrsLibraryItemCount

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-app-perf-scheduling-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = try ItemStore(databaseURL: directory.appendingPathComponent("library.sqlite"))
    try await store.bootstrap()
    var clock = TestClock(start: Date(timeIntervalSince1970: 1_700_000_000))
    _ = try await PerformanceFixtures.seedBasicItems(
        count: libraryCount,
        in: store,
        now: clock.now()
    )
    _ = try await PerformanceFixtures.seedFSRSOptimizationHistory(
        in: store,
        cardCount: fsrsCount,
        clock: &clock
    )

    let model = SchedulingModel(store: store)

    _ = try await PerformanceHarness.measure(
        flow: "scheduling-model-optimize",
        layer: "app",
        metadata: ["item_count": "\(libraryCount)", "fsrs_seed_count": "\(fsrsCount)"]
    ) {
        await model.optimizeIfNeeded()
        // The seeded history warrants a fit, so this measures the fit itself
        // rather than the cheap gate that decides against one.
        let attempt = try #require(await store.lastOptimizationAttempt())
        return ["review_log_count": "\(attempt.reviewLogCount)"]
    }
}

@Test @MainActor func perfTemplatesModelLoad() async throws {
    guard let scale = requirePerformanceScale() else { return }
    _ = scale

    let (store, directory) = try await makeAppStore(label: "templates-load")
    defer { try? FileManager.default.removeItem(at: directory) }

    let model = TemplatesModel(store: store)

    _ = try await PerformanceHarness.measure(
        flow: "templates-model-load",
        layer: "app"
    ) {
        await model.load()
        #expect(!model.itemTypes.isEmpty)
        return ["item_type_count": "\(model.itemTypes.count)"]
    }
}

@Test @MainActor func perfStudySupportInteractionPaths() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let libraryCount = scale.itemCount
    let sampleCount = scale.interactionSampleSize

    let (store, directory) = try await makeAppStore(label: "study-support")
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await PerformanceFixtures.seedBasicItems(count: libraryCount, in: store)
    let due = try await store.fetchDueCards()

    _ = try await PerformanceHarness.measure(
        flow: "study-support-interactions",
        layer: "app",
        metadata: ["item_count": "\(libraryCount)", "sample_count": "\(sampleCount)"]
    ) {
        var choiceCount = 0
        var arrangementCount = 0
        for card in due.prefix(sampleCount) {
            choiceCount += StudySupport.choiceOptions(for: card).count
            if StudySupport.arrangement(for: card) != nil {
                arrangementCount += 1
            }
            _ = StudySupport.evaluate("Answer 0", for: card)
        }
        return [
            "choice_options": "\(choiceCount)",
            "arrangements": "\(arrangementCount)",
        ]
    }
}

@Test @MainActor func perfItemEditorStateBuildAtScale() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let libraryCount = scale.itemCount
    let sampleCount = scale.batchSampleSize

    let (store, directory) = try await makeAppStore(label: "editor-state")
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await PerformanceFixtures.seedBasicItems(count: libraryCount, in: store)
    let itemType = try await store.defaultItemType()
    let summaries = try await store.listItems()

    _ = try await PerformanceHarness.measure(
        flow: "item-editor-state-build",
        layer: "app",
        metadata: ["item_count": "\(libraryCount)", "sample_count": "\(sampleCount)"]
    ) {
        var built = 0
        for summary in summaries.prefix(sampleCount) {
            guard let detail = try await store.fetchItem(id: summary.id) else { continue }
            let snapshot = ItemEditorState.hydrated(from: detail.item, itemType: itemType)
            #expect(ItemEditorState.canSave(snapshot, itemType: itemType))
            built += 1
        }
        return ["editor_states": "\(built)"]
    }
}

@Test @MainActor func perfPortableDeckTransferDirectOperations() async throws {
    guard let scale = requirePerformanceScale() else { return }
    guard scale.includesPortableDeckTransfer else { return }
    let itemCount = scale.itemCount

    let (store, directory) = try await makeAppStore(label: "portable-transfer")
    defer { try? FileManager.default.removeItem(at: directory) }
    let deck = try await store.createDeck(Deck(name: "Transfer"))
    _ = try await PerformanceFixtures.seedBasicItems(count: itemCount, in: store)
    try await PerformanceFixtures.assignItems(to: deck.id, in: store)

    let exportURL = directory.appendingPathComponent("transfer.neodeck")

    _ = try await PerformanceHarness.measure(
        flow: "portable-transfer-export",
        layer: "app",
        metadata: ["item_count": "\(itemCount)"]
    ) {
        try await PortableDeck.export(deckID: deck.id, from: store, to: exportURL)
        return [:]
    }

    let importStore = try ItemStore(
        databaseURL: directory.appendingPathComponent("import.sqlite")
    )
    try await importStore.bootstrap()

    _ = try await PerformanceHarness.measure(
        flow: "portable-transfer-import",
        layer: "app",
        metadata: ["item_count": "\(itemCount)"]
    ) {
        let result = try await PortableDeck.importDeck(from: exportURL, into: importStore)
        #expect(result.itemCount == itemCount)
        return ["imported_items": "\(result.itemCount)"]
    }
}
