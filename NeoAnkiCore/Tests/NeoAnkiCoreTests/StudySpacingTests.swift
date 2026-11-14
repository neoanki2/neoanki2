import Foundation
import Testing
@testable import NeoAnkiCore

private let spacingNow = Date(timeIntervalSince1970: 1_900_000_000)

private func spacingFixture() async throws -> (ItemStore, URL) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("spacing-\(UUID())/library.sqlite")
    let store = try ItemStore(databaseURL: url)
    try await store.bootstrap()
    return (store, url)
}

private func spacingType(in store: ItemStore, name: String = "Context fixture", extra: [FieldDef] = []) async throws -> ItemType {
    let basic = try await store.defaultItemType()
    return try await store.createItemType(ItemType(name: name, fields: basic.fields + extra, templates: basic.templates))
}

private func spacingItem(_ type: ItemType, front: String = "Question", deck: UUID? = nil, extra: [FieldValue] = []) -> Item {
    Item(itemTypeID: type.id, fields: [
        .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text(front)),
        .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
    ] + extra, deckID: deck)
}

private func contextJSON(_ expression: String, language: String = "en", group: UUID = UUID()) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: [
        "format": "neoanki-context-example", "groupID": group.uuidString,
        "target": ["expression": expression, "language": language],
    ]), as: UTF8.self)
}

@Test func variationIsBoundedStableAndPreservesRatingOrder() {
    let scheduler = LearningScheduler()
    var intervals: Set<Date> = []
    for index in 0..<100 {
        let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!
        var dates: [Date] = []
        for rating in [ReviewRating.hard, .good, .easy] {
            let raw = scheduler.schedule(.new(due: spacingNow), rating: rating, now: spacingNow)
            let varied = ReviewIntervalVariation.apply(to: raw, cardID: id, now: spacingNow, maximumIntervalDays: 36_500)
            #expect(varied == ReviewIntervalVariation.apply(to: raw, cardID: id, now: spacingNow, maximumIntervalDays: 36_500))
            #expect(varied.stability == raw.stability && varied.difficulty == raw.difficulty)
            let base = raw.due.timeIntervalSince(spacingNow)
            #expect(varied.due.timeIntervalSince(spacingNow) >= max(1, ceil(base * 0.85)))
            #expect(varied.due.timeIntervalSince(spacingNow) <= floor(base * 1.15))
            dates.append(varied.due)
            if rating == .good { intervals.insert(varied.due) }
        }
        #expect(dates == dates.sorted())
    }
    #expect(intervals.count > 90)
    let repair = scheduler.schedule(.new(), rating: .again, now: spacingNow)
    #expect(ReviewIntervalVariation.apply(to: repair, cardID: UUID(), now: spacingNow, maximumIntervalDays: 1) == repair)
    var capped = scheduler.schedule(.new(), rating: .easy, now: spacingNow)
    capped.due = spacingNow.addingTimeInterval(100 * 86_400)
    let varied = ReviewIntervalVariation.apply(to: capped, cardID: UUID(), now: spacingNow, maximumIntervalDays: 1)
    #expect(varied.due <= spacingNow.addingTimeInterval(86_400))
}

