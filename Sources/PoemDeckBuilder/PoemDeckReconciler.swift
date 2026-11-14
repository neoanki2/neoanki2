import Foundation
import NeoAnkiCore

public struct PoemSequenceMismatch: Sendable, Equatable, Identifiable {
    public let itemID: UUID
    public let expectedPrompt: String
    public let actualPrompt: String

    public var id: UUID { itemID }
}

public struct PoemDeckSnapshot: Sendable, Equatable {
    public let openingRecord: PoemDeckItemRecord?
    /// Continuation records only; the opening answer is not a transition.
    public let orderedRecords: [PoemDeckItemRecord]
    public let sourceText: String
    public let mismatches: [PoemSequenceMismatch]
}

public struct PoemDeckReconciliationChange: Sendable, Equatable, Identifiable {
    public let itemID: UUID
    public let oldPrompt: String
    public let newPrompt: String
    public let oldAnswer: String
    public let newAnswer: String
    public let addsStanzaBreak: Bool
    public let removesStanzaBreak: Bool

    public var id: UUID { itemID }
}

public struct PoemDeckReconciliationPreview: Sendable, Equatable {
    public let poem: ParsedPoem
    public let originalItemType: ItemType
    public let updatedItemType: ItemType
    public let replacements: [Item]
    public let changes: [PoemDeckReconciliationChange]
    public let repairedMismatchCount: Int
    public let operations: [ItemBulkOperation]
    public let order: OrderedDeckItemReconciliation?
    public let openingCard: Item?
    public let retiredOpeningCard: Item?
    public let addedCount: Int
    public let retiredCount: Int

    public var changesItemType: Bool { originalItemType != updatedItemType }
    public var hasChanges: Bool { changesItemType || !operations.isEmpty }
}

public enum PoemDeckReconciler {
    public static let stanzaBreakFieldName = "Stanza Break"

    public static func snapshot(records: [PoemDeckItemRecord]) throws -> PoemDeckSnapshot {
        let sequence = try PoemSequenceResolver.resolve(records: records)
        let sourceLines = sequence.sourceLines
        let ordered = sequence.orderedRecords
        let itemType = ordered[0].itemType
        let front = try requiredTextField(named: "Front", in: itemType)
        var sourceParts: [String] = []
        for index in sourceLines.indices {
            if index > 0, sequence.startsStanza[index - 1] {
                sourceParts.append("")
            }
            sourceParts.append(sourceLines[index])
        }
        let sourceText = sourceParts.joined(separator: "\n")
        let expectedPrompts = PoemPromptPlanner.prompts(for: PoemDeckGenerator.parse(sourceText))
        let mismatches = try ordered.enumerated().compactMap { index, candidate -> PoemSequenceMismatch? in
            let expected = expectedPrompts[index]
            let actual = try text(candidate.item.value(for: front.id), fieldName: front.name)
            guard normalizeMultiline(actual) != normalizeMultiline(expected) else { return nil }
            return .init(itemID: candidate.item.id, expectedPrompt: expected, actualPrompt: actual)
        }
        return PoemDeckSnapshot(
            openingRecord: sequence.openingRecord,
            orderedRecords: ordered,
            sourceText: sourceText,
            mismatches: mismatches
        )
    }

