import Foundation
import NeoAnkiCore
import ProseDeckBuilder
import Testing

@Test func proseParsingPreservesMultilingualWordsAndParagraphs() {
    let source = "Dr. Smith arrived. Він сказав: «Привіт!»\r\n\r\n第二段。 Next sentence."
    let units = ProseText.parse(source)
    #expect(ProseText.paragraphCount(in: units) == 2)
    #expect(units.first?.text.hasPrefix("Dr. Smith") == true)
    #expect(units.contains { $0.text.contains("Він сказав") })
    #expect(units.contains { $0.text.contains("第二段") })
    #expect(ProseText.source(from: units).contains("\n\n"))
    #expect(ProseText.source(from: units).contains("«Привіт!»"))
    let chinese = "第一句。第二句。"
    #expect(ProseText.source(from: ProseText.parse(chinese)) == chinese)
    let chineseUnit = ProseUnit(text: "天地玄黃", separator: "")
    #expect(ProseText.split(chineseUnit, afterWord: 2).map {
        ProseText.source(from: [$0.0, $0.1])
    } == chineseUnit.text)
}

@Test func longProseSentenceCanBeSplitAndJoinedWithoutChangingWords() {
    let sentence = (1...90).map { "word\($0)" }.joined(separator: " ")
    var units = ProseText.parse(sentence)
    #expect(units.count > 1)
    #expect(units.allSatisfy { ProseText.wordCount($0.text) <= 45 })
    #expect(ProseText.source(from: units) == sentence)
    let first = units.removeFirst()
    let second = units.removeFirst()
    units.insert(.init(text: first.text + " " + second.text, separator: ""), at: 0)
    #expect(ProseText.source(from: units) == sentence)
    let manual = ProseText.split(units[0], afterWord: 10)
    #expect(manual != nil)
    #expect(manual.map { ProseText.source(from: [$0.0, $0.1]) } == units[0].text)
}

@Test func revisedSourceKeepsManualBreaksInUnchangedParagraphs() {
    var units = ProseText.parse("One long thought remains together.\n\nSecond paragraph changes.")
    let split = ProseText.split(units[0], afterWord: 2)!
    units.replaceSubrange(0...0, with: [split.0, split.1])
    let revised = ProseText.parse(
        "One long thought remains together.\n\nSecond paragraph now changes.",
        preserving: units
    )
    #expect(revised[0].text == "One long")
    #expect(revised[1].text == "thought remains together.")
    #expect(ProseText.paragraphCount(in: revised) == 2)
}

@Test func repeatedProseCuesAreDistinctAndOpeningUnitIsStudied() throws {
    let ordinaryUnits = ProseText.parse("The address begins. Its next thought follows. A third thought arrives.")
    let ordinaryPrompts = ProsePromptPlanner.prompts(for: ordinaryUnits)
    #expect(ordinaryPrompts.count == 3)
    #expect(ordinaryPrompts[2] == ordinaryUnits[1].text)
    let units = ProseText.parse("Start. A. B. C. A. B. D.")
    let prompts = ProsePromptPlanner.prompts(for: units)
    #expect(prompts.count == units.count)
    #expect(prompts[0] == "Begin the passage.")
    #expect(Set(prompts).count == prompts.count)
    let generated = try ProseDeckGenerator.generate(
        input: .init(destinationDeckID: UUID(), title: "Passage", text: "Start. A. B. C. A. B. D.")
    )
    defer { generated.cleanup() }
    #expect(AuthoredDeck.validate(at: generated.bundleURL).isEmpty)
    let lines = try String(
        contentsOf: generated.bundleURL.appendingPathComponent("items/prose.jsonl"),
        encoding: .utf8
    ).split(separator: "\n")
    #expect(lines.count == units.count)
}

