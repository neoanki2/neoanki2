import Foundation

/// Turns an item into its cards by applying the templates of its item type.
/// A template that is gated by `generateWhen` is skipped when the condition
/// isn't met for the item (e.g. no listening card without audio).
public enum CardGenerator {
    public static func cards(
        for item: Item,
        type: ItemType,
        now: Date = .now
    ) -> [Card] {
        type.templates.flatMap { template -> [Card] in
            guard shouldGenerate(template, for: item) else { return [] }
            let groups: [Int?]
            if template.interaction == .cloze {
                groups = clozeGroups(for: template, item: item).map(Optional.some)
            } else {
                groups = [nil]
            }
            return groups.map { group in
                Card(
                    itemID: item.id,
                    templateID: template.id,
                    skill: template.skill,
                    memory: .new(due: now),
                    deckID: item.deckID,
                    clozeGroup: group
                )
            }
        }
    }

    public static func shouldGenerate(_ template: Template, for item: Item) -> Bool {
        guard let condition = template.generateWhen else { return true }
        return evaluate(condition, for: item)
    }

    private static func evaluate(_ condition: SlotCondition, for item: Item) -> Bool {
        switch condition {
        case let .fieldNotEmpty(fieldID):
            return !item.isFieldEmpty(fieldID)
        case let .fieldEmpty(fieldID):
            return item.isFieldEmpty(fieldID)
        case let .all(conditions):
            return conditions.allSatisfy { evaluate($0, for: item) }
        case let .any(conditions):
            return conditions.contains { evaluate($0, for: item) }
        }
    }

    public static func clozeGroups(for template: Template, item: Item) -> [Int] {
        guard template.interaction == .cloze else { return [] }
        for fieldID in ItemTypeValidation.fieldIDs(in: template.prompt) {
            if case let .cloze(_, blanks)? = item.value(for: fieldID) {
                return Set(blanks.map(\.group)).sorted()
            }
        }
        return []
    }
}