    public static func preview(
        sourceText: String,
        records: [PoemDeckItemRecord],
        title: String? = nil,
        deckID: UUID? = nil
    ) throws -> PoemDeckReconciliationPreview {
        let snapshot = try snapshot(records: records)
        let poem = PoemDeckGenerator.parse(sourceText)
        let proposedLines = poem.lines
        let existingLineCount = snapshot.orderedRecords.count + 1
        guard proposedLines.count == existingLineCount else {
            throw PoemDeckReconciliationError.lineCountChanged(
                existing: existingLineCount,
                proposed: proposedLines.count
            )
        }

        let originalType = snapshot.orderedRecords[0].itemType
        // Legacy stanza components remain in the schema so learned card identities
        // survive reconciliation. An empty marker value is not rendered.
        let updatedType = originalType
        let front = try requiredTextField(named: "Front", in: updatedType)
        let back = try requiredTextField(named: "Back", in: updatedType)
        let marker = field(named: stanzaBreakFieldName, in: updatedType)
        let plannedPrompts = PoemPromptPlanner.prompts(for: poem)

        var replacements: [Item] = []
        var changes: [PoemDeckReconciliationChange] = []
        for (index, record) in snapshot.orderedRecords.enumerated() {
            let answerIndex = index + 1
            let newPrompt = plannedPrompts[index]
            let stanzaStarts = proposedLines[answerIndex].startsStanza
            let newAnswer = (stanzaStarts ? "\n" : "") + proposedLines[answerIndex].text
            let needsStanzaSpacing = proposedLines[answerIndex].startsStanza
            let oldPrompt = try text(record.item.value(for: front.id), fieldName: front.name)
            let oldAnswer = try text(record.item.value(for: back.id), fieldName: back.name)
            let hadLegacyMarker = try marker.map {
                !(try text(
                    record.item.value(for: $0.id),
                    fieldName: $0.name,
                    permitsMissing: true
                )).isEmpty
            } ?? false
            let hadStanzaBreak = hadLegacyMarker || oldAnswer.hasPrefix("\n")

            var replacement = record.item
            setText(newPrompt, field: front, in: &replacement)
            setText(newAnswer, field: back, in: &replacement)
            if let marker {
                setText("", field: marker, in: &replacement)
            }
            replacements.append(replacement)

            if oldPrompt != newPrompt || oldAnswer != newAnswer || hadLegacyMarker {
                changes.append(.init(
                    itemID: record.item.id,
                    oldPrompt: oldPrompt,
                    newPrompt: newPrompt,
                    oldAnswer: oldAnswer,
                    newAnswer: newAnswer,
                    addsStanzaBreak: !hadStanzaBreak && needsStanzaSpacing,
                    removesStanzaBreak: hadStanzaBreak && !needsStanzaSpacing
                ))
            }
        }

        let changedIDs = Set(changes.map(\.itemID))
        var operations = replacements.filter { changedIDs.contains($0.id) }.map {
            ItemBulkOperation(operationID: "replace-\($0.id)", action: .replace($0))
        }
        let needsOpening = title.map {
            PoemCardPlanner.needsOpeningCard(title: $0, firstLine: proposedLines[0].text)
        } ?? (snapshot.openingRecord != nil)
        var openingCard: Item?
        var retiredOpeningCard: Item?
        var addedCount = 0
        var retiredCount = 0
        if needsOpening {
            var opening = snapshot.openingRecord?.item ?? Item(
                itemTypeID: originalType.id,
                fields: snapshot.orderedRecords[0].item.fields,
                tags: snapshot.orderedRecords[0].item.tags + [PoemCardPlanner.openingTag],
                deckID: deckID ?? snapshot.orderedRecords[0].item.deckID
            )
            setText(PoemCardPlanner.openingPrompt, field: front, in: &opening)
            setText(proposedLines[0].text, field: back, in: &opening)
            if let marker { setText("", field: marker, in: &opening) }
            openingCard = opening
            if let old = snapshot.openingRecord?.item {
                if old != opening {
                    operations.append(.init(operationID: "opening-replace", action: .replace(opening)))
                    changes.append(.init(
                        itemID: old.id,
                        oldPrompt: try text(old.value(for: front.id), fieldName: front.name),
                        newPrompt: PoemCardPlanner.openingPrompt,
                        oldAnswer: try text(old.value(for: back.id), fieldName: back.name),
                        newAnswer: proposedLines[0].text,
                        addsStanzaBreak: false, removesStanzaBreak: false
                    ))
                }
            } else {
                operations.append(.init(operationID: "opening-create", action: .create(opening)))
                addedCount = 1
            }
        } else if let old = snapshot.openingRecord?.item {
            retiredOpeningCard = old
            operations.append(.init(operationID: "opening-delete", action: .delete(old.id)))
            retiredCount = 1
        }
        let finalItems = openingCard.map { [$0] } ?? []
        try validateGeneratedChain(items: finalItems + replacements, itemType: updatedType)
        let order = deckID.map {
            OrderedDeckItemReconciliation(
                deckID: $0, expectedItems: records.map(\.item),
                orderedItemIDs: (finalItems + replacements).map(\.id)
            )
        }
        return PoemDeckReconciliationPreview(
            poem: poem,
            originalItemType: originalType,
            updatedItemType: updatedType,
            replacements: replacements,
            changes: changes,
            repairedMismatchCount: snapshot.mismatches.count,
            operations: operations,
            order: order,
            openingCard: openingCard,
            retiredOpeningCard: retiredOpeningCard,
            addedCount: addedCount,
            retiredCount: retiredCount
        )
    }

