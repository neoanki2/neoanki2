import Foundation
import SQLite3
import Testing
@testable import NeoAnkiCore

@Suite struct MaturityProjectionTests {
    @Test func scopedReadsAndJournalUpdatesDoNotReplayUnrelatedCards() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("maturity-projection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(databaseURL: directory.appendingPathComponent("library.sqlite"))
        try await store.bootstrap()
        let rows = (0..<200).map { ["Front": "Question \($0)", "Back": "Answer"] }
        let data = try JSONSerialization.data(withJSONObject: ["itemType": "Basic", "rows": rows])
        let items = try await store.importItemSummaries(from: data, adapter: JSONImportAdapter())
        let cards = try await store.cards()
        let card = try #require(cards.first)
        _ = try await store.cardMaturityStatus(id: card.id)
        #expect(await store.maturityReadStatistics().decodedCards == 1)
        _ = try await store.cardMaturityDetails(itemID: items[0].id)
        #expect(await store.maturityReadStatistics().decodedCards <= 2)
        _ = try await store.scopeSummary()
        let full = await store.maturityReadStatistics()
        #expect(full.aggregateRebuilds == 1)
        var deck = try await store.createDeck(Deck(name: "Before"))
        deck.name = "After"
        _ = try await store.updateDeck(deck)
        _ = try await store.scopeSummary()
        let renamed = await store.maturityReadStatistics()
        #expect(renamed.decodedCards == full.decodedCards)
        #expect(renamed.decodedReviews == full.decodedReviews)
        _ = try await store.submitReview(cardID: card.id, rating: .good)
        _ = try await store.scopeSummary()
        let graded = await store.maturityReadStatistics()
        #expect(graded.aggregateRebuilds == full.aggregateRebuilds)
        #expect(graded.decodedCards == full.decodedCards + 1)
        #expect(graded.decodedReviews == full.decodedReviews + 1)
        try await store.revertReview(reviewLogID: try #require(await store.database.fetchActiveReviewLogs(cardID: card.id).last?.id))
        #expect(try await store.cardMaturityStatus(id: card.id) == .notStarted)
        #expect(await store.maturityReadStatistics().aggregateRebuilds == 1)
    }

    @Test func malformedReviewIsExplicitAndDoesNotPoisonUnrelatedScopedReads() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("maturity-corruption-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try ItemStore(databaseURL: url)
        try await store.bootstrap()
        let data = Data(#"{"itemType":"Basic","rows":[{"Front":"One","Back":"Answer"},{"Front":"Two","Back":"Answer"}]}"#.utf8)
        _ = try await store.importItemSummaries(from: data, adapter: JSONImportAdapter())
        let cards = try await store.cards()
        _ = try await store.submitReview(cardID: cards[0].id, rating: .good)
        _ = try await store.scopeSummary()
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "UPDATE review_logs SET log = '{}' WHERE card_id = '\(cards[0].id.uuidString)';", nil, nil, nil) == SQLITE_OK)
        await #expect(throws: MaturityReadError.self) { try await store.scopeSummary() }
        #expect(try await store.cardMaturityStatus(id: cards[1].id) == .notStarted)
        #expect(try await store.listItems().count == 2)
    }
    @Test func journalGapAndExternalHistoryOriginRebuildConservatively() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("maturity-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try ItemStore(databaseURL: url)
        try await store.bootstrap()
        let data = Data(#"{"itemType":"Basic","rows":[{"Front":"One","Back":"Answer"}]}"#.utf8)
        _ = try await store.importItemSummaries(from: data, adapter: JSONImportAdapter())
        let cardID = try #require(try await store.cards().first?.id)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for day in [0.0, 8, 17] {
            _ = try await store.submitReview(cardID: cardID, rating: .good, now: start.addingTimeInterval(day * 86_400))
        }
        var card = try await store.card(id: cardID)
        card.memory.phase = .review; card.memory.reps = 3; card.memory.stability = 40
        try await store.applySynchronizedCard(card)
        #expect(try await store.scopeSummary().maturity.status == .maintaining)
        for number in 0..<4 { _ = try await store.createDeck(Deck(name: "Deck \(number)")) }
        _ = try await store.pruneLibraryChanges(asOf: .distantFuture, retentionInterval: 0, minimumRetained: 1)
        #expect(try await store.scopeSummary().maturity.status == .maintaining)
        #expect(await store.maturityReadStatistics().aggregateRebuilds == 2)
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let origin = start.addingTimeInterval(8 * 86_400).timeIntervalSince1970
        #expect(sqlite3_exec(db, "UPDATE scheduler_card_history SET history_origin = \(origin) WHERE card_id = '\(cardID.uuidString)';", nil, nil, nil) == SQLITE_OK)
        let globalReviews = try await store.database.fetchActiveReviewLogs()
        let expected = CardMaturityStatus.evaluate(card: card, reviews: globalReviews)
        #expect(expected == .learning)
        #expect(try await store.cardMaturityStatus(id: cardID) == expected)
        #expect(try await store.scopeSummary().maturity.status == .learning)
        #expect(await store.maturityReadStatistics().aggregateRebuilds == 3)
    }

}
