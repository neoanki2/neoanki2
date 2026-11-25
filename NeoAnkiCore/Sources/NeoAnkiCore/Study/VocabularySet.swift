import CryptoKit
import Foundation

public struct VocabularyTerm: Codable, Hashable, Sendable, Identifiable {
    public let language: String
    public let expression: String
    public let sense: String?

    public init(language: String, expression: String, sense: String? = nil) {
        self.language = Self.languageCode(language)
        self.expression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sense = sense?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var id: String {
        let parts = [language, Self.normalized(expression), Self.normalized(sense ?? "")]
        return parts.map { "\($0.utf8.count):\($0)" }.joined()
    }

    public static func languageCode(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-").lowercased()
    }

    public static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public func validated() throws -> Self {
        let value = Self(language: language, expression: expression, sense: sense)
        guard Self.isLanguageCode(value.language), !value.expression.isEmpty, value.expression.count <= 250,
              (value.sense?.count ?? 0) <= 250 else { throw VocabularySetError.invalidTerm }
        return value
    }

    public static func isLanguageCode(_ code: String) -> Bool {
        let canonical = languageCode(code)
        let parts = canonical.split(separator: "-", omittingEmptySubsequences: false)
        guard let primary = parts.first, (2...8).contains(primary.count),
              primary.utf8.allSatisfy({ (97...122).contains($0) }), canonical != "und" else { return false }
        return parts.allSatisfy { (1...8).contains($0.count) && $0.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0)
        } }
    }
}

public enum VocabularyJudgment: String, Codable, Sendable {
    case known, unfamiliar, reviewHistory
}

public struct VocabularyJudgmentChange: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let term: VocabularyTerm
    public let judgment: VocabularyJudgment
    public let changedAt: Date
}

public struct VocabularyStatus: Codable, Equatable, Identifiable, Sendable {
    public let term: VocabularyTerm
    public var judgment: VocabularyJudgment?
    public var readingMature = false
    public var clozeMature = false
    public var hasCards = false
    public var id: String { term.id }
    public var isKnown: Bool {
        judgment == .known || (judgment != .unfamiliar && readingMature)
    }
}

public struct VocabularySetDraft: Codable, Equatable, Sendable {
    public var term: VocabularyTerm
    public var meaning: String
    public var meaningLanguage: String
    public var sentence: String
    public var occurrence: Int
    public var productionSentence: String?
    public var productionForm: String?
    public var productionOccurrence: Int?
    public var acceptedVariants: [String]?
    public var source: String?
    public var deckID: UUID?

    public init(term: VocabularyTerm, meaning: String, meaningLanguage: String, sentence: String, occurrence: Int = 0,
                productionSentence: String? = nil, productionForm: String? = nil, productionOccurrence: Int? = nil,
                acceptedVariants: [String]? = nil, source: String? = nil, deckID: UUID? = nil) {
        self.term = term
        self.meaning = meaning
        self.meaningLanguage = meaningLanguage
        self.sentence = sentence
        self.occurrence = occurrence
        self.productionSentence = productionSentence
        self.productionForm = productionForm
        self.productionOccurrence = productionOccurrence
        self.acceptedVariants = acceptedVariants
        self.source = source
        self.deckID = deckID
    }
}

public enum VocabularySetError: LocalizedError {
    case invalidTerm, missingMeaning, invalidOccurrence, exposedAnswer, changedPreset, idConflict
    public var errorDescription: String? {
        switch self {
        case .invalidTerm: "Choose a language and enter a word or phrase."
        case .missingMeaning: "Enter a short meaning and choose its language."
        case .invalidOccurrence: "Choose the exact word or phrase in a complete example sentence."
        case .exposedAnswer: "Choose a sentence that shows the missing form only once."
        case .changedPreset: "The Vocabulary Set card setup was edited. Restore it before adding another set."
        case .idConflict: "This request already created a different vocabulary set."
        }
    }
}

public enum VocabularySet {
    private static func uuid(_ suffix: String) -> UUID {
        UUID(uuidString: "B9573F82-D098-428F-A54F-DAC7A1DE\(suffix)")!
    }
    public static let typeID = uuid("1000")
    public static let readingID = uuid("1001")
    public static let productionID = uuid("1002")
    private static let target = FieldDef(id: uuid("1010"), name: "Word or phrase", type: .text, isRequired: true)
    private static let reading = FieldDef(id: uuid("1011"), name: "Reading sentence", type: .richText, isRequired: true)
    private static let meaning = FieldDef(id: uuid("1012"), name: "Meaning", type: .text, isRequired: true)
    private static let cloze = FieldDef(id: uuid("1013"), name: "Production sentence", type: .cloze, isRequired: true)
    private static let metadata = FieldDef(id: uuid("1014"), name: "Vocabulary identity", type: .text, isRequired: true)
    private static let source = FieldDef(id: uuid("1015"), name: "Source", type: .text)