    public static func validateGeneratedChain(items: [Item], itemType: ItemType) throws {
        let openings = items.filter { $0.tags.contains(PoemCardPlanner.openingTag) }
        guard openings.count <= 1 else { throw PoemDeckReconciliationError.invalidOpeningCard }
        let items = items.filter { !$0.tags.contains(PoemCardPlanner.openingTag) }
        let front = try requiredTextField(named: "Front", in: itemType)
        let back = try requiredTextField(named: "Back", in: itemType)
        guard !items.isEmpty else { throw PoemDeckReconciliationError.emptyDeck }
        var source = [normalize(try text(items[0].value(for: front.id), fieldName: front.name))]
        guard !source[0].contains("\n") else { throw PoemDeckReconciliationError.brokenChain }
        if let opening = openings.first {
            guard try text(opening.value(for: front.id), fieldName: front.name) == PoemCardPlanner.openingPrompt,
                  try text(opening.value(for: back.id), fieldName: back.name) == source[0] else {
                throw PoemDeckReconciliationError.invalidOpeningCard
            }
        }
        var stanzaStarts = [false]
        for item in items {
            let rawAnswer = try text(item.value(for: back.id), fieldName: back.name)
            let answer = normalizeAnswer(rawAnswer)
            guard !answer.isEmpty, !answer.contains("\n") else {
                throw PoemDeckReconciliationError.brokenChain
            }
            source.append(answer)
            stanzaStarts.append(rawAnswer.hasPrefix("\n"))
        }
        var sourceParts: [String] = []
        for index in source.indices {
            if stanzaStarts[index] { sourceParts.append("") }
            sourceParts.append(source[index])
        }
        let expected = PoemPromptPlanner.prompts(
            for: PoemDeckGenerator.parse(sourceParts.joined(separator: "\n"))
        )
        for (index, item) in items.enumerated() {
            let actual = try text(item.value(for: front.id), fieldName: front.name)
            guard normalizeMultiline(actual) == normalizeMultiline(expected[index]) else {
                throw PoemDeckReconciliationError.brokenChain
            }
        }
    }

    private static func field(named name: String, in itemType: ItemType) -> FieldDef? {
        itemType.fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private static func requiredTextField(named name: String, in itemType: ItemType) throws -> FieldDef {
        guard let field = field(named: name, in: itemType) else {
            throw PoemDeckReconciliationError.missingField(name)
        }
        guard field.type == .text else { throw PoemDeckReconciliationError.nonTextField(name) }
        return field
    }

    private static func text(
        _ value: ContentValue?,
        fieldName: String,
        permitsMissing: Bool = false
    ) throws -> String {
        guard let value else {
            if permitsMissing { return "" }
            throw PoemDeckReconciliationError.missingField(fieldName)
        }
        guard case let .text(value, _) = value else {
            throw PoemDeckReconciliationError.nonTextField(fieldName)
        }
        return value
    }

    private static func setText(_ value: String, field: FieldDef, in item: inout Item) {
        let language: String?
        if case let .text(_, existingLanguage) = item.value(for: field.id) {
            language = existingLanguage
        } else {
            language = nil
        }
        item.fields.removeAll { $0.fieldID == field.id }
        if !value.isEmpty {
            item.fields.append(FieldValue(fieldID: field.id, value: .text(value, lang: language)))
        }
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces)
            .precomposedStringWithCanonicalMapping
    }

    private static func normalizeAnswer(_ value: String) -> String {
        normalize(value.hasPrefix("\n") ? String(value.dropFirst()) : value)
    }

    private static func normalizeMultiline(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { normalize(String($0)) }
            .joined(separator: "\n")
    }

    private static func requiredLast(_ lines: [String]) throws -> String {
        guard let line = lines.last, !line.isEmpty else {
            throw PoemDeckReconciliationError.brokenChain
        }
        return line
    }
}
