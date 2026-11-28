import Foundation

/// Derived content identity, never a replacement for a card's own memory state.
public struct StudyCardRelation: Equatable, Sendable {
    public let family: String
    public let work: String?
    public let ordinal: Int?

    public init(family: String, work: String? = nil, ordinal: Int? = nil) {
        self.family = family
        self.work = work
        self.ordinal = ordinal
    }

    public static func family(for item: Item) -> String {
        // Course entries belong to their individual lesson track, even when the
        // same word appears in several lessons and contributes one Known Words term.
        if VocabularySet.hasCourseExample(in: item) { return "item:\(item.id.uuidString)" }
        if let term = VocabularySet.term(in: item) { return "vocabulary:\(term.id)" }
        struct Envelope: Decodable {
            struct Target: Decodable { var language: String; var expression: String }
            var format: String
            var groupID: UUID?
            var target: Target?
        }
        for field in item.fields {
            guard case let .text(json, _) = field.value,
                  json.contains("neoanki-context-example"),
                  let value = try? JSONDecoder().decode(Envelope.self, from: Data(json.utf8)),
                  value.format == "neoanki-context-example" else { continue }
            if let target = value.target {
                let language = normalized(target.language)
                let expression = normalized(target.expression)
                if !language.isEmpty, !expression.isEmpty {
                    // Length-prefixing prevents collisions between the two parts.
                    return "context:\(language.utf8.count):\(language)\(expression)"
                }
            }
            if let group = value.groupID { return "context-batch:\(group.uuidString)" }
        }
        return "item:\(item.id.uuidString)"
    }

    private static func normalized(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Session ordering only: never changes eligibility, memories, or due dates.
public enum StudyQueueOrdering {
    public static let preferredInterveningCards = 5

    /// Reorders each work inside its existing slots, leaving unrelated slots intact.
    public static func orderWorks(in queue: inout [DueCard], from start: Int = 0) {
        guard start < queue.count else { return }
        let slots = Dictionary(grouping: (max(0, start)..<queue.count).filter {
            queue[$0].studyRelation?.work != nil
        }, by: { queue[$0].studyRelation!.work! })
        for indices in slots.values {
            let ordered = indices.map { queue[$0] }.sorted {
                let left = $0.studyRelation?.ordinal ?? Int.max
                let right = $1.studyRelation?.ordinal ?? Int.max
                return left == right ? $0.id.uuidString < $1.id.uuidString : left < right
            }
            for (index, card) in zip(indices, ordered) { queue[index] = card }
        }
    }

    static func orderWorks(in cards: inout [Card], relations: [UUID: StudyCardRelation]) {
        let slots = Dictionary(grouping: cards.indices.filter { relations[cards[$0].itemID]?.work != nil },
                               by: { relations[cards[$0].itemID]!.work! })
        for indices in slots.values {
            let ordered = indices.map { cards[$0] }.sorted {
                let left = relations[$0.itemID]?.ordinal ?? Int.max
                let right = relations[$1.itemID]?.ordinal ?? Int.max
                return left == right ? $0.id.uuidString < $1.id.uuidString : left < right
            }
            for (index, card) in zip(indices, ordered) { cards[index] = card }
        }
    }

    /// A stable move (rather than a swap) preserves the priority of candidates
    /// which were not selected. Builder work slots and repair phases stay fixed.
    public static func separateRelated(in queue: inout [DueCard], at index: Int) {
        guard let selected = relatedCardIndex(in: queue, at: index, family: family(of:)),
              selected != index else { return }
        let phase = queue[index].card.memory.phase
        let card = queue[selected]
        var destination = selected
        for source in stride(from: selected - 1, through: index, by: -1)
        where queue[source].studyRelation?.work == nil && queue[source].card.memory.phase == phase {
            queue[destination] = queue[source]
            destination = source
        }
        queue[index] = card
    }

    /// The resolver seam lets tests count actual family inspections without
    /// timing assumptions. Keys live only for this read, so edits stay visible.
    static func relatedCardIndex(
        in queue: [DueCard], at index: Int, family: (DueCard) -> String
    ) -> Int? {
        guard queue.indices.contains(index), index > 0,
              queue[index].studyRelation?.work == nil,
              queue[index].card.memory.phase == .review || queue[index].card.memory.phase == .new else { return nil }
        let phase = queue[index].card.memory.phase
        let recent = queue[..<index].suffix(preferredInterveningCards).map(family)
        var selected = index
        var bestScore = recent.lastIndex(of: family(queue[index])) ?? -1
        // An unseen family is optimal. Ordinary independent cards therefore
        // advance in constant work rather than scanning the remaining session.
        guard bestScore >= 0 else { return selected }
        for candidate in (index + 1)..<queue.count
        where queue[candidate].studyRelation?.work == nil && queue[candidate].card.memory.phase == phase {
            let score = recent.lastIndex(of: family(queue[candidate])) ?? -1
            if score < bestScore {
                selected = candidate
                bestScore = score
                if score == -1 { break }
            }
        }
        return selected
    }

    public static func refreshRelation(in card: inout DueCard) {
        guard let relation = card.studyRelation else { return }
        if let work = relation.work {
            if card.itemType.name.caseInsensitiveCompare("Prose Unit") == .orderedSame,
               let field = card.itemType.field(named: "Order"),
               case let .text(value, _)? = card.item.value(for: field.id), let ordinal = Int(value) {
                card.studyRelation = .init(family: relation.family, work: work, ordinal: ordinal)
            }
        } else {
            card.studyRelation = .init(family: StudyCardRelation.family(for: card.item))
        }
    }

    public static func family(of card: DueCard) -> String {
        if card.studyRelation?.work != nil { return card.studyRelation!.family }
        return StudyCardRelation.family(for: card.item)
    }
}
