import CryptoKit
import Foundation

/// Turns an item into its cards by applying the templates of its item type.
/// A template that is gated by `generateWhen` is skipped when the condition
/// isn't met for the item (e.g. no listening card without audio).
public enum CardGenerator {
    public static func cards(
        for item: Item,
        type: ItemType,
        now: Date = .now,
        deterministicIDs: Bool = false
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
                    id: deterministicIDs
                        ? deterministicCardID(
                            itemID: item.id,
                            templateID: template.id,
                            clozeGroup: group
                        )
                        : UUID(),
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

    /// Stable identities are used by API bulk planning so a non-mutating dry
    /// run and its later commit describe the same cards. The identity inputs
    /// are all immutable card-generation coordinates.
    private static func deterministicCardID(
        itemID: UUID,
        templateID: UUID,
        clozeGroup: Int?
    ) -> UUID {
        let groupText = clozeGroup.map(String.init) ?? "none"
        let input = "neoanki-card-v1|\(itemID.uuidString.lowercased())|\(templateID.uuidString.lowercased())|\(groupText)"
        var bytes = Array(SHA256.hash(data: Data(input.utf8)).prefix(16))
        // RFC 9562-compatible name-derived UUID shape (version 5, variant 1).
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
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
        for fieldID in template.components.compactMap({ component -> UUID? in
            guard component.purpose == .question,
                  case let .field(id) = component.source else { return nil }
            return id
        }) {
            if case let .cloze(_, blanks)? = item.value(for: fieldID) {
                return Set(blanks.map(\.group)).sorted()
            }
        }
        return []
    }
}
