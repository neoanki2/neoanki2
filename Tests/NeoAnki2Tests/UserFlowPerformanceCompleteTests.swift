import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import NeoAnkiTestSupport
import Testing

@testable import NeoAnki2

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

@Test @MainActor func perfRefreshLibraryComposite() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let itemCount = scale.itemCount

    let (store, directory) = try await makeAppStore(label: "refresh-library")
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await PerformanceFixtures.seedDecksAtScale(scale, in: store)
    _ = try await PerformanceFixtures.seedBasicItems(count: itemCount, in: store)

    let decksModel = DecksModel(store: store)
    let itemsModel = ItemsModel(store: store, mediaStore: await store.media)
    await decksModel.load()
    await itemsModel.load()

    _ = try await PerformanceHarness.measure(
        flow: "refresh-library-composite",
        layer: "app",
        metadata: ["item_count": "\(itemCount)", "deck_count": "\(scale.deckCount)"]
    ) {
        let now = Date.now
        await decksModel.load(asOf: now)
        await itemsModel.load(scope: decksModel.studyScope, asOf: now)
        return [:]
    }
}

@Test @MainActor func perfRefreshCountsApp() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let itemCount = scale.itemCount

    let (store, directory) = try await makeAppStore(label: "refresh-counts-app")
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await PerformanceFixtures.seedBasicItems(count: itemCount, in: store)

    let decksModel = DecksModel(store: store)
    let itemsModel = ItemsModel(store: store, mediaStore: await store.media)
    await decksModel.load()
    await itemsModel.load()

    _ = try await PerformanceHarness.measure(
        flow: "refresh-counts-app",
        layer: "app",
        metadata: ["item_count": "\(itemCount)"]
    ) {
        let now = Date.now
        await decksModel.refreshCounts(asOf: now)
        await itemsModel.refreshCounts(asOf: now)
        return [:]
    }
}

@Test @MainActor func perfStudySessionStartScoped() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let itemCount = scale.itemCount

    let (store, directory) = try await makeAppStore(label: "study-start-scoped")
    defer { try? FileManager.default.removeItem(at: directory) }
    let decks = try await PerformanceFixtures.seedDecksAtScale(scale, in: store)
    _ = try await PerformanceFixtures.seedBasicItems(count: itemCount, in: store)
    try await PerformanceFixtures.assignItemsRoundRobin(to: decks, in: store)
    guard let deck = PerformanceFixtures.leafDecks(in: decks).first else { return }

    let model = StudyModel(store: store)

    _ = try await PerformanceHarness.measure(
        flow: "study-session-start-scoped",
        layer: "app",
        metadata: ["item_count": "\(itemCount)", "deck_count": "\(scale.deckCount)"]
    ) {
        await model.startSession(scope: .deck(deck.id, name: deck.name))
        #expect(!model.queue.isEmpty)
        return ["queue_count": "\(model.queue.count)"]
    }
}

@Test @MainActor func perfStudyUndoInSession() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let sampleCount = min(scale.batchSampleSize, 100)

    let (store, directory) = try await makeAppStore(label: "study-undo")
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await PerformanceFixtures.seedBasicItems(count: sampleCount, in: store)

    let model = StudyModel(store: store)
    await model.startSession()

    _ = try await PerformanceHarness.measure(
        flow: "study-undo-in-session",
        layer: "app",
        metadata: ["sample_count": "\(sampleCount)"]
    ) {
        var undos = 0
        for _ in 0..<sampleCount {
            guard model.currentCard != nil else { break }
            model.revealAnswer()
            await model.grade(.good)
            await model.undoLastGrade()
            undos += 1
        }
        return ["undo_count": "\(undos)"]
    }
}

