import Foundation
import NeoAnkiCore

public struct ProseDeckItemRecord: Sendable, Equatable {
    public let item: Item
    public let itemType: ItemType

    public init(item: Item, itemType: ItemType) {
        self.item = item
        self.itemType = itemType
    }
}

public struct ProseDeckSnapshot: Sendable, Equatable {
    public let records: [ProseDeckItemRecord]
    public let units: [ProseUnit]
    public let sourceText: String
    public let attribution: String
}

public struct ProseDeckEditPreview: Sendable, Equatable {
    public let operations: [ItemBulkOperation]
    public let order: OrderedDeckItemReconciliation
    public let newCardIndices: [Int]
    public let retiredCards: [ProseRetiredCard]
    public let addedCount: Int
    public let retiredCount: Int
    public let retainedCount: Int
    public let revisedCount: Int
    public let changedPromptCount: Int
    public let unitCount: Int
    public let paragraphCount: Int

    public var hasChanges: Bool { !operations.isEmpty }
}

public struct ProseRetiredCard: Sendable, Equatable {
    public let prompt: String
    public let answer: String
}

public enum ProseDeckEditError: LocalizedError, Sendable, Equatable {
    case emptyDeck
    case mixedContent
    case unsupportedType
    case invalidOrder
    case invalidField(String)
    case invalidSource

    public var errorDescription: String? {
        switch self {
        case .emptyDeck: "This deck has no prose units to edit."
        case .mixedContent: "This deck contains items outside its generated prose sequence."
        case .unsupportedType: "This deck is not a generated Prose Unit deck."
        case .invalidOrder: "The stored prose order is damaged. Restore the deck from a backup."
        case let .invalidField(name): "The generated prose deck has an invalid \(name) field."
        case .invalidSource: "The passage needs at least one nonempty unit."
        }
    }
}

public enum ProseDeckReconciler {
    public static func snapshot(records: [ProseDeckItemRecord]) throws -> ProseDeckSnapshot {
        guard let first = records.first else { throw ProseDeckEditError.emptyDeck }
        let type = first.itemType
        guard type.name == "Prose Unit", type.templates.count == 1 else {
            throw ProseDeckEditError.unsupportedType
        }
        guard records.allSatisfy({
            $0.itemType.id == type.id && $0.item.itemTypeID == type.id
        }) else { throw ProseDeckEditError.mixedContent }
        let front = try field("Front", in: type)
        let back = try field("Back", in: type)
        let attribution = try field("Attribution", in: type)
        let order = try field("Order", in: type)
        let separator = try field("Separator", in: type)

        let sorted = try records.sorted {
            guard let left = Int(try text($0.item, field: order)),
                  let right = Int(try text($1.item, field: order)) else {
                throw ProseDeckEditError.invalidOrder
            }
            return left < right
        }
        let ordinals = try sorted.map { record -> Int in
            guard let value = Int(try text(record.item, field: order)) else {
                throw ProseDeckEditError.invalidOrder
            }
            return value
        }
        guard ordinals == Array(sorted.indices) else { throw ProseDeckEditError.invalidOrder }
        let attributions = try Set(sorted.map { try text($0.item, field: attribution) })
        guard attributions.count == 1, let caption = attributions.first, !caption.isEmpty else {
            throw ProseDeckEditError.invalidField("Attribution")
        }
        let units = try sorted.map {
            ProseUnit(
                text: try text($0.item, field: back),
                separator: try text($0.item, field: separator)
            )
        }
        guard ProseDeckGenerator.valid(units) else { throw ProseDeckEditError.invalidSource }
        _ = try sorted.map { try text($0.item, field: front) }
        return ProseDeckSnapshot(
            records: sorted,
            units: units,
            sourceText: ProseText.source(from: units),
            attribution: caption
        )
    }

