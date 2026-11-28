import Foundation
import Testing
@testable import NeoAnkiCore

@Suite struct LibraryDueSnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func fixture() async throws -> (ItemStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("due-snapshot-\(UUID())")
        let store = try ItemStore(databaseURL: root.appendingPathComponent("library.sqlite"))
        try await store.bootstrap()
        return (store, root)
    }

    private func item(_ title: String, deck: UUID? = nil) -> Item {
        Item(itemTypeID: BuiltInItemTypes.basicID, fields: [
            .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text(title)),
            .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
        ], deckID: deck)
    }

    @Test func matchesHomeAndStudyAcrossScopesLimitsReviewUndoAndRollover() async throws {
        let (store, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var parent = try await store.createDeck(Deck(name: "Parent", newCardsPerDay: 2))
        let child = try await store.createDeck(Deck(name: "Child", parentID: parent.id, newCardsPerDay: 1))
        let outside = try await store.createDeck(Deck(name: "Outside"))
        for (index, deck) in [parent.id, child.id, child.id, outside.id, nil].enumerated() {
            _ = try await store.createItem(item("Question \(index)", deck: deck), now: now)
        }
        _ = try await store.createItem(item("Future", deck: outside.id), now: now.addingTimeInterval(120))
        let scopes: [DeckScope] = [.allDecks, .unassigned, .deck(parent.id),
            .deck(parent.id, includeDescendants: false), .deck(child.id)]
        func parity(_ date: Date) async throws {
            let home = try await store.coldLibraryHomeSnapshot(asOf: date)
            for scope in scopes {
                let snapshot = try await store.dueSnapshot(activeScope: scope, asOf: date)
                let count = try await store.dueCount(scope: scope, asOf: date)
                let availability = try await store.studyAvailability(asOf: date)
                #expect(snapshot.total == home.allDecksSummary.dueNow)
                #expect(snapshot.unassigned == home.unassignedSummary.dueNow)
                #expect(snapshot.count(for: scope) == count)
                #expect(snapshot.nextStudyAt == availability.nextStudyAt)
                #expect(snapshot.decks == Dictionary(uniqueKeysWithValues: home.deckSummaries.map { ($0.id, $0.dueCount) }))
            }
        }
        try await parity(now)
        let card = try #require(try await store.fetchDueCards(asOf: now, limit: 1).first)
        let review = try await store.submitReviewWithReceipt(cardID: card.id, rating: .easy, now: now)
        try await parity(now)
        try await store.revertReview(reviewLogID: review.reviewLogID, now: now)
        try await parity(now)
        parent.newCardsPerDay = 0
        _ = try await store.updateDeck(parent)
        try await parity(now)
        try await parity(StudyDay.nextRollover(after: now, rolloverMinutes: 240))
    }

    @Test func excludesBranchFromAllDecksStudyWithoutHidingItsItemsOrDirectStudy() async throws {
        let (store, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = try await store.createDeck(Deck(name: "Music", newCardsPerDay: 1))
        var practice = try await store.createDeck(Deck(name: "Piano Practice", parentID: parent.id))
        let scales = try await store.createDeck(Deck(name: "Scales", parentID: practice.id))
        let older = now.addingTimeInterval(-60)
        let unrelated = try await store.createItem(item("Unassigned"), now: now)
        let theory = try await store.createItem(item("Theory", deck: parent.id), now: now)
        let exercise = try await store.createItem(item("Scale", deck: scales.id), now: older)
        _ = try await store.createItem(item("Future scale", deck: scales.id), now: now.addingTimeInterval(30))
        #expect(try await store.fetchDueCards(asOf: now).contains { $0.item.id == exercise.id })
        _ = try await store.dueSnapshot(activeScope: .allDecks, asOf: now)

        practice.includeInAllDecksStudy = false
        _ = try await store.updateDeck(practice)

        let all = try await store.fetchDueCards(asOf: now)
        #expect(Set(all.map(\.item.id)) == Set([unrelated.id, theory.id]))
        #expect(try await store.dueCount(asOf: now) == 2)
        #expect(try await store.scopeSummary(asOf: now).dueNow == 2)
        #expect(try await store.scopeSummary(asOf: now).itemCount == 4)
        #expect(try await store.listItems().contains { $0.id == exercise.id })
        let snapshot = try await store.dueSnapshot(activeScope: .allDecks, asOf: now)
        #expect(snapshot.total == 2)
        #expect(snapshot.activeScopeCount == 2)
        #expect(snapshot.decks[scales.id] == 1)
        #expect(snapshot.nextStudyAt == nil)
        #expect(snapshot.validUntil == now.addingTimeInterval(30))
        #expect(try await store.studyAvailability(asOf: now).nextStudyAt == nil)

        let direct = try #require(try await store.fetchDueCards(scope: .deck(practice.id), asOf: now).first)
        #expect(direct.item.id == exercise.id)
        #expect(try await store.isNewStudyCardEligible(cardID: direct.id, scope: .deck(practice.id), asOf: now))
        #expect(try await !store.isNewStudyCardEligible(cardID: direct.id, scope: .allDecks, asOf: now))
        #expect(try await store.dueSnapshot(activeScope: .deck(practice.id), asOf: now).activeScopeCount == 1)

        practice.includeInAllDecksStudy = true
        try await store.applySynchronizedBatch([.deck(practice)])
        #expect(try await store.fetchDueCards(asOf: now).contains { $0.id == direct.id })
        #expect(try await store.deck(id: practice.id).includeInAllDecksStudy)
    }

    @Test func legacyDeckPayloadDefaultsToInclusion() throws {
        let legacy = Data(#"{"id":"DA7888B6-2389-4D9A-B2E6-D9FDD7A164C8","name":"Legacy"}"#.utf8)
        var deck = try JSONDecoder().decode(Deck.self, from: legacy)
        #expect(deck.includeInAllDecksStudy)
        deck.includeInAllDecksStudy = false
        #expect(try JSONDecoder().decode(Deck.self, from: JSONEncoder().encode(deck)) == deck)
    }

    @Test func cachesUntilExactDueBoundaryAndRejectsBackwardClock() async throws {
        let (store, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let due = now.addingTimeInterval(60)
        _ = try await store.createItem(item("Future"), now: due)
        _ = try await store.dueCount(asOf: now)
        let reader = try SQLiteDatabase(path: root.appendingPathComponent("library.sqlite"), createIfMissing: false)
        try await reader.prepareDueReader()
        let first = try await reader.dueSnapshot(activeScope: nil, asOf: now)
        #expect(first.total == 0)
        #expect(first.validUntil == due)
        _ = try await reader.dueSnapshot(activeScope: nil, asOf: due.addingTimeInterval(-0.001))
        #expect(await reader.dueSnapshotReadCount == 1)
        let arrived = try await reader.dueSnapshot(activeScope: nil, asOf: due)
        #expect(arrived.total == 1)
        #expect(await reader.dueSnapshotReadCount == 2)
        let backward = try await reader.dueSnapshot(activeScope: nil, asOf: now)
        #expect(backward.total == 0)
        #expect(await reader.dueSnapshotReadCount == 3)
    }

    @Test func fractionalDueBoundaryUsesTheSameEpochPrecisionAsSQLite() async throws {
        let (store, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        // Date's reference epoch has finer precision here than SQLite's Unix
        // seconds. Persisting this value rounds the deadline upward by one ULP.
        let due = Date(timeIntervalSinceReferenceDate: Double(816_692_800).nextUp.nextUp.nextUp)
        let persisted = Date(timeIntervalSince1970: due.timeIntervalSince1970)
        #expect(due < persisted)
        let deck = try await store.createDeck(Deck(name: "Fractional boundary"))
        _ = try await store.createItem(item("Fractional boundary", deck: deck.id), now: due)
        let earlier = due.addingTimeInterval(-1)
        #expect(try await store.dueCount(asOf: earlier) == 0)
        #expect(try await store.deckSummaries(asOf: earlier).first?.dueCount == 0)
        let before = try await store.dueSnapshot(asOf: earlier)
        #expect(before.total == 0)
        #expect(before.validUntil == persisted)
        let arrived = try await store.dueSnapshot(asOf: due)
        #expect(arrived.total == 1)
        #expect(arrived.calculatedAt == due)
        #expect(try await store.dueCount(asOf: due) == 1)
        #expect(try await store.deckSummaries(asOf: due).first?.dueCount == 1)
    }

    @Test func observesOtherConnectionsWithoutNotificationsAndExpiresAtRollover() async throws {
        let (store, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await store.dueCount(asOf: now)
        let reader = try SQLiteDatabase(path: root.appendingPathComponent("library.sqlite"), createIfMissing: false)
        try await reader.prepareDueReader()
        let first = try await reader.dueSnapshot(activeScope: nil, asOf: now)
        #expect(first.nextStudyAt == nil)
        _ = try await store.createItem(item("External commit"), now: now)
        _ = try await store.dueCount(asOf: now)
        let second = try await reader.dueSnapshot(activeScope: nil, asOf: now)
        #expect(second.total == 1)
        #expect(second.sourceRevision > first.sourceRevision)
        let reads = await reader.dueSnapshotReadCount
        let rollover = StudyDay.nextRollover(after: now, rolloverMinutes: 240)
        #expect(second.validUntil == rollover)
        _ = try await reader.dueSnapshot(activeScope: nil, asOf: rollover)
        #expect(await reader.dueSnapshotReadCount == reads + 1)
        try await store.setStudyDayRolloverMinutes(300)
        let changed = try await reader.dueSnapshot(activeScope: nil, asOf: now)
        #expect(changed.validUntil == StudyDay.nextRollover(after: now, rolloverMinutes: 300))
    }

    @Test func preservesScopeSpecificRepresentativesForRelatedCards() async throws {
        let (store, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = FieldDef(name: "Context provenance", type: .text)
        let basic = BuiltInItemTypes.basic
        let type = try await store.createItemType(ItemType(name: "Related", fields: basic.fields + [metadata], templates: basic.templates))
        let deck = try await store.createDeck(Deck(name: "Deck"))
        for (index, destination) in [deck.id, nil].enumerated() {
            var value = item("Related \(index)", deck: destination)
            value = Item(itemTypeID: type.id, fields: value.fields + [
                .init(fieldID: metadata.id, value: .text("{\"format\":\"neoanki-context-example\",\"target\":{\"language\":\"en\",\"expression\":\"take off\"}}")),
            ], deckID: destination)
            _ = try await store.createItem(value, now: now.addingTimeInterval(Double(index)))
        }
        let date = now.addingTimeInterval(10)
        let snapshot = try await store.dueSnapshot(activeScope: .deck(deck.id), asOf: date)
        #expect(snapshot.total == 1)
        #expect(snapshot.unassigned == 1, "Unassigned has its own family representative, even when the global representative is assigned")
        #expect(snapshot.activeScopeCount == 1)
        let card = try #require(try await store.fetchDueCards(asOf: date, limit: 1).first)
        let review = try await store.submitReviewWithReceipt(cardID: card.id, rating: .easy, now: date)
        let reviewed = try await store.dueSnapshot(activeScope: .deck(deck.id), asOf: date)
        #expect(reviewed.total == 0 && reviewed.unassigned == 0)
        try await store.revertReview(reviewLogID: review.reviewLogID, now: date)
        #expect(try await store.dueSnapshot(asOf: date).total == 1)
    }

    @Test func countsDoNotWaitForThePrimaryDatabaseReadLane() async throws {
        let (store, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await store.createItem(item("Due"), now: now)
        // Prime relations so holding a primary read never holds a derived write.
        _ = try await store.dueCount(asOf: now)
        let held = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let primary = Task {
            try await store.database.countDueCardsSnapshotDiagnostic(asOf: now, studyDay: "2027-01-15") {
                held.continuation.yield(())
                release.wait()
            }
        }
        var iterator = held.stream.makeAsyncIterator()
        await iterator.next()
        // A watchdog only releases a broken implementation so the suite can
        // report failure rather than hang. Success never depends on a delay.
        let watchdog = Task {
            try await Task.sleep(for: .seconds(10))
            release.signal()
            return true
        }
        defer { watchdog.cancel(); release.signal() }
        let snapshot = try await store.dueSnapshot(asOf: now)
        #expect(snapshot.total == 1)
        watchdog.cancel()
        let timedOut = (try? await watchdog.value) ?? false
        #expect(!timedOut, "Availability waited for the held primary connection")
        release.signal()
        _ = try await primary.value
    }

    @Test func cancellationDoesNotPopulateTheCache() async throws {
        let (store, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = try SQLiteDatabase(path: root.appendingPathComponent("library.sqlite"), createIfMissing: false)
        try await reader.prepareDueReader()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await reader.dueSnapshot(activeScope: nil, asOf: now)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await reader.dueSnapshotReadCount == 0)
        #expect(try await store.dueSnapshot(asOf: now).total == 0)
    }

    @Test func calendarAndTimeZoneChangesInvalidateTheCache() {
        let snapshot = LibraryDueSnapshot(total: 0, unassigned: 0, decks: [:], activeScope: nil,
            activeScopeCount: nil, sourceRevision: 0, calculatedAt: now, validUntil: now.addingTimeInterval(60))
        let token = DatabaseCacheToken(localRevision: 1, dataVersion: 1)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let cached = CachedLibraryDueSnapshot(token: token, calendar: calendar, snapshot: snapshot)
        #expect(cached.isValid(token: token, asOf: now, calendar: calendar))
        calendar.timeZone = TimeZone(secondsFromGMT: 3600)!
        #expect(!cached.isValid(token: token, asOf: now, calendar: calendar))
        #expect(!cached.isValid(token: token, asOf: now, calendar: Calendar(identifier: .buddhist)))
    }

    @Test func syncSuspensionAndDeckMovesInvalidateReaderCache() async throws {
        let (store, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = item("Mutable")
        _ = try await store.createItem(original, now: now)
        let deck = try await store.createDeck(Deck(name: "Destination"))
        #expect(try await store.dueSnapshot(asOf: now).unassigned == 1)
        _ = try await store.moveItems([ItemMoveSelection(itemID: original.id, expectedDeckID: nil)], to: deck.id)
        let moved = try await store.dueSnapshot(activeScope: .deck(deck.id), asOf: now)
        #expect(moved.unassigned == 0 && moved.activeScopeCount == 1)
        let card = try #require(try await store.fetchDueCards(asOf: now, limit: 1).first?.card)
        try await store.database.execute("UPDATE cards SET is_suspended = 1 WHERE id = ?;", bindings: [.text(card.id.uuidString)])
        #expect(try await store.dueSnapshot(asOf: now).total == 0)
        try await store.database.execute("UPDATE cards SET is_suspended = 0 WHERE id = ?;", bindings: [.text(card.id.uuidString)])
        #expect(try await store.dueSnapshot(asOf: now).total == 1)
        var remote = card
        remote.memory.due = now.addingTimeInterval(120)
        try await store.applySynchronizedBatch([.card(remote)])
        let synced = try await store.dueSnapshot(asOf: now)
        #expect(synced.total == 0 && synced.validUntil == remote.memory.due)
    }

    @Test func readerCannotWriteAndWriterRemainsUsableAcrossBackupConnections() async throws {
        let (store, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = try SQLiteDatabase(path: root.appendingPathComponent("library.sqlite"), createIfMissing: false)
        try await reader.prepareDueReader()
        await #expect(throws: (any Error).self) {
            try await reader.execute("UPDATE app_metadata SET value = 'forbidden';")
        }
        _ = try await store.createItem(item("Initial"), now: now)
        await #expect(throws: DueProjectionNeedsRefresh.self) {
            try await reader.dueSnapshot(activeScope: nil, asOf: now)
        }
        for index in 0..<8 {
            _ = try await store.dueSnapshot(asOf: now)
            let backup = root.appendingPathComponent("backup-\(index).sqlite")
            try await store.createValidationDatabaseSnapshot(at: backup)
            _ = try await store.createItem(item("After backup \(index)"), now: now)
        }
        #expect(try await store.dueSnapshot(asOf: now).total == 9)
    }

    @Test(arguments: [UInt64(0), 1, 7, 42])
    func optimizedCountsMatchStudyQueuesInMixedLimitedForests(seed: UInt64) async throws {
        let (store, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var random = seed
        func next(_ upper: Int) -> Int {
            random = random &* 6_364_136_223_846_793_005 &+ 1
            return Int((random >> 32) % UInt64(upper))
        }
        var decks: [Deck] = []
        for index in 0..<9 {
            decks.append(try await store.createDeck(Deck(name: "Deck \(index)",
                parentID: index.isMultiple(of: 3) ? nil : decks.last?.id,
                newCardsPerDay: index.isMultiple(of: 2) ? next(4) : nil)))
        }
        for index in 0..<36 {
            let destination = next(10)
            let title = index < 12
                ? "{\"format\":\"neoanki-context-example\",\"target\":{\"language\":\"en\",\"expression\":\"family \(index / 3)\"}}"
                : "Question \(index)"
            _ = try await store.createItem(item(title, deck: destination < decks.count ? decks[destination].id : nil),
                now: now.addingTimeInterval(index.isMultiple(of: 7) ? 120 : -172_800))
        }
        for card in try await store.fetchDueCards(asOf: now, limit: 4) {
            _ = try await store.submitReview(cardID: card.id, rating: next(2) == 0 ? .again : .easy, now: now)
        }
        let scopes: [DeckScope] = [.allDecks, .unassigned] + decks.map { .deck($0.id) }
        for date in [now, now.addingTimeInterval(86_400)] {
            let home = try await store.coldLibraryHomeSnapshot(asOf: date)
            for scope in scopes {
                let snapshot = try await store.dueSnapshot(activeScope: scope, asOf: date)
                let queue = try await store.fetchDueCards(scope: scope, asOf: date)
                #expect(snapshot.count(for: scope) == queue.count)
                #expect(snapshot.total == home.allDecksSummary.dueNow)
                #expect(snapshot.decks == Dictionary(uniqueKeysWithValues: home.deckSummaries.map { ($0.id, $0.dueCount) }))
            }
        }
    }
}