@Test @MainActor func perfItemsModelAddItemBatch() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let createCount = min(scale.batchSampleSize, 50)
    let itemCount = scale.itemCount

    let (store, directory) = try await makeAppStore(label: "add-item")
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await PerformanceFixtures.seedBasicItems(count: itemCount, in: store)

    let model = ItemsModel(store: store, mediaStore: await store.media)
    await model.load()
    let itemType = try await store.defaultItemType()
    let frontID = itemType.fields[0].id
    let backID = itemType.fields[1].id

    _ = try await PerformanceHarness.measure(
        flow: "items-model-add-item-batch",
        layer: "app",
        metadata: ["library_count": "\(itemCount)", "create_count": "\(createCount)"]
    ) {
        for index in 0..<createCount {
            #expect(await model.addItem(fieldSpans: [
                frontID: [Span("Added \(index)")],
                backID: [Span("Reply \(index)")],
            ]))
        }
        return ["created_items": "\(createCount)"]
    }
}

@Test @MainActor func perfItemsModelUpdateItemApp() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let libraryCount = scale.itemCount
    let updateCount = scale.batchSampleSize

    let (store, directory) = try await makeAppStore(label: "update-item-app")
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await PerformanceFixtures.seedBasicItems(count: libraryCount, in: store)

    let model = ItemsModel(store: store, mediaStore: await store.media)
    await model.load()
    let itemType = try await store.defaultItemType()
    let frontID = itemType.fields[0].id
    let backID = itemType.fields[1].id

    _ = try await PerformanceHarness.measure(
        flow: "items-model-update-item-batch",
        layer: "app",
        metadata: ["item_count": "\(libraryCount)", "update_count": "\(updateCount)"]
    ) {
        var updated = 0
        for summary in model.items.prefix(updateCount) {
            #expect(await model.updateItem(
                id: summary.id,
                fieldSpans: [
                    frontID: [Span("Edited \(updated)")],
                    backID: [Span("Revised \(updated)")],
                ]
            ))
            updated += 1
        }
        return ["updated_items": "\(updated)"]
    }
}

@Test @MainActor func perfItemsModelDeleteItemsBatch() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let libraryCount = scale.itemCount
    let deleteCount = scale.batchSampleSize

    let (store, directory) = try await makeAppStore(label: "delete-items-app")
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await PerformanceFixtures.seedBasicItems(count: libraryCount, in: store)

    let model = ItemsModel(store: store, mediaStore: await store.media)
    await model.load()
    let ids = model.items.prefix(deleteCount).map(\.id)

    _ = try await PerformanceHarness.measure(
        flow: "items-model-delete-items-batch",
        layer: "app",
        metadata: ["item_count": "\(libraryCount)", "delete_count": "\(deleteCount)"]
    ) {
        var deleted = 0
        for id in ids {
            #expect(await model.deleteItem(id: id))
            deleted += 1
        }
        return ["deleted_items": "\(deleted)"]
    }
}

@Test @MainActor func perfUnassignedScopeSwitchApp() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let itemCount = scale.itemCount

    let (store, directory) = try await makeAppStore(label: "switch-unassigned-app")
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await PerformanceFixtures.seedBasicItems(count: itemCount, in: store)

    let model = ItemsModel(store: store, mediaStore: await store.media)
    await model.load(scope: .allDecks)

    _ = try await PerformanceHarness.measure(
        flow: "unassigned-scope-switch-app",
        layer: "app",
        metadata: ["item_count": "\(itemCount)"]
    ) {
        await model.load(scope: .unassigned)
        #expect(model.items.count == itemCount)
        return ["unassigned_items": "\(model.items.count)"]
    }
}

