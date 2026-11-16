import Foundation
import Testing
@testable import NeoAnkiCore

private func orderingCard(_ index: Int, family: String? = nil, phase: Phase = .new, work: String? = nil) -> DueCard {
    let type = BuiltInItemTypes.basic
    let text = family.map { "{\"format\":\"neoanki-context-example\",\"target\":{\"language\":\"en\",\"expression\":\"\($0)\"}}" } ?? "Question \(index)"
    let item = Item(itemTypeID: type.id, fields: [
        .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text(text)),
        .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
    ])
    return DueCard(card: Card(itemID: item.id, templateID: type.templates[0].id,
                             skill: type.templates[0].skill, memory: .init(phase: phase)),
                   item: item, itemType: type, template: type.templates[0],
                   studyRelation: .init(family: "item:\(item.id)", work: work, ordinal: index))
}

/// Frozen pre-optimization policy: an independent oracle for stable movement
/// and tie-breaking, including duplicate cards in deferred repair rounds.
private func referenceOrdering(_ queue: inout [DueCard], at index: Int) {
    guard queue.indices.contains(index), index > 0, queue[index].studyRelation?.work == nil,
          queue[index].card.memory.phase == .review || queue[index].card.memory.phase == .new else { return }
    let phase = queue[index].card.memory.phase
    let recent = queue[..<index].suffix(StudyQueueOrdering.preferredInterveningCards).map { StudyQueueOrdering.family(of: $0) }
    let slots = (index..<queue.count).filter { queue[$0].studyRelation?.work == nil && queue[$0].card.memory.phase == phase }
    func score(_ slot: Int) -> Int { recent.lastIndex(of: StudyQueueOrdering.family(of: queue[slot])) ?? -1 }
    guard let selected = slots.min(by: { score($0) < score($1) }), selected != index,
          let offset = slots.firstIndex(of: selected) else { return }
    let card = queue[selected]
    for position in stride(from: offset, through: 1, by: -1) { queue[slots[position]] = queue[slots[position - 1]] }
    queue[index] = card
}

@Test func relatedOrderingMatchesReferenceAcrossMixedQueuesAndRepairs() {
    var random: UInt64 = 7
    func pick(_ count: Int) -> Int {
        random = random &* 6_364_136_223_846_793_005 &+ 1
        return Int((random >> 32) % UInt64(count))
    }
    let phases: [Phase] = [.new, .review, .learning, .relearning]
    let families = ["café", "cafe\u{301}", " Take   Off ", "take off", "猫", "other"]
    for _ in 0..<60 {
        var actual = (0..<40).map { index in
            orderingCard(index, family: pick(3) == 0 ? nil : families[pick(families.count)],
                         phase: phases[pick(phases.count)], work: pick(5) == 0 ? "ordered" : nil)
        }
        actual += actual.prefix(5)
        var expected = actual
        for index in actual.indices {
            StudyQueueOrdering.separateRelated(in: &actual, at: index)
            referenceOrdering(&expected, at: index)
            #expect(actual == expected)
        }
    }
}

@Test func independentQueueInspectsOnlyTheRecentWindowAndCurrentCard() {
    let queue = (0..<25_000).map { orderingCard($0) }
    var inspections = 0
    for index in queue.indices {
        let selected = StudyQueueOrdering.relatedCardIndex(in: queue, at: index) { card in
            inspections += 1
            return card.item.id.uuidString
        }
        #expect(selected == (index == 0 ? nil : index))
    }
    #expect(inspections <= queue.count * (StudyQueueOrdering.preferredInterveningCards + 1))
}

@Test func relatedSelectionStopsAtFirstOptimalCandidateAndSeesEdits() {
    var queue = [orderingCard(0, family: "same"), orderingCard(1, family: "same"),
                 orderingCard(2, family: "different")] + (3..<100).map { orderingCard($0) }
    var inspections = 0
    let selected = StudyQueueOrdering.relatedCardIndex(in: queue, at: 1) { card in
        inspections += 1
        return StudyQueueOrdering.family(of: card)
    }
    #expect(selected == 2)
    #expect(inspections == 3)
    queue[1].item.fields[0].value = .text("Edited independent question")
    let expected = queue
    StudyQueueOrdering.separateRelated(in: &queue, at: 1)
    #expect(queue == expected)
}
