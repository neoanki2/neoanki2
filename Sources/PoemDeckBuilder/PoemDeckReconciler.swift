import Foundation
import NeoAnkiCore

public struct PoemDeckItemRecord: Sendable, Equatable {
    public let item: Item
    public let itemType: ItemType
    public let createdAt: Date?

    public init(item: Item, itemType: ItemType, createdAt: Date? = nil) {
        self.item = item
        self.itemType = itemType
        self.createdAt = createdAt
    }
}

public struct PoemSequenceMismatch: Sendable, Equatable, Identifiable {
    public let itemID: UUID
    public let expectedPrompt: String
    public let actualPrompt: String

    public var id: UUID { itemID }
}

public struct PoemDeckSnapshot: Sendable, Equatable {
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

    public var changesItemType: Bool { originalItemType != updatedItemType }
    public var hasChanges: Bool { changesItemType || !changes.isEmpty }
}

public enum PoemDeckReconciliationError: LocalizedError, Sendable, Equatable {
    case emptyDeck
    case mixedItemTypes
    case unsupportedItemType
    case missingField(String)
    case nonTextField(String)
    case missingTemplate
    case ambiguousStart
    case brokenChain
    case ambiguousChain
    case lineCountChanged(existing: Int, proposed: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyDeck:
            "This deck has no poem-line items to edit."
        case .mixedItemTypes:
            "Every card in a poem deck must use the same Poem Line item type."
        case .unsupportedItemType:
            "This deck is not a generated Poem Line deck."
        case let .missingField(name):
            "The Poem Line item type is missing its \(name) field."
        case let .nonTextField(name):
            "The \(name) field must contain plain text."
        case .missingTemplate:
            "The Poem Line item type must have one card template."
        case .ambiguousStart:
            "NeoAnki could not identify one unambiguous first transition."
        case .brokenChain:
            "The stored prompts do not form one complete poem sequence."
        case .ambiguousChain:
            "The stored poem order is ambiguous. Open a generated deck with reliable creation order or rebuild it from its source."
        case let .lineCountChanged(existing, proposed):
            "This edit has \(proposed) lines; the existing poem has \(existing). Adding or removing lines is not supported yet."
        }
    }
}

public enum PoemDeckReconciler {
    public static let stanzaBreakFieldName = "Stanza Break"