@Test @MainActor func perfImportModelCSVImport() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let itemCount = scale.itemCount

    let (store, directory) = try await makeAppStore(label: "import-csv-model")
    defer { try? FileManager.default.removeItem(at: directory) }
    let itemsModel = ItemsModel(store: store, mediaStore: await store.media)
    await itemsModel.load()

    let batchCount = PerformanceFixtures.importBatchCount(for: itemCount)
    var fileURLs: [URL] = []
    var startIndex = 0
    for batch in 0..<batchCount {
        let batchSize = min(itemCount - startIndex, ImportLimits.maxRows)
        let fileURL = directory.appendingPathComponent("import-\(batch).csv")
        try PerformanceFixtures.makeCSVImportPayload(rowCount: batchSize, startIndex: startIndex)
            .write(to: fileURL)
        fileURLs.append(fileURL)
        startIndex += batchSize
    }

    let model = ImportModel(itemsModel: itemsModel)

    _ = try await PerformanceHarness.measure(
        flow: "import-model-csv",
        layer: "app",
        metadata: ["item_count": "\(itemCount)", "import_batches": "\(batchCount)"]
    ) {
        for fileURL in fileURLs {
            #expect(await model.selectFile(fileURL))
            #expect(await model.importSelected(scope: .allDecks))
        }
        return ["loaded_items": "\(itemsModel.items.count)"]
    }
}

@Test @MainActor func perfPortableDeckTransferModelPath() async throws {
    guard let scale = requirePerformanceScale() else { return }
    guard scale.includesPortableDeckTransfer else { return }
    let itemCount = scale.itemCount

    let (store, directory) = try await makeAppStore(label: "portable-model")
    defer { try? FileManager.default.removeItem(at: directory) }
    let deck = try await store.createDeck(Deck(name: "Transfer Model"))
    _ = try await PerformanceFixtures.seedBasicItems(count: itemCount, in: store)
    try await PerformanceFixtures.assignItems(to: deck.id, in: store)

    let transfer = PortableDeckTransferModel(store: store)
    let exportURL = directory.appendingPathComponent("model-transfer.neodeck")

    _ = try await PerformanceHarness.measure(
        flow: "portable-transfer-model-export",
        layer: "app",
        metadata: ["item_count": "\(itemCount)"]
    ) {
        #expect(await transfer.exportDeck(id: deck.id, to: exportURL))
        return [:]
    }

    let importStore = try ItemStore(databaseURL: directory.appendingPathComponent("imported.sqlite"))
    try await importStore.bootstrap()
    let importTransfer = PortableDeckTransferModel(store: importStore)

    _ = try await PerformanceHarness.measure(
        flow: "portable-transfer-model-import",
        layer: "app",
        metadata: ["item_count": "\(itemCount)"]
    ) {
        let result = await importTransfer.importDeck(from: exportURL)
        #expect(result != nil)
        return ["imported_items": "\(result?.itemCount ?? 0)"]
    }
}

@Test @MainActor func perfDeckCRUDApp() async throws {
    guard let scale = requirePerformanceScale() else { return }
    _ = scale

    let (store, directory) = try await makeAppStore(label: "deck-crud-app")
    defer { try? FileManager.default.removeItem(at: directory) }

    let model = DecksModel(store: store)
    await model.load()

    _ = try await PerformanceHarness.measure(
        flow: "deck-crud-app",
        layer: "app"
    ) {
        let created = await model.createDeck(name: "Perf CRUD")
        #expect(created != nil)
        #expect(await model.renameDeck(id: created!.id, name: "Renamed CRUD"))
        #expect(await model.updateNewCardsPerDay(id: created!.id, limit: 15))
        #expect(await model.deleteDeck(id: created!.id))
        return ["operations": "create-rename-limit-delete-reload"]
    }
}

@Test @MainActor func perfStudyChoiceInteractionSession() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let sampleCount = scale.interactionSampleSize

    let (store, directory) = try await makeAppStore(label: "study-choice")
    defer { try? FileManager.default.removeItem(at: directory) }

    var itemType = try await store.defaultItemType()
    itemType.templates[0].interaction = .choose
    _ = try await store.updateItemType(itemType)
    _ = try await PerformanceFixtures.seedBasicItems(count: sampleCount, in: store)

    let model = StudyModel(store: store)
    await model.startSession()

    _ = try await PerformanceHarness.measure(
        flow: "study-choice-interaction-session",
        layer: "app",
        metadata: ["sample_count": "\(sampleCount)"]
    ) {
        var graded = 0
        while let card = model.currentCard, !model.isFinished, graded < sampleCount {
            if let option = StudySupport.choiceOptions(for: card).first {
                model.selectChoice(option)
                model.submitChoice()
            } else {
                model.revealAnswer()
            }
            await model.grade(.good)
            graded += 1
        }
        return ["graded_cards": "\(graded)"]
    }
}