@Test func proseChildUsesParentDailyNewCardLimit() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("prose-limit-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ItemStore(databaseURL: directory.appendingPathComponent("library.sqlite"))
    try await store.bootstrap()
    let parent = try await store.createDeck(Deck(name: "Speeches", newCardsPerDay: 2))
    let generated = try ProseDeckGenerator.generate(
        input: .init(
            destinationDeckID: parent.id,
            title: "Address",
            text: "First line. Second line. Third line. Fourth line."
        )
    )
    defer { generated.cleanup() }
    let result = try await AuthoredDeck.importDeck(from: generated.bundleURL, into: store)
    var child = try await store.deck(id: #require(result.deckIDs.first))
    #expect(child.newCardsPerDay == nil)
    child.parentID = parent.id
    _ = try await store.updateDeck(child)
    let due = try await store.fetchDueCards(scope: .deck(parent.id), asOf: .now)
    #expect(due.count == 2)
}

@Test func proseEditPreservesMatchingReviewAndReordersNewCards() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("prose-builder-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ItemStore(databaseURL: directory.appendingPathComponent("library.sqlite"))
    try await store.bootstrap()
    let source = "Alpha starts. Bravo follows. Charlie turns. Delta rests. Echo returns. Foxtrot ends."
    let generated = try ProseDeckGenerator.generate(
        input: .init(destinationDeckID: UUID(), author: "Writer", title: "Passage", text: source)
    )
    defer { generated.cleanup() }
    let result = try await AuthoredDeck.importDeck(from: generated.bundleURL, into: store)
    let deckID = try #require(result.deckIDs.first)
    let summaries = try await store.listItems(scope: .deck(deckID, includeDescendants: false))
    let records = try await summaries.asyncMap { summary -> ProseDeckItemRecord in
        let loaded = try #require(await store.fetchItem(id: summary.id))
        return .init(item: loaded.item, itemType: loaded.itemType)
    }
    let snapshot = try ProseDeckReconciler.snapshot(records: records)
    #expect(snapshot.sourceText == source)
    #expect(snapshot.records.count == 6)
    let initial = try await store.fetchDueCards(asOf: .now)
    let firstCard = try #require(initial.first)
    _ = try await store.submitReview(cardID: firstCard.card.id, rating: .good, now: .now)
    let reviewedMemory = try await store.card(id: firstCard.card.id).memory
    let lastCard = try #require(initial.last)
    _ = try await store.submitReview(cardID: lastCard.card.id, rating: .good, now: .now)
    let lastMemory = try await store.card(id: lastCard.card.id).memory

    let edited = ProseText.parse(
        "Alpha starts. Bravo follows. Charlie turns. New sentence. Delta rests. Echo returns. Foxtrot ends."
    )
    let preview = try ProseDeckReconciler.preview(
        units: edited,
        records: records,
        deckID: deckID
    )
    #expect(preview.addedCount >= 1)
    #expect(preview.retainedCount >= 2)
    #expect(preview.changedPromptCount > 0)
    #expect(preview.newCardIndices.count == preview.addedCount)
    #expect(preview.retiredCards.count == preview.retiredCount)
    _ = try await store.reconcileOrderedDeckItems(preview.operations, order: preview.order)
    #expect(try await store.card(id: firstCard.card.id).memory == reviewedMemory)
    #expect(try await store.card(id: lastCard.card.id).memory == lastMemory)
    let newDue = try await store.fetchDueCards(asOf: .distantFuture)
        .filter { $0.card.memory.phase == .new }
    let newAnswers = newDue.compactMap { due -> String? in
        guard let field = due.itemType.field(named: "Back"),
              case let .text(answer, lang: _) = due.item.value(for: field.id) else { return nil }
        return answer
    }
    #expect(newAnswers == edited.dropFirst().dropLast().map(\.text))

    let refreshed = try await store.listItems(scope: .deck(deckID, includeDescendants: false))
    let finalRecords = try await refreshed.asyncMap { summary -> ProseDeckItemRecord in
        let loaded = try #require(await store.fetchItem(id: summary.id))
        return .init(item: loaded.item, itemType: loaded.itemType)
    }
    #expect(try ProseDeckReconciler.snapshot(records: finalRecords).sourceText ==
        ProseText.source(from: edited))
    let deletePreview = try ProseDeckReconciler.preview(
        units: Array(edited.dropLast()),
        records: finalRecords,
        deckID: deckID
    )
    let invalidOrder = OrderedDeckItemReconciliation(
        deckID: deckID,
        expectedItems: deletePreview.order.expectedItems,
        orderedItemIDs: deletePreview.order.orderedItemIDs + [UUID()]
    )
    await #expect(throws: Error.self) {
        try await store.reconcileOrderedDeckItems(
            deletePreview.operations,
            order: invalidOrder
        )
    }
    #expect(try await store.listItems(scope: .deck(deckID, includeDescendants: false)).count ==
        finalRecords.count)
}