    public static func snapshot(records: [PoemDeckItemRecord]) throws -> PoemDeckSnapshot {
        guard !records.isEmpty else { throw PoemDeckReconciliationError.emptyDeck }
        let typeIDs = Set(records.map { $0.itemType.id })
        guard typeIDs.count == 1,
              records.allSatisfy({ $0.item.itemTypeID == records[0].itemType.id })
        else { throw PoemDeckReconciliationError.mixedItemTypes }

        let itemType = records[0].itemType
        guard itemType.name.caseInsensitiveCompare("Poem Line") == .orderedSame else {
            throw PoemDeckReconciliationError.unsupportedItemType
        }
        guard itemType.templates.count == 1 else {
            throw PoemDeckReconciliationError.missingTemplate
        }
        let front = try requiredTextField(named: "Front", in: itemType)
        let back = try requiredTextField(named: "Back", in: itemType)
        let attribution = try requiredTextField(named: "Attribution", in: itemType)
        let marker = field(named: stanzaBreakFieldName, in: itemType)
        let captions = try Set(records.map {
            try text($0.item.value(for: attribution.id), fieldName: attribution.name)
        })
        guard captions.count == 1, captions.first?.isEmpty == false else {
            throw PoemDeckReconciliationError.brokenChain
        }

        struct Candidate {
            let record: PoemDeckItemRecord
            let prompt: [String]
            let answer: String
            let startsStanza: Bool
        }

        let candidates = try records.map { record -> Candidate in
            let prompt = try text(record.item.value(for: front.id), fieldName: front.name)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { normalize(String($0)) }
            let rawAnswer = try text(record.item.value(for: back.id), fieldName: back.name)
            let answer = normalizeAnswer(rawAnswer)
            guard !answer.isEmpty, !answer.contains("\n") else {
                throw PoemDeckReconciliationError.brokenChain
            }
            let markerText = try marker.map {
                try text(record.item.value(for: $0.id), fieldName: $0.name, permitsMissing: true)
            } ?? ""
            return Candidate(
                record: record,
                prompt: prompt,
                answer: answer,
                startsStanza: !markerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || rawAnswer.hasPrefix("\n")
            )
        }

        let ordered: [Candidate]
        let dates = candidates.compactMap { $0.record.createdAt }
        if dates.count == candidates.count, Set(dates).count == candidates.count {
            ordered = candidates.sorted { $0.record.createdAt! < $1.record.createdAt! }
        } else {
            let starts = candidates.filter { $0.prompt.count == 1 }
            guard starts.count == 1, let start = starts.first else {
                throw PoemDeckReconciliationError.ambiguousStart
            }
            var chain = [start]
            var used: Set<UUID> = [start.record.item.id]
            var sourceLines = [try requiredLast(start.prompt), start.answer]
            while chain.count < candidates.count {
                let possible = candidates.filter {
                    !used.contains($0.record.item.id) && $0.prompt.last == sourceLines.last
                }
                let selected: Candidate
                if possible.count == 1, let only = possible.first {
                    selected = only
                } else if possible.count > 1 {
                    let exact = possible.filter {
                        Array($0.prompt.suffix(min(2, $0.prompt.count)))
                            == Array(sourceLines.suffix(min(2, $0.prompt.count)))
                    }
                    guard exact.count == 1, let only = exact.first else {
                        throw PoemDeckReconciliationError.ambiguousChain
                    }
                    selected = only
                } else {
                    throw PoemDeckReconciliationError.brokenChain
                }
                chain.append(selected)
                used.insert(selected.record.item.id)
                sourceLines.append(selected.answer)
            }
            ordered = chain
        }

        guard ordered[0].prompt.count == 1 else {
            throw PoemDeckReconciliationError.ambiguousStart
        }
        for index in 1 ..< ordered.count {
            guard ordered[index].prompt.last == ordered[index - 1].answer else {
                throw PoemDeckReconciliationError.brokenChain
            }
        }
        let sourceLines = [try requiredLast(ordered[0].prompt)] + ordered.map(\.answer)

        var sourceParts: [String] = []
        for index in sourceLines.indices {
            if index > 0, ordered[index - 1].startsStanza {
                sourceParts.append("")
            }
            sourceParts.append(sourceLines[index])
        }
        let sourceText = sourceParts.joined(separator: "\n")
        let expectedPrompts = PoemPromptPlanner.prompts(for: PoemDeckGenerator.parse(sourceText))
        let mismatches = try ordered.enumerated().compactMap { index, candidate -> PoemSequenceMismatch? in
            let expected = expectedPrompts[index]
            let actual = try text(candidate.record.item.value(for: front.id), fieldName: front.name)
            guard normalizeMultiline(actual) != normalizeMultiline(expected) else { return nil }
            return .init(itemID: candidate.record.item.id, expectedPrompt: expected, actualPrompt: actual)
        }
        return PoemDeckSnapshot(
            orderedRecords: ordered.map(\.record),
            sourceText: sourceText,
            mismatches: mismatches
        )
    }

    public static func preview(
        sourceText: String,
        records: [PoemDeckItemRecord]
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

        try validateGeneratedChain(items: replacements, itemType: updatedType)
        return PoemDeckReconciliationPreview(
            poem: poem,
            originalItemType: originalType,
            updatedItemType: updatedType,
            replacements: replacements,
            changes: changes,
            repairedMismatchCount: snapshot.mismatches.count
        )
    }

    public static func validateGeneratedChain(items: [Item], itemType: ItemType) throws {
        let front = try requiredTextField(named: "Front", in: itemType)
        let back = try requiredTextField(named: "Back", in: itemType)
        guard !items.isEmpty else { throw PoemDeckReconciliationError.emptyDeck }
        var source = [normalize(try text(items[0].value(for: front.id), fieldName: front.name))]
        guard !source[0].contains("\n") else { throw PoemDeckReconciliationError.brokenChain }
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
