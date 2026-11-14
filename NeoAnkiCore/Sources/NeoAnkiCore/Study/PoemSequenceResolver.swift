import Foundation

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

public enum PoemDeckReconciliationError: LocalizedError, Sendable, Equatable {
    case emptyDeck
    case mixedItemTypes
    case unsupportedItemType
    case missingField(String)
    case nonTextField(String)
    case missingTemplate
    case invalidOpeningCard
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
        case .invalidOpeningCard:
            "The poem has duplicate or inconsistent opening-line cards."
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

/// Canonical poem order shared by the editor and study queues. Resolve the
/// complete work before selecting its due subset; missing lines are not gaps
/// that can safely be reconstructed from a partial queue.
public enum PoemSequenceResolver {
    public static let openingTag = "neoanki:poem-opening"
    public static let openingPrompt = "Recall the first line."

    public struct Sequence: Sendable {
        public let openingRecord: PoemDeckItemRecord?
        public let orderedRecords: [PoemDeckItemRecord]
        public let sourceLines: [String]
        public let startsStanza: [Bool]
    }

    public static func resolve(records: [PoemDeckItemRecord]) throws -> Sequence {
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
        let marker = field(named: "Stanza Break", in: itemType)
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

        let openings = records.filter { $0.item.tags.contains(openingTag) }
        guard openings.count <= 1 else { throw PoemDeckReconciliationError.invalidOpeningCard }
        let transitions = records.filter { !$0.item.tags.contains(openingTag) }
        guard !transitions.isEmpty else { throw PoemDeckReconciliationError.emptyDeck }
        let candidates = try transitions.map { record -> Candidate in
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
        if let opening = openings.first {
            let answer = try text(opening.item.value(for: back.id), fieldName: back.name)
            let prompt = try text(opening.item.value(for: front.id), fieldName: front.name)
            let markerText = try marker.map {
                try text(opening.item.value(for: $0.id), fieldName: $0.name, permitsMissing: true)
            } ?? ""
            guard normalize(answer) == sourceLines[0], !answer.contains("\n"),
                  prompt == openingPrompt,
                  markerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PoemDeckReconciliationError.invalidOpeningCard
            }
        }

        return Sequence(openingRecord: openings.first, orderedRecords: ordered.map(\.record),
                        sourceLines: sourceLines, startsStanza: ordered.map(\.startsStanza))
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