@Test @MainActor func perfPostStudyRefreshLibrary() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let studyCount = min(scale.studyLoopItemCount, 200)

    let (store, directory) = try await makeAppStore(label: "post-study-refresh")
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await PerformanceFixtures.seedBasicItems(count: studyCount, in: store)

    let studyModel = StudyModel(store: store)
    await studyModel.startSession()
    for _ in 0..<studyCount {
        studyModel.revealAnswer()
        await studyModel.grade(.good)
    }

    let decksModel = DecksModel(store: store)
    let itemsModel = ItemsModel(store: store, mediaStore: await store.media)

    _ = try await PerformanceHarness.measure(
        flow: "post-study-refresh-library",
        layer: "app",
        metadata: ["study_count": "\(studyCount)"]
    ) {
        let now = Date.now
        await decksModel.load(asOf: now)
        await itemsModel.load(scope: .allDecks, asOf: now)
        return [:]
    }
}

@Test @MainActor func perfItemTypesFeatureCreateItemType() async throws {
    guard requirePerformanceScale() != nil else { return }

    let (store, directory) = try await makeAppStore(label: "item-type-create")
    defer { try? FileManager.default.removeItem(at: directory) }

    let model = ItemTypesFeatureModel(library: SQLiteLibraryRepository(store: store))
    await model.load()

    _ = try await PerformanceHarness.measure(
        flow: "item-types-feature-create-item-type",
        layer: "app"
    ) {
        model.beginCreatingItemType()
        model.studioDraft?.name = "Perf Type"
        let preparation = try await model.prepareSave()
        let saved = try await model.commitSave(preparation)
        #expect(saved.name == "Perf Type")
        return ["item_type_count": "\(model.itemTypes.count)"]
    }
}

@Test @MainActor func perfMoveItemBetweenDecks() async throws {
    guard let scale = requirePerformanceScale() else { return }
    let sampleCount = min(scale.batchSampleSize, 100)

    let (store, directory) = try await makeAppStore(label: "move-item")
    defer { try? FileManager.default.removeItem(at: directory) }
    let decks = try await PerformanceFixtures.seedDecksAtScale(scale, in: store)
    _ = try await PerformanceFixtures.seedBasicItems(count: sampleCount, in: store)
    guard decks.count >= 2 else { return }
    let targetDeck = decks[1]

    let model = ItemsModel(store: store, mediaStore: await store.media)
    await model.load()

    _ = try await PerformanceHarness.measure(
        flow: "move-item-between-decks",
        layer: "app",
        metadata: ["sample_count": "\(sampleCount)"]
    ) {
        var moved = 0
        for summary in model.items.prefix(sampleCount) {
            #expect(await model.moveItem(id: summary.id, to: targetDeck.id))
            moved += 1
        }
        return ["moved_items": "\(moved)"]
    }
}

@Test @MainActor func perfMultiSubtreeDeckSwitchAppStress() async throws {
    guard let scale = requirePerformanceScale(flow: "multi-subtree-deck-switch-app-stress") else { return }
    guard scale == .stress else { return }
    let itemCount = scale.itemCount
    let switchCount = scale.deckSwitchMeasureCount

    let (store, directory) = try await makeAppStore(label: "multi-subtree-app")
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

    let model = ItemsModel(store: store, mediaStore: await store.media)
    await model.load(scope: .allDecks)

    _ = try await PerformanceHarness.measure(
        flow: "multi-subtree-deck-switch-app-stress",
        layer: "app",
        metadata: [
            "item_count": "\(itemCount)",
            "deck_count": "\(scale.deckCount)",
            "switch_count": "\(switchTargets.count)",
        ]
    ) {
        for deck in switchTargets {
            await model.load(scope: .deck(deck.id, name: deck.name))
        }
        return ["switches": "\(switchTargets.count)"]
    }
}