@Test func chapterLengthProseSupportsInsertionAndDeletion() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("prose-chapter-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ItemStore(databaseURL: directory.appendingPathComponent("library.sqlite"))
    try await store.bootstrap()
    let sentences = (0..<360).map {
        "Sentence \($0) gives this chapter a distinct thought to remember and recite."
    }
    let source = sentences.prefix(180).joined(separator: " ") + "\n\n"
        + sentences.suffix(180).joined(separator: " ")
    let generated = try ProseDeckGenerator.generate(
        input: .init(destinationDeckID: UUID(), title: "Chapter", text: source)
    )
    defer { generated.cleanup() }
    let result = try await AuthoredDeck.importDeck(from: generated.bundleURL, into: store)
    let deckID = try #require(result.deckIDs.first)
    #expect(result.itemCount == 360)
    let summaries = try await store.listItems(scope: .deck(deckID, includeDescendants: false))
    let records = try await summaries.asyncMap { summary -> ProseDeckItemRecord in
        let loaded = try #require(await store.fetchItem(id: summary.id))
        return .init(item: loaded.item, itemType: loaded.itemType)
    }
    let original = try ProseDeckReconciler.snapshot(records: records)
    #expect(original.sourceText == source)
    var edited = original.units
    edited.remove(at: 179)
    edited.insert(.init(text: "A new thought enters this chapter.", separator: " "), at: 180)
    let preview = try ProseDeckReconciler.preview(units: edited, records: records, deckID: deckID)
    #expect(preview.addedCount >= 1)
    #expect(preview.retiredCount >= 1)
    _ = try await store.reconcileOrderedDeckItems(preview.operations, order: preview.order)
    let finalSummaries = try await store.listItems(scope: .deck(deckID, includeDescendants: false))
    #expect(finalSummaries.count == 360)
    let finalRecords = try await finalSummaries.asyncMap { summary -> ProseDeckItemRecord in
        let loaded = try #require(await store.fetchItem(id: summary.id))
        return .init(item: loaded.item, itemType: loaded.itemType)
    }
    #expect(try ProseDeckReconciler.snapshot(records: finalRecords).sourceText ==
        ProseText.source(from: edited))
}

private extension Array {
    func asyncMap<Output>(_ transform: (Element) async throws -> Output) async throws -> [Output] {
        var output: [Output] = []
        output.reserveCapacity(count)
        for element in self { try await output.append(transform(element)) }
        return output
    }
}

@Test func singleUnitProseAlreadyHasExactlyOneOpeningCard() throws {
    let units = [ProseUnit(text: "One sentence.", separator: "")]
    #expect(ProsePromptPlanner.prompts(for: units) == ["Begin the passage."])
    let generated = try ProseDeckGenerator.generate(
        input: .init(destinationDeckID: UUID(), title: "One sentence.", text: "One sentence."),
        reviewedUnits: units
    )
    defer { generated.cleanup() }
    let lines = try String(contentsOf: generated.bundleURL.appendingPathComponent("items/prose.jsonl"), encoding: .utf8)
        .split(separator: "\n")
    #expect(lines.count == 1)
    let record = try #require(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
    let fields = try #require(record["fields"] as? [String: [String: String]])
    #expect(fields["back"]?["text"] == "One sentence.")
}