    private struct Identity: Codable {
        let version: Int
        let term: VocabularyTerm
        let acceptedVariants: [String]
    }

    public static let itemType = ItemType(id: typeID, name: "Vocabulary Set",
        fields: [target, reading, meaning, cloze, metadata, source], templates: [
            .init(id: readingID, name: "Understand in context", layout: .focus, components: [
                .init(id: uuid("1026"), region: .label, purpose: .supporting,
                      source: .literal("What does the highlighted expression mean here?")),
                .init(id: uuid("1020"), region: .primary, purpose: .question, source: .field(reading.id)),
                .init(id: uuid("1021"), region: .secondary, purpose: .expectedAnswer, source: .field(meaning.id),
                      presentation: .init(reveal: .hiddenUntilAnswer)),
                .init(id: uuid("1022"), region: .supporting, purpose: .supporting, source: .field(source.id),
                      presentation: .init(reveal: .hiddenUntilAnswer)),
            ], interaction: .reveal, skill: .init(input: .text, output: .freeResponse, operation: .recall)),
            .init(id: productionID, name: "Complete the sentence", layout: .focus, components: [
                .init(id: uuid("1023"), region: .primary, purpose: .question, source: .field(cloze.id)),
                .init(id: uuid("1024"), region: .supporting, purpose: .supporting, source: .field(meaning.id)),
                .init(id: uuid("1025"), region: .secondary, purpose: .expectedAnswer, source: .field(cloze.id),
                      presentation: .init(reveal: .hiddenUntilAnswer)),
            ], interaction: .cloze, skill: .init(input: .text, output: .freeResponse, operation: .recall)),
        ])

    /// Match complete tokens as well as selections in scripts that do not separate words with spaces.
    public static func occurrences(of expression: String, in sentence: String, language: String) -> [Range<String.Index>] {
        guard !expression.isEmpty else { return [] }
        let locale = Locale(identifier: language)
        let runTogether = ["ja", "zh", "th", "lo", "km", "my"].contains(String(language.split(separator: "-").first ?? ""))
        func wordCharacter(_ character: Character) -> Bool {
            character.isLetter || character.isNumber
        }
        var matches: [Range<String.Index>] = []
        var start = sentence.startIndex
        while start < sentence.endIndex,
              let hit = sentence.range(of: expression, options: [.caseInsensitive],
                                       range: start..<sentence.endIndex, locale: locale) {
            let left = hit.lowerBound == sentence.startIndex || !wordCharacter(sentence[sentence.index(before: hit.lowerBound)])
            let right = hit.upperBound == sentence.endIndex || !wordCharacter(sentence[hit.upperBound])
            if runTogether || (left && right) { matches.append(hit) }
            start = hit.upperBound
        }
        return matches
    }

