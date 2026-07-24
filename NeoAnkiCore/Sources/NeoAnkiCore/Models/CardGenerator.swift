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
        type.templates.compactMap { template in
            guard shouldGenerate(template, for: item) else { return nil }
            return Card(
                itemID: item.id,
                templateID: template.id,
                skill: template.skill,
                memory: .new(due: now),
                deckID: item.deckID
            )
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
}