@Test func contextFamiliesCrossBatchesDecksAndRestartAndUndo() async throws {
    let (store, url) = try await spacingFixture()
    let metadata = FieldDef(name: "Context provenance", type: .text)
    let type = try await spacingType(in: store, extra: [metadata])
    let a = try await store.createDeck(Deck(name: "A", newCardsPerDay: 2))
    let b = try await store.createDeck(Deck(name: "B"))
    for (index, expression) in [" Take   Off ", "take off", "unrelated"].enumerated() {
        _ = try await store.createItem(spacingItem(type, deck: index == 1 ? b.id : a.id, extra: [
            .init(fieldID: metadata.id, value: .text(contextJSON(expression))),
        ]), now: spacingNow.addingTimeInterval(Double(index)))
    }
    let now = spacingNow.addingTimeInterval(10)
    let queue = try await store.fetchDueCards(asOf: now)
    #expect(queue.count == 2)
    #expect(try await store.dueCount(asOf: now) == queue.count)
    let first = try #require(queue.first)
    let receipt = try await store.submitReviewWithReceipt(cardID: first.id, rating: .easy, now: now)
    #expect(try await store.fetchDueCards(scope: .deck(b.id, includeDescendants: false), asOf: now).isEmpty)
    let reopened = try ItemStore(databaseURL: url)
    try await reopened.bootstrap()
    #expect(try await reopened.fetchDueCards(scope: .deck(b.id, includeDescendants: false), asOf: now).isEmpty)
    try await store.revertReview(reviewLogID: receipt.reviewLogID, now: now)
    #expect(try await store.fetchDueCards(scope: .deck(b.id, includeDescendants: false), asOf: now).count == 1)
    _ = try await store.submitReview(cardID: first.id, rating: .easy, now: now)
    let tomorrow = StudyDay.nextRollover(after: now, rolloverMinutes: 240)
    #expect(try await store.fetchDueCards(scope: .deck(b.id, includeDescendants: false), asOf: tomorrow).count == 1)
}

@Test func siblingsAreFilteredBeforeDeckCapacityAndLearningRemainsAvailable() async throws {
    let (store, _) = try await spacingFixture()
    let basic = try await store.defaultItemType()
    var second = basic.templates[0]
    second = Template(name: "Reverse", layout: second.layout, components: second.components, interaction: second.interaction, skill: second.skill)
    let type = try await store.createItemType(ItemType(name: "Siblings", fields: basic.fields, templates: basic.templates + [second]))
    let parent = try await store.createDeck(Deck(name: "Parent", newCardsPerDay: 2))
    let child = try await store.createDeck(Deck(name: "Child", parentID: parent.id, newCardsPerDay: 2))
    for index in 0..<3 { _ = try await store.createItem(spacingItem(type, front: "Q\(index)", deck: child.id), now: spacingNow.addingTimeInterval(Double(index))) }
    let now = spacingNow.addingTimeInterval(10)
    let before = try await store.fetchDueCards(asOf: now)
    #expect(before.count == 2)
    #expect(Set(before.map { $0.item.id }).count == 2)
    let first = try #require(before.first)
    _ = try await store.submitReview(cardID: first.id, rating: .again, now: now)
    let after = try await store.fetchDueCards(asOf: now)
    #expect(after.contains { $0.id == first.id && $0.card.memory.phase == .learning })
    #expect(!after.contains { $0.item.id == first.item.id && $0.card.memory.phase == .new })
    #expect(try await store.scopeSummary(scope: .allDecks, asOf: now).dueNow == after.count)
}

@Test func editingContextUpdatesFamilyAndLanguagesStayDistinct() async throws {
    let (store, _) = try await spacingFixture()
    let metadata = FieldDef(name: "Metadata", type: .text)
    let type = try await spacingType(in: store, extra: [metadata])
    let first = spacingItem(type, extra: [.init(fieldID: metadata.id, value: .text(contextJSON("café")))])
    var second = spacingItem(type, extra: [.init(fieldID: metadata.id, value: .text(contextJSON("cafe\u{301}")))])
    _ = try await store.createItem(first, now: spacingNow)
    _ = try await store.createItem(second, now: spacingNow)
    #expect(try await store.fetchDueCards(asOf: spacingNow).count == 1)
    second.fields.removeAll { $0.fieldID == metadata.id }
    second.fields.append(.init(fieldID: metadata.id, value: .text(contextJSON("café", language: "fr"))))
    _ = try await store.updateItem(second, now: spacingNow)
    #expect(try await store.fetchDueCards(asOf: spacingNow).count == 2)
}

