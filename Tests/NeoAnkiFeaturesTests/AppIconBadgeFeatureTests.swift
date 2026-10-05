import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import Testing

private actor RecordingBadgePublisher: AppIconBadgePublishing {
    var badges: [AppIconBadge] = []
    func publish(_ badge: AppIconBadge) { badges.append(badge) }
}

private actor BadgeOnlyNotificationScheduler: NotificationSchedulingService {
    var requests = 0
    func authorizationStatus() -> NotificationAuthorizationStatus { .authorized }
    func requestAuthorization() -> Bool { requests += 1; return true }
    func replaceDailyReminder(_ request: DailyReminderRequest?) {}
}

@Test @MainActor func mobileBadgeAuthorizationDoesNotSkipReminderAlertPermission() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-mobile-badge-reminder-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
    let notifier = BadgeOnlyNotificationScheduler()
    let model = LibraryFeatureModel(library: library, notifier: notifier)
    await model.bootstrap()
    try await model.setReminderSettings(ReminderSettings(isEnabled: true))
    #expect(await notifier.requests == 1)
    #expect(model.reminderSettings.isEnabled)
    // Changing an already-enabled reminder does not ask again.
    try await model.setReminderSettings(ReminderSettings(isEnabled: true, hour: 8))
    #expect(await notifier.requests == 1)
}

@Test @MainActor func mobileBadgeTracksBootstrapStudyUndoAndDeletionWithRemindersOff() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-mobile-badge-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
    let publisher = RecordingBadgePublisher()
    let model = LibraryFeatureModel(library: library, badgePublisher: publisher)
    await model.bootstrap()
    #expect(await publisher.badges.last?.label == nil)
    #expect(await publisher.badges.last?.count == 0)
    #expect(!model.reminderSettings.isEnabled)
    #expect(!model.syncEnabled)

    let type = try #require(model.itemTypes.first { $0.id == BuiltInItemTypes.basicID })
    try await model.createItem(itemType: type, deckID: nil, values: [
        BuiltInItemTypes.frontFieldID: .text("Question"),
        BuiltInItemTypes.backFieldID: .text("Answer"),
    ])
    #expect(await publisher.badges.last?.label == "1")

    // Reopening a populated library must publish its count on first load.
    let reopened = LibraryFeatureModel(library: library, badgePublisher: publisher)
    await reopened.bootstrap()
    #expect(await publisher.badges.last?.count == 1)
    await model.beginStudy(scope: .allDecks, title: "All Decks")
    let study = try #require(model.activeStudy)
    study.revealAnswer()
    await study.grade(.good)
    #expect(study.error == nil)
    #expect(await publisher.badges.last?.count == 0)
    #expect(await publisher.badges.last?.label == nil)
    await study.undoLastGrade()
    #expect(study.error == nil)
    #expect(await publisher.badges.last?.label == "1")
    await model.endStudy()

    // Advancing time through a refresh brings scheduled cards back to the icon.
    await model.beginStudy(scope: .allDecks, title: "All Decks")
    let nextStudy = try #require(model.activeStudy)
    nextStudy.revealAnswer()
    await nextStudy.grade(.good)
    let cardID = try #require(nextStudy.queue.first?.id)
    let due = try await library.card(id: cardID).memory.due
    await model.refresh(asOf: due.addingTimeInterval(1))
    #expect(await publisher.badges.last?.label == "1")
    try await model.deleteItems(Set(model.items.map(\.id)))
    #expect(await publisher.badges.last?.count == 0)
}

@Test @MainActor func mobileBadgeIsLibraryWideAndHonorsDailyNewCardLimits() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-mobile-badge-scope-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
    let publisher = RecordingBadgePublisher()
    let model = LibraryFeatureModel(library: library, badgePublisher: publisher)
    await model.bootstrap()
    let deck = try await library.createDeck(Deck(name: "Deferred", newCardsPerDay: 0))
    let type = try #require(model.itemTypes.first { $0.id == BuiltInItemTypes.basicID })
    for deckID in [nil, deck.id] {
        try await model.createItem(itemType: type, deckID: deckID, values: [
            BuiltInItemTypes.frontFieldID: .text("Question"),
            BuiltInItemTypes.backFieldID: .text("Answer"),
        ])
    }
    model.selectedScope = .deck(deck.id)
    try await model.reload()
    #expect(model.items.count == 1)
    #expect(model.allDecksSummary.cardCount == 2)
    #expect(model.allDecksSummary.hiddenNewCount == 1)
    #expect(await publisher.badges.last?.label == "1")
    try await model.updateDeck(id: deck.id, name: deck.name, parentID: nil, newCardsPerDay: 1)
    #expect(await publisher.badges.last?.label == "2")
}
