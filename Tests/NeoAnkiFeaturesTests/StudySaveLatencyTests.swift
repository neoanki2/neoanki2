import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import NeoAnkiTestSupport
import Observation
import Testing

private actor ReviewPublicationGate: AppIconBadgePublishing {
    private var shouldSuspend = false
    private var suspended: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private(set) var counts: [Int] = []

    func holdNextPublication() { shouldSuspend = true }
    func publish(_ badge: AppIconBadge) async {
        if shouldSuspend {
            shouldSuspend = false
            await withCheckedContinuation { continuation in
                suspended = continuation
                observer?.resume()
                observer = nil
            }
        }
        counts.append(badge.count)
    }
    func waitUntilHeld() async {
        guard suspended == nil else { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { suspended?.resume(); suspended = nil }
}

private actor ReviewWidgetPublisher: WidgetSnapshotPublishing {
    private(set) var snapshots: [DueWidgetSnapshot] = []
    func publish(_ snapshot: DueWidgetSnapshot) { snapshots.append(snapshot) }
}

@Test @MainActor func editingFromStudyFinishesBeforeDevicePublication() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("edit-save-gate-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
    try await library.bootstrap()
    let item = Item(itemTypeID: BuiltInItemTypes.basicID, fields: [
        .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Before")),
        .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
    ])
    _ = try await library.createItem(item)
    let badge = ReviewPublicationGate()
    let model = LibraryFeatureModel(library: library, badgePublisher: badge)
    await model.bootstrap(startSync: false)
    await model.awaitDevicePublication()
    await model.beginStudy(scope: .allDecks, title: "Editing")
    var edited = item
    edited.fields[0].value = .text("After")
    await badge.holdNextPublication()
    var saveReturned = false
    let save = Task {
        try await model.updateItem(edited)
        saveReturned = true
    }
    await badge.waitUntilHeld()
    while model.lastCommandReceipt == nil {
        await withCheckedContinuation { continuation in
            withObservationTracking { _ = model.lastCommandReceipt } onChange: { continuation.resume() }
        }
    }
    #expect(try await library.item(id: item.id)?.item == edited)
    #expect(saveReturned, "EDITOR_COMMIT_BOUNDARY: a committed card edit must not wait for OS badge publication")
    if saveReturned {
        // A second edit must also commit while the previous device update is
        // suspended. The background refresher coalesces the outstanding work.
        edited.fields[0].value = .text("A later correction")
        try await model.updateItem(edited)
        #expect(try await library.item(id: item.id)?.item == edited)
        #expect(model.activeStudy?.completion.reviews == 0)
    }
    await badge.release()
    try await save.value
    #expect(model.lastCommandReceipt != nil)
    await model.awaitDevicePublication()
}

@Test(arguments: [false, true]) @MainActor
func reviewSavingFinishesBeforeDevicePublication(duringRefresh: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("review-save-gate-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
    try await library.bootstrap()
    let deck = try await library.createDeck(Deck(name: "Study"))
    for index in 0..<3 {
        _ = try await library.createItem(Item(itemTypeID: BuiltInItemTypes.basicID, fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Question \(index)")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
        ], deckID: deck.id))
    }
    let badge = ReviewPublicationGate()
    let widget = ReviewWidgetPublisher()
    let model = LibraryFeatureModel(library: library, widgetPublisher: widget, badgePublisher: badge)
    await model.bootstrap()
    await model.awaitDevicePublication()
    await model.beginStudy(scope: .allDecks, title: "All Decks")
    let study = try #require(model.activeStudy)
    let first = try #require(study.currentCard?.id)
    await badge.holdNextPublication()
    let refresh: Task<Void, Never>? = duringRefresh ? Task { await model.refresh() } : nil
    if duringRefresh { await badge.waitUntilHeld() }
    let grade = Task { await study.grade(.good) }
    if duringRefresh { await grade.value }
    else { await badge.waitUntilHeld() }

    // The durable write and next-card validation have finished. An OS service
    // must not keep the saving spinner active or prevent another grade/undo.
    #expect(try await library.card(id: first).memory.reps == 1)
    #expect(!study.isGrading)
    #expect(!study.isPreparingQueue)
    #expect(study.canUndo)
    #expect(study.completion.reviews == 1)
    #expect(study.currentCard?.id != first)
    await study.grade(.good)
    #expect(study.completion.reviews == 2)
    await study.undoLastGrade()
    #expect(study.completion.reviews == 1)
    #expect(!study.isGrading)

    await badge.release()
    await grade.value
    await refresh?.value
    await model.endStudy()
    await model.awaitReadModels()
    await model.awaitDevicePublication()
    #expect(model.allDecksSummary.dueNow == 2)
    #expect(model.allDecksSummary.cardCount == 3)
    #expect(await badge.counts.last == 2)
    #expect(await widget.snapshots.last?.totalDueCount == 2)
    #expect(await widget.snapshots.last?.decks.first?.dueCount == 2)
    #expect(study.error == nil)
}

@Test @MainActor func perfMobileReviewSavingWithHistory() async throws {
    guard PerformanceScale.current != nil else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("review-save-perf-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // Use the production scheduler, repository, observable model, and device
    // publication path, with history and multiple decks like a used library.
    let store = try ItemStore(databaseURL: root.appendingPathComponent("library.sqlite"))
    try await store.bootstrap()
    let past = Date.now.addingTimeInterval(-730 * 86_400)
    _ = try await PerformanceFixtures.seedBasicItems(count: 1_000, in: store, now: past)
    let decks = try await PerformanceFixtures.seedForestDecks(count: 12, depth: 1, in: store)
    try await PerformanceFixtures.assignItemsRoundRobin(to: decks, in: store)
    let cards = try await store.fetchDueCards(asOf: past)
    for pass in 0..<12 {
        for card in cards {
            _ = try await store.submitReview(cardID: card.id, rating: .again,
                now: past.addingTimeInterval(Double(pass) * 86_400))
        }
    }
    let library = SQLiteLibraryRepository(store: store)
    let badge = ReviewPublicationGate()
    let widget = ReviewWidgetPublisher()
    let model = LibraryFeatureModel(library: library, widgetPublisher: widget, badgePublisher: badge)
    await model.bootstrap()
    await model.awaitDevicePublication()
    await model.beginStudy(scope: .allDecks, title: "All Decks")
    let study = try #require(model.activeStudy)
    for sample in 0..<5 {
        let start = ContinuousClock.now
        await study.grade(.good)
        print("MOBILE_REVIEW_SAVE_SECONDS sample=\(sample) duration=\(start.duration(to: .now))")
        await Task.yield()
    }
    #expect(study.completion.reviews == 5)
    #expect(!study.isGrading)
    #expect(study.error == nil)
    await model.endStudy()
}