@Test func builderDueSubsetsUseSourceOrderWithoutChangingEligibilityOrIntervals() async throws {
    for prose in [false, true] {
        let (store, _) = try await spacingFixture()
        let attribution = FieldDef(name: "Attribution", type: .text)
        let order = FieldDef(name: "Order", type: .text)
        let separator = FieldDef(name: "Separator", type: .text)
        let type = try await spacingType(in: store, name: prose ? "Prose Unit" : "Poem Line", extra: [attribution] + (prose ? [order, separator] : []))
        let deck = try await store.createDeck(Deck(name: "Work"))
        var itemIDs: [UUID] = []
        for index in 0..<9 {
            var item = spacingItem(type, front: index == 0 ? PoemSequenceResolver.openingPrompt : "Line \(index - 1)", deck: deck.id, extra: [
                .init(fieldID: attribution.id, value: .text("A work")),
            ] + (prose ? [.init(fieldID: order.id, value: .text("\(index)"))] : []))
            item.fields[1].value = .text("Line \(index)")
            if !prose && index == 0 { item.tags = [PoemSequenceResolver.openingTag] }
            _ = try await store.createItem(item, now: spacingNow.addingTimeInterval(Double(index)))
            itemIDs.append(item.id)
        }
        let now = spacingNow.addingTimeInterval(100)
        for var card in try await store.cards() {
            let index = itemIDs.firstIndex(of: card.itemID)!
            card.memory = MemoryState(stability: 7, difficulty: 5,
                due: [2, 5, 8].contains(index) ? now.addingTimeInterval(-Double(index)) : now.addingTimeInterval(86_400),
                lastReview: now.addingTimeInterval(-7 * 86_400), reps: 1, phase: .review)
            card.memoryModelVersion = SchedulerPersistenceConstants.memoryModelVersion
            card.memoryParameterSetID = SchedulerPersistenceConstants.populationDefaultParameterSetID
            if index == 2 { card.memory.phase = .new; card.memory.reps = 0; card.memory.lastReview = nil }
            try await store.applySynchronizedCard(card)
        }
        let before = try await store.cards()
        let queue = try await store.fetchDueCards(asOf: now)
        #expect(queue.map { $0.item.id } == [2, 5, 8].map { itemIDs[$0] })
        #expect(queue.allSatisfy { $0.studyRelation?.work != nil })
        #expect(try await store.fetchDueCards(asOf: now, limit: 1).first?.id == queue.first?.id)
        #expect(try await store.dueCount(asOf: now) == 3)
        #expect(try await store.cards() == before)
        let session = try await store.createStudySession(clientID: UUID(), scope: .allDecks, now: now)
        for expected in queue {
            let next = try #require(try await store.reserveNextStudyCard(sessionID: session.id, now: now))
            #expect(next.id == expected.id)
            let raw = LearningScheduler().schedule(next.card.memory, rating: .good, now: now)
            let preview = try #require(try await store.reviewPreviews(cardID: next.id, now: now)[.good])
            #expect(preview == raw)
            let result = try await store.submitReservedReview(sessionID: session.id, cardID: next.id, rating: .good, now: now)
            #expect(result.memory == raw)
        }
        #expect(try await store.reserveNextStudyCard(sessionID: session.id, now: now) == nil)
    }
}

@Test func independentPreviewMatchesSavedVariedSchedule() async throws {
    let (store, _) = try await spacingFixture()
    let type = try await store.defaultItemType()
    _ = try await store.createItem(spacingItem(type), now: spacingNow)
    let card = try #require(try await store.fetchDueCards(asOf: spacingNow).first)
    let details = try await store.reviewPreviewDetails(cardID: card.id, now: spacingNow)
    let preview = try #require(details[.good])
    #expect(preview.intervalPolicyVersion == ReviewIntervalVariation.policyIdentifier)
    let saved = try await store.submitReviewWithReceipt(cardID: card.id, rating: .good, now: spacingNow)
    #expect(saved.memory == preview.memoryAfter)
    let log = try await store.synchronizedReviewRecord(id: saved.reviewLogID)
    #expect(log.log.schedulingAudit?.finalDueAt == saved.memory.due)
}
