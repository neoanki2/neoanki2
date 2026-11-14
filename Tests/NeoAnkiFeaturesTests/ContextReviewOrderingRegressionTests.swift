import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import Testing
@testable import NeoAnkiFeatures

@Suite struct ContextReviewOrderingRegressionTests {
    @Test func relatedContextInterleavingDoesNotPostponeInterveningRepairCards() throws {
        let group = UUID()
        var queue = try [example(group: group), example(group: group, phase: .review), example(phase: .learning), example(group: UUID(), phase: .review), example(phase: .relearning)]
        let original = queue
        ContextReviewOrdering.separateRelatedContexts(in: &queue, at: 1)
        #expect(queue.map(\.id) == [original[0].id, original[3].id, original[2].id, original[1].id, original[4].id])
        #expect(Dictionary(uniqueKeysWithValues: queue.map { ($0.id, $0.card.memory) }) == Dictionary(uniqueKeysWithValues: original.map { ($0.id, $0.card.memory) }))
    }

    @Test func aCurrentRepairCardIsNeverReplacedByAnUnrelatedContext() throws {
        let group = UUID()
        var queue = try [example(group: group), example(group: group, phase: .learning), example(group: UUID())]
        let original = queue
        ContextReviewOrdering.separateRelatedContexts(in: &queue, at: 1)
        #expect(queue == original)
    }

    @Test func anUnrelatedNewCardCannotJumpAheadOfAPendingReview() throws {
        let group = UUID()
        var queue = try [example(group: group, phase: .review), example(group: group, phase: .review), example(group: UUID(), phase: .new)]
        let original = queue
        ContextReviewOrdering.separateRelatedContexts(in: &queue, at: 1)
        #expect(queue == original)
    }

    @Test func aSkippedReviewCannotReplaceANewCardAndChangeThePhaseOrder() throws {
        let group = UUID()
        var queue = try [example(group: group), example(group: group), example(phase: .learning), example(group: UUID(), phase: .review)]
        let original = queue
        ContextReviewOrdering.separateRelatedContexts(in: &queue, at: 1)
        #expect(queue == original)
    }

    @Test func samePhaseAlternativesStillSeparateContextsWithoutChangingPhaseSlots() throws {
        for phase in [Phase.new, .review] {
            let group = UUID()
            var queue = try [example(group: group, phase: phase), example(group: group, phase: phase),
                             example(phase: .learning), example(group: UUID(), phase: phase), example(phase: .relearning)]
            let original = queue
            ContextReviewOrdering.separateRelatedContexts(in: &queue, at: 1)
            #expect(queue[1].id == original[3].id)
            #expect(queue[3].id == original[1].id)
            #expect(queue.map { $0.card.memory.phase } == original.map { $0.card.memory.phase })
            #expect(Dictionary(uniqueKeysWithValues: queue.map { ($0.id, $0.card.memory) }) == Dictionary(uniqueKeysWithValues: original.map { ($0.id, $0.card.memory) }))
        }
    }

    @Test func fiveInterveningCardsArePreferredAndSmallQueuesStillDrain() throws {
        let group = UUID()
        var queue = try [example(group: group), example(group: group)] + (0..<5).map { _ in try example(group: UUID()) }
        let related = queue[1].id
        for index in 1..<queue.count { ContextReviewOrdering.separateRelatedContexts(in: &queue, at: index) }
        #expect(queue.last?.id == related)
        var small = try [example(group: group), example(group: group)]
        let before = small
        ContextReviewOrdering.separateRelatedContexts(in: &small, at: 1)
        #expect(small == before)
    }

    @Test func worksStayInTheirSlotsAndSortAcrossPhases() throws {
        var first = try example(phase: .new)
        var last = try example(phase: .review)
        first.studyRelation = .init(family: "first", work: "poem", ordinal: 2)
        last.studyRelation = .init(family: "last", work: "poem", ordinal: 8)
        let unrelated = try example(group: UUID())
        var queue = [last, unrelated, first]
        StudyQueueOrdering.orderWorks(in: &queue)
        #expect(queue.map(\.id) == [first.id, unrelated.id, last.id])
        let ordered = queue
        StudyQueueOrdering.separateRelated(in: &queue, at: 2)
        #expect(queue == ordered)
    }

    private func example(group: UUID? = nil, phase: Phase = .new) throws -> DueCard {
        let type = ContextExamplePreset.itemType
        let template = type.templates[0]
        let metadata = SavedContextMetadata(groupID: group, target: .init(expression: group?.uuidString ?? "take off", language: "en", meaning: "remove"),
            spans: [.init(start: 7, length: 8)], provenance: .init(origin: .manual, sourceName: "Fixture"))
        let json = String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self)
        let item = Item(itemTypeID: type.id, fields: [.init(fieldID: ContextExamplePreset.metadata.id, value: .text(json))])
        let card = Card(itemID: item.id, templateID: template.id, skill: template.skill, memory: .init(phase: phase))
        return DueCard(card: card, item: item, itemType: type, template: template)
    }
}