    public static func preview(
        units: [ProseUnit],
        records: [ProseDeckItemRecord],
        deckID: UUID
    ) throws -> ProseDeckEditPreview {
        let original = try snapshot(records: records)
        guard ProseDeckGenerator.valid(units) else { throw ProseDeckEditError.invalidSource }
        let type = original.records[0].itemType
        let front = try field("Front", in: type)
        let back = try field("Back", in: type)
        let attribution = try field("Attribution", in: type)
        let order = try field("Order", in: type)
        let separator = try field("Separator", in: type)
        let oldTexts = original.units.map(\.text)
        let newTexts = units.map(\.text)
        let difference = newTexts.difference(from: oldTexts)
        let removed = Set(difference.removals.compactMap { change -> Int? in
            if case let .remove(offset, _, _) = change { return offset }
            return nil
        })
        let inserted = Set(difference.insertions.compactMap { change -> Int? in
            if case let .insert(offset, _, _) = change { return offset }
            return nil
        })
        var matches: [Int: Int] = [:]
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldTexts.count && newIndex < newTexts.count {
            if removed.contains(oldIndex) { oldIndex += 1; continue }
            if inserted.contains(newIndex) { newIndex += 1; continue }
            matches[newIndex] = oldIndex
            oldIndex += 1
            newIndex += 1
        }

        let prompts = ProsePromptPlanner.prompts(for: units)
        var operations: [ItemBulkOperation] = []
        var keptOld: Set<Int> = []
        var finalIDs: [UUID] = []
        var retainedCount = 0
        var revisedCount = 0
        var addedCount = 0
        var newCardIndices: [Int] = []
        var changedPromptCount = 0
        for index in units.indices {
            let unit = units[index]
            let match = matches[index]
            let canRetain: Bool
            if let match {
                let item = original.records[match].item
                canRetain = try text(item, field: front) == prompts[index]
                    && text(item, field: back) == unit.text
            } else {
                canRetain = false
            }
            let itemID = canRetain ? original.records[match!].item.id : UUID()
            finalIDs.append(itemID)
            let fields: [FieldValue] = [
                .init(fieldID: front.id, value: .text(prompts[index])),
                .init(fieldID: back.id, value: .text(unit.text)),
                .init(fieldID: attribution.id, value: .text(original.attribution)),
                .init(fieldID: order.id, value: .text(String(index))),
                .init(fieldID: separator.id, value: .text(unit.separator)),
            ]
            let proposed = Item(
                id: itemID,
                itemTypeID: type.id,
                fields: fields,
                tags: canRetain
                    ? original.records[match!].item.tags
                    : original.records[0].item.tags,
                deckID: deckID
            )
            if canRetain {
                keptOld.insert(match!)
                retainedCount += 1
                if proposed != original.records[match!].item {
                    operations.append(.init(operationID: "replace-\(index)", action: .replace(proposed)))
                    revisedCount += 1
                }
            } else {
                operations.append(.init(operationID: "create-\(index)", action: .create(proposed)))
                addedCount += 1
                newCardIndices.append(index)
                if match != nil { changedPromptCount += 1 }
            }
        }
        var retiredCards: [ProseRetiredCard] = []
        for index in original.records.indices where !keptOld.contains(index) {
            retiredCards.append(.init(
                prompt: try text(original.records[index].item, field: front),
                answer: original.units[index].text
            ))
            operations.append(.init(
                operationID: "delete-\(index)",
                action: .delete(original.records[index].item.id)
            ))
        }
        return ProseDeckEditPreview(
            operations: operations,
            order: .init(
                deckID: deckID,
                expectedItems: original.records.map(\.item),
                orderedItemIDs: finalIDs
            ),
            newCardIndices: newCardIndices,
            retiredCards: retiredCards,
            addedCount: addedCount,
            retiredCount: retiredCards.count,
            retainedCount: retainedCount,
            revisedCount: revisedCount,
            changedPromptCount: changedPromptCount,
            unitCount: units.count,
            paragraphCount: ProseText.paragraphCount(in: units)
        )
    }

    private static func field(_ name: String, in type: ItemType) throws -> FieldDef {
        guard let field = type.field(named: name), field.type == .text else {
            throw ProseDeckEditError.invalidField(name)
        }
        return field
    }

    private static func text(_ item: Item, field: FieldDef) throws -> String {
        guard case let .text(value, lang: _) = item.value(for: field.id) else {
            throw ProseDeckEditError.invalidField(field.name)
        }
        return value
    }
}
