import Foundation
import NeoAnkiTestSupport
import Testing
@testable import NeoAnkiCore

/// Opt-in, optimized-build measurements; fixture creation is outside the timer.
@Test func perfForegroundDueCounts() async throws {
    guard let scale = PerformanceScale.require() else { return }
    let (store, root) = try await PerformanceFixtures.makeStore(label: "foreground-due-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let seededAt = now.addingTimeInterval(-30 * 86_400)
    try await store.database.seedDueBenchmarkItems(count: scale.itemCount, asOf: seededAt)
    let decks = try await PerformanceFixtures.seedForestDecks(count: scale.deckCount, depth: 3, in: store)
    var assignments: [UUID: [ItemMoveSelection]] = [:]
    for (index, item) in try await store.listItems().enumerated() {
        assignments[decks[index % decks.count].id, default: []]
            .append(ItemMoveSelection(itemID: item.id, expectedDeckID: nil))
    }
    for (destination, selection) in assignments { _ = try await store.moveItems(selection, to: destination) }
    let reviewed = try await store.fetchDueCards(asOf: seededAt, limit: 64)
    for pass in 0..<3 {
        for card in reviewed {
            _ = try await store.submitReview(cardID: card.id, rating: .again,
                now: seededAt.addingTimeInterval(Double(pass) * 86_400))
        }
    }
    for (index, var deck) in decks.prefix(2).enumerated() {
        deck.newCardsPerDay = index == 0 ? 20 : 10
        _ = try await store.updateDeck(deck)
    }
    for index in 0..<12 {
        _ = try await store.createItem(Item(itemTypeID: BuiltInItemTypes.basicID, fields: [
            .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text("{\"format\":\"neoanki-context-example\",\"target\":{\"language\":\"en\",\"expression\":\"family \(index / 2)\"}}")),
            .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
        ], deckID: index.isMultiple(of: 2) ? nil : decks.last?.id), now: seededAt)
    }
    // Finish the derived-relation rebuild outside steady-state measurements.
    let expected = try await store.dueCount(asOf: now)
    for repetition in 0..<6 {
        _ = try await PerformanceHarness.measure(flow: "foreground-due-existing-availability", metadata: [
            "repetition": "\(repetition)", "warmup": "\(repetition == 0)",
        ]) {
            let availability = try await store.studyAvailability(asOf: now)
            #expect(availability.dueNow == expected)
            return [:]
        }
        _ = try await PerformanceHarness.measure(flow: "foreground-due-existing-home", metadata: [
            "repetition": "\(repetition)", "warmup": "\(repetition == 0)",
        ]) {
            let home = try await store.coldLibraryHomeSnapshot(asOf: now)
            #expect(home.allDecksSummary.dueNow == expected)
            return [:]
        }
    }
    _ = try await PerformanceHarness.measure(flow: "foreground-due-reader-initialization") {
        let snapshot = try await store.dueSnapshot(asOf: now)
        #expect(snapshot.total == expected)
        return [:]
    }
    // Move backward within the same due interval to force real recalculations
    // without adding fixture writes to the timed path. Every card stays due.
    for repetition in 0..<31 {
        let reference = now.addingTimeInterval(-Double(repetition))
        _ = try await PerformanceHarness.measure(flow: "foreground-due-recalculation", metadata: [
            "repetition": "\(repetition)", "warmup": "\(repetition == 0)",
        ]) {
            let snapshot = try await store.dueSnapshot(asOf: reference)
            #expect(snapshot.total == expected)
            #expect(snapshot.calculatedAt == reference, "Each sample must actually recalculate rather than reuse an older cache entry")
            return [:]
        }
        _ = try await PerformanceHarness.measure(flow: "foreground-due-cache-hit", metadata: [
            "repetition": "\(repetition)", "warmup": "\(repetition == 0)",
        ]) {
            let snapshot = try await store.dueSnapshot(asOf: reference)
            #expect(snapshot.total == expected)
            return [:]
        }
    }

    // A practiced library: most schedules are in the future and exactly 32
    // review cards cross their due boundary while the app is backgrounded.
    // Seed coherent persisted schedules directly, outside measurement, rather
    // than performing 100,000 artificial user review transactions.
    let future = MemoryState(stability: 5, difficulty: 5, due: now.addingTimeInterval(86_400),
        lastReview: seededAt, reps: 3, phase: .review)
    try await store.database.execute("UPDATE cards SET memory = ?, phase = 'review', due_at = ?, lapses = 0;",
        bindings: [.blob(try JSONEncoder().encode(future)), .double(future.due.timeIntervalSince1970)])
    for card in reviewed.prefix(32) {
        var due = future
        due.due = now
        try await store.database.updateCardMemory(card.id, memory: due)
    }
    let before = try await store.dueSnapshot(asOf: now.addingTimeInterval(-1))
    #expect(before.total == 0 && before.validUntil == now)
    for repetition in 0..<31 {
        let reference = now.addingTimeInterval(Double(60 - repetition))
        _ = try await PerformanceHarness.measure(flow: "foreground-due-32-review-cards", metadata: [
            "repetition": "\(repetition)", "warmup": "\(repetition == 0)",
        ]) {
            let snapshot = try await store.dueSnapshot(asOf: reference)
            #expect(snapshot.total == 32)
            #expect(snapshot.calculatedAt == reference)
            return [:]
        }
    }
}

private extension SQLiteDatabase {
    /// Fixture setup is not an import benchmark. Batch the real persistence
    /// helpers in one transaction so stress runs do not time 100,000 fsyncs.
    func seedDueBenchmarkItems(count: Int, asOf now: Date) throws {
        let type = BuiltInItemTypes.basic
        let template = type.templates[0]
        try inTransaction {
            for index in 0..<count {
                let item = Item(itemTypeID: type.id, fields: [
                    .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Question \(index)")),
                    .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
                ])
                let card = Card(itemID: item.id, templateID: template.id, skill: template.skill, memory: .new(due: now))
                try insertItemWithCards(item, cards: [card], createdAt: now, updatedAt: now)
            }
        }
    }
}