    public static func makeItem(_ draft: VocabularySetDraft, id: UUID) throws -> Item {
        let term = try draft.term.validated()
        let gloss = draft.meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gloss.isEmpty, gloss.count <= 1_000,
              VocabularyTerm.isLanguageCode(draft.meaningLanguage)
        else { throw VocabularySetError.missingMeaning }
        let sentence = draft.sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = occurrences(of: term.expression, in: sentence, language: term.language)
        guard sentence.count <= 2_000, matches.indices.contains(draft.occurrence),
              sentence.count > term.expression.count else { throw VocabularySetError.invalidOccurrence }
        let match = matches[draft.occurrence]
        guard containsContext(in: sentence, outside: match) else { throw VocabularySetError.invalidOccurrence }
        let production = draft.productionSentence?.trimmingCharacters(in: .whitespacesAndNewlines) ?? sentence
        let form = draft.productionForm?.trimmingCharacters(in: .whitespacesAndNewlines) ?? String(sentence[match])
        let productionMatches = occurrences(of: form, in: production, language: term.language)
        let ordinal = draft.productionOccurrence ?? (draft.productionSentence == nil ? draft.occurrence : 0)
        guard production.count <= 2_000, production.count > form.count, productionMatches.indices.contains(ordinal)
        else { throw VocabularySetError.invalidOccurrence }
        guard productionMatches.count == 1, occurrences(of: form, in: gloss, language: term.language).isEmpty
        else { throw VocabularySetError.exposedAnswer }
        let blank = productionMatches[ordinal]
        guard containsContext(in: production, outside: blank) else { throw VocabularySetError.invalidOccurrence }
        let span = ClozeSpan(group: 1, start: production.distance(from: production.startIndex, to: blank.lowerBound),
                             length: production.distance(from: blank.lowerBound, to: blank.upperBound))
        try ClozeValidation.validate(text: production, blanks: [span])
        let variants = (draft.acceptedVariants ?? []).prefix(16)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && $0.count <= 250 }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let identity = String(decoding: try encoder.encode(Identity(version: 1, term: term, acceptedVariants: variants)), as: UTF8.self)
        return Item(id: id, itemTypeID: typeID, fields: [
            .init(fieldID: target.id, value: .text(term.expression, lang: term.language)),
            .init(fieldID: reading.id, value: .rich([
                Span(String(sentence[..<match.lowerBound])),
                Span(String(sentence[match]), styles: [.bold]),
                Span(String(sentence[match.upperBound...])),
            ].filter { !$0.text.isEmpty })),
            .init(fieldID: meaning.id, value: .text(gloss, lang: VocabularyTerm.languageCode(draft.meaningLanguage))),
            .init(fieldID: cloze.id, value: .cloze(production, blanks: [span])),
            .init(fieldID: metadata.id, value: .text(identity)),
            .init(fieldID: source.id, value: draft.source.map { .text(String($0.prefix(2_000))) } ?? .empty),
        ], deckID: draft.deckID)
    }

    private static func containsContext(in sentence: String, outside span: Range<String.Index>) -> Bool {
        sentence[..<span.lowerBound].contains(where: \.isLetter)
            || sentence[span.upperBound...].contains(where: \.isLetter)
    }

    public static func authoringFields(in itemType: ItemType) -> [FieldDef] {
        guard itemType.id == typeID else { return itemType.fields }
        return itemType.fields.filter { $0.id != metadata.id }
    }

    public static func term(in item: Item) -> VocabularyTerm? {
        guard let identity = identity(in: item),
              case let .text(expression, language)? = item.value(for: target.id),
              VocabularyTerm.normalized(expression) == VocabularyTerm.normalized(identity.term.expression),
              language == nil || language == identity.term.language else { return nil }
        return try? identity.term.validated()
    }

    private static func identity(in item: Item) -> Identity? {
        guard item.itemTypeID == typeID, case let .text(json, _)? = item.value(for: metadata.id),
              let identity = try? JSONDecoder().decode(Identity.self, from: Data(json.utf8)),
              identity.version == 1 else { return nil }
        return identity
    }

    public static func supportsTypedResponse(_ card: DueCard) -> Bool {
        card.template.interaction == .cloze && card.template.id == productionID && term(in: card.item) != nil
    }

    public static func productionAnswer(for card: DueCard) -> String? {
        guard supportsTypedResponse(card) else { return nil }
        return productionAnswer(in: card.item, group: card.card.clozeGroup)
    }

    private static func productionAnswer(in item: Item, group: Int?) -> String? {
        guard let group, case let .cloze(sentence, blanks)? = item.value(for: cloze.id),
              blanks.count == 1, let blank = ClozeValidation.sanitize(text: sentence, blanks: blanks).first,
              blank.group == group else { return nil }
        return String(sentence.dropFirst(blank.start).prefix(blank.length))
    }

    public static func studyComponents(for template: Template, from item: Item, clozeGroup: Int?) -> [ResolvedTemplateComponent] {
        var components = SideContent.resolvedComponents(for: template, from: item)
        if template.id == productionID, let answer = productionAnswer(in: item, group: clozeGroup),
           let index = components.firstIndex(where: { $0.purpose == .expectedAnswer }) {
            components[index].value = .text(answer, lang: term(in: item)?.language)
        }
        return components
    }

    public static func check(_ response: String, for card: DueCard) -> AnswerEvaluation {
        guard let answer = productionAnswer(for: card), let identity = identity(in: card.item) else { return .unavailable }
        func compare(_ value: String) -> String {
            value.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return ([answer] + identity.acceptedVariants).contains { compare($0) == compare(response) } ? .correct : .incorrect
    }

    static func prompt(for card: Card, item: Item, type: ItemType) -> String? {
        guard let term = term(in: item), let actual = type.templates.first(where: { $0.id == card.templateID }),
              let expected = itemType.templates.first(where: { $0.id == card.templateID }), actual == expected else { return nil }
        if card.templateID == productionID, productionAnswer(in: item, group: card.clozeGroup) == nil { return nil }
        let fieldIDs = card.templateID == readingID ? [reading.id, meaning.id] : [cloze.id, meaning.id, metadata.id]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let content = fieldIDs.map { fieldID -> ContentValue? in
            let value = item.value(for: fieldID)
            if fieldID == reading.id, case let .rich(spans)? = value {
                return .rich(spans.map { Span($0.text, styles: $0.styles.contains(.bold) ? [.bold] : []) })
            }
            return value
        }
        guard let values = try? encoder.encode(content) else { return nil }
        return SHA256.hash(data: Data(term.id.utf8) + values).map { String(format: "%02x", $0) }.joined()
    }
}
