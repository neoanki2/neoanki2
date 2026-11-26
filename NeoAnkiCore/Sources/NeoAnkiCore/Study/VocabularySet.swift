import CryptoKit
import Foundation

public struct VocabularyTerm: Codable, Hashable, Sendable, Identifiable {
    public let language: String
    public let expression: String
    public let sense: String?
    /// The dictionary form this spelling belongs to, such as *книга* for *книжки*. It groups
    /// inflected forms without changing the term's identity.
    public let lemma: String?

    public init(language: String, expression: String, sense: String? = nil, lemma: String? = nil) {
        self.language = Self.languageCode(language)
        self.expression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sense = sense?.trimmingCharacters(in: .whitespacesAndNewlines)
        let lemma = lemma?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.lemma = lemma?.isEmpty == false ? lemma : nil
    }

    public var id: String {
        let parts = [language, Self.normalized(expression), Self.normalized(sense ?? "")]
        return parts.map { "\($0.utf8.count):\($0)" }.joined()
    }

    /// The same term without a meaning, which is what a reading judgment applies to.
    public var withoutSense: Self { Self(language: language, expression: expression, lemma: lemma) }

    public static func languageCode(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-").lowercased()
    }

    public static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Languages whose dictionaries mark stress with combining accents that ordinary text omits.
    static let stressMarkedLanguages: Set<String> = ["uk", "ru", "be"]
    /// Languages that write the same apostrophe with several characters.
    static let apostropheLanguages: Set<String> = ["uk", "be"]

    /// Compare spellings as a reader would. Matching ignores case, spacing, and, for some languages,
    /// stress marks and apostrophe variants. Keep in sync with `VocabularyMatchKey` in
    /// NeoAnkiVocabularyKit and `matchKey` in the Chrome companion (`docs/vocabulary-match-keys.json`).
    public static func matchKey(_ text: String, language: String) -> String {
        let primary = languageCode(language).split(separator: "-").first.map(String.init) ?? ""
        // Lowercasing maps a final capital sigma to σ in Swift but to ς in JavaScript; use σ everywhere.
        var value = normalized(text).replacingOccurrences(of: "\u{3C2}", with: "\u{3C3}")
        if stressMarkedLanguages.contains(primary) {
            let scalars = value.decomposedStringWithCanonicalMapping.unicodeScalars
                .filter { $0.value != 0x301 && $0.value != 0x300 }
            value = String(String.UnicodeScalarView(scalars)).precomposedStringWithCanonicalMapping
        }
        if apostropheLanguages.contains(primary) {
            value = value.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{02BC}", with: "'")
        }
        return value
    }

    public var matchKey: String { Self.matchKey(expression, language: language) }
    public var lemmaKey: String { Self.matchKey(lemma ?? expression, language: language) }

    public func validated() throws -> Self {
        let value = Self(language: language, expression: expression, sense: sense, lemma: lemma)
        guard Self.isLanguageCode(value.language), !value.expression.isEmpty, value.expression.count <= 250,
              (value.sense?.count ?? 0) <= 250, (value.lemma?.count ?? 0) <= 250 else { throw VocabularySetError.invalidTerm }
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

public enum VocabularyJudgment: String, Codable, Sendable, CaseIterable {
    case known, unfamiliar, reviewHistory
    /// Hide the term from reading highlights and word counts, for names, brands, and loanwords.
    case ignored
    /// A judgment written by a newer NeoAnki2 version. It is stored unchanged and read as no judgment.
    case unrecognized

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unrecognized
    }

    /// Values a person or client may record. `unrecognized` exists only to read newer data.
    public static let recordable: [Self] = [.known, .unfamiliar, .ignored, .reviewHistory]

    /// A judgment that overrides the estimate from reviews.
    public var isExplicit: Bool { self == .known || self == .unfamiliar || self == .ignored }
}

public struct VocabularyJudgmentChange: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let term: VocabularyTerm
    public let judgment: VocabularyJudgment
    public let changedAt: Date
    /// Groups the changes of one bulk action so it can be undone together.
    public let batchID: UUID?
    /// Why the judgment was recorded when a person did not record it directly.
    public let origin: VocabularyJudgmentOrigin?

    public init(id: UUID, term: VocabularyTerm, judgment: VocabularyJudgment, changedAt: Date,
                batchID: UUID? = nil, origin: VocabularyJudgmentOrigin? = nil) {
        self.id = id
        self.term = term
        self.judgment = judgment
        self.changedAt = changedAt
        self.batchID = batchID
        self.origin = origin
    }

    private enum CodingKeys: String, CodingKey {
        case id, term, judgment, changedAt, batchID, origin, ignored
    }

    // Releases before Ignored reject unknown judgment values and would stop syncing. Ignored is
    // therefore written as `unfamiliar` plus a flag those releases skip, so they show the term
    // as not known instead of failing.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        term = try container.decode(VocabularyTerm.self, forKey: .term)
        let decoded = try container.decode(VocabularyJudgment.self, forKey: .judgment)
        judgment = try container.decodeIfPresent(Bool.self, forKey: .ignored) == true ? .ignored : decoded
        changedAt = try container.decode(Date.self, forKey: .changedAt)
        batchID = try container.decodeIfPresent(UUID.self, forKey: .batchID)
        origin = try? container.decodeIfPresent(VocabularyJudgmentOrigin.self, forKey: .origin)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(term, forKey: .term)
        try container.encode(judgment == .ignored ? .unfamiliar : judgment, forKey: .judgment)
        if judgment == .ignored { try container.encode(true, forKey: .ignored) }
        try container.encode(changedAt, forKey: .changedAt)
        try container.encodeIfPresent(batchID, forKey: .batchID)
        try container.encodeIfPresent(origin, forKey: .origin)
    }
}

public enum VocabularyJudgmentOrigin: String, Codable, Sendable {
    /// Kept from review evidence when the cards that supplied it were deleted.
    case archivedReviews
}

/// What a learner sees for a term while reading.
public enum VocabularyReadingState: String, Codable, Sendable, CaseIterable {
    case known, learning, unfamiliar, unassessed, ignored
}

public struct VocabularyStatus: Codable, Equatable, Identifiable, Sendable {
    public let term: VocabularyTerm
    public var judgment: VocabularyJudgment?
    public var readingMature = false
    public var clozeMature = false
    public var hasCards = false
    /// The state used when this spelling appears in text, combining every meaning of the term.
    public var expressionState: VocabularyReadingState?
    public var origin: VocabularyJudgmentOrigin?
    /// When the latest explicit judgment was recorded.
    public var judgedAt: Date?
    public var id: String { term.id }

    public init(term: VocabularyTerm, judgment: VocabularyJudgment? = nil, readingMature: Bool = false,
                clozeMature: Bool = false, hasCards: Bool = false, expressionState: VocabularyReadingState? = nil,
                origin: VocabularyJudgmentOrigin? = nil, judgedAt: Date? = nil) {
        self.term = term
        self.judgment = judgment
        self.readingMature = readingMature
        self.clozeMature = clozeMature
        self.hasCards = hasCards
        self.expressionState = expressionState
        self.origin = origin
        self.judgedAt = judgedAt
    }

    /// The learner's explicit judgment, ignoring review-history resets and values from newer releases.
    public var explicitJudgment: VocabularyJudgment? {
        judgment.flatMap { $0.isExplicit ? $0 : nil }
    }

    public var isKnown: Bool {
        switch explicitJudgment {
        case .known: true
        case .unfamiliar, .ignored: false
        default: readingMature
        }
    }

    /// The state of this exact term, before meanings of the same spelling are combined.
    public var state: VocabularyReadingState {
        switch explicitJudgment {
        case .ignored: .ignored
        case .known: .known
        case .unfamiliar: hasCards ? .learning : .unfamiliar
        default: readingMature ? .known : hasCards ? .learning : .unassessed
        }
    }

    /// One rule for every surface: an explicit judgment of the word as a whole wins; otherwise the
    /// spelling is known if any meaning is known and learning if any meaning has cards.
    public static func combinedState(of statuses: [VocabularyStatus]) -> VocabularyReadingState {
        switch latestGeneral(in: statuses)?.explicitJudgment {
        case .known: return .known
        case .ignored: return .ignored
        case .unfamiliar: return statuses.contains(where: \.hasCards) ? .learning : .unfamiliar
        default: break
        }
        let states = statuses.map(\.state)
        if states.contains(.known) { return .known }
        if states.contains(.learning) { return .learning }
        if states.contains(.unfamiliar) { return .unfamiliar }
        return .unassessed
    }

    /// The sense-less row whose explicit judgment is the most recent. Several can exist when spellings
    /// differ only in what matching ignores, such as stress marks.
    static func latestGeneral(in statuses: [VocabularyStatus]) -> VocabularyStatus? {
        statuses.filter { ($0.term.sense ?? "").isEmpty }.max { left, right in
            let l = left.explicitJudgment == nil ? Date.distantPast : left.judgedAt ?? .distantPast
            let r = right.explicitJudgment == nil ? Date.distantPast : right.judgedAt ?? .distantPast
            return l != r ? l < r : left.term.id > right.term.id
        }
    }

    /// The key that groups the meanings of one spelling in one language.
    public var expressionKey: String { term.language + "\u{1F}" + term.matchKey }
    /// The key that groups the inflected forms of one dictionary form in one language.
    public var lemmaKey: String { term.language + "\u{1F}" + term.lemmaKey }

    /// The state of a dictionary form: a judgment written on the dictionary form itself wins;
    /// otherwise the best-supported state among its forms applies. Ignoring a form never hides others.
    public static func lemmaState(of statuses: [VocabularyStatus]) -> VocabularyReadingState {
        let own = statuses.filter { $0.term.matchKey == $0.term.lemmaKey }
        if latestGeneral(in: own)?.explicitJudgment != nil {
            return combinedState(of: own)
        }
        let states = Set(statuses.map(\.state))
        for state in [VocabularyReadingState.known, .learning, .unfamiliar] where states.contains(state) { return state }
        return states == [.ignored] && !own.isEmpty ? .ignored : .unassessed
    }

    /// Fill `expressionState` for every row.
    public static func combiningExpressions(_ statuses: [VocabularyStatus]) -> [VocabularyStatus] {
        let groups = Dictionary(grouping: statuses, by: \.expressionKey).mapValues(combinedState(of:))
        return statuses.map { status in
            var status = status
            status.expressionState = groups[status.expressionKey]
            return status
        }
    }

    private enum CodingKeys: String, CodingKey {
        case term, judgment, readingMature, clozeMature, hasCards, state, expressionState, origin, judgedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        term = try container.decode(VocabularyTerm.self, forKey: .term)
        judgment = try container.decodeIfPresent(VocabularyJudgment.self, forKey: .judgment)
        readingMature = try container.decodeIfPresent(Bool.self, forKey: .readingMature) ?? false
        clozeMature = try container.decodeIfPresent(Bool.self, forKey: .clozeMature) ?? false
        hasCards = try container.decodeIfPresent(Bool.self, forKey: .hasCards) ?? false
        expressionState = try? container.decodeIfPresent(VocabularyReadingState.self, forKey: .expressionState)
        origin = try? container.decodeIfPresent(VocabularyJudgmentOrigin.self, forKey: .origin)
        judgedAt = try container.decodeIfPresent(Date.self, forKey: .judgedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(term, forKey: .term)
        try container.encodeIfPresent(judgment == .unrecognized ? nil : judgment, forKey: .judgment)
        try container.encode(readingMature, forKey: .readingMature)
        try container.encode(clozeMature, forKey: .clozeMature)
        try container.encode(hasCards, forKey: .hasCards)
        try container.encode(state, forKey: .state)
        try container.encode(expressionState ?? state, forKey: .expressionState)
        try container.encodeIfPresent(origin, forKey: .origin)
        try container.encodeIfPresent(judgedAt, forKey: .judgedAt)
    }
}

/// A compact view of a language's vocabulary for highlighting text. Keys are match keys.
public struct VocabularySnapshot: Codable, Equatable, Sendable {
    /// Changes whenever any vocabulary state may have changed. Compare for equality only.
    public let version: String
    public let language: String
    /// Combined state of each spelling, by `VocabularyTerm.matchKey`.
    public let expressions: [String: VocabularyReadingState]
    /// Combined state of each dictionary form, by `VocabularyTerm.lemmaKey`.
    public let lemmas: [String: VocabularyReadingState]

    /// The version is a digest of the language and its states, so it changes only when something a
    /// reader would see changes, and never matches another language's snapshot.
    public init(language: String, statuses: [VocabularyStatus]) {
        self.language = language
        let rows = statuses.filter { $0.term.language == language }
        expressions = Dictionary(grouping: rows, by: \.term.matchKey).mapValues(VocabularyStatus.combinedState(of:))
        lemmas = Dictionary(grouping: rows, by: \.term.lemmaKey).mapValues(VocabularyStatus.lemmaState(of:))
        var digest = SHA256()
        digest.update(data: Data("v1\u{1F}\(language)".utf8))
        for (name, map) in [("e", expressions), ("l", lemmas)] {
            for key in map.keys.sorted() {
                digest.update(data: Data("\u{1E}\(name)\u{1F}\(key)\u{1F}\(map[key]!.rawValue)".utf8))
            }
        }
        version = digest.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The state of a word in text, given the dictionary forms a pack resolves it to.
    public func state(of text: String, lemmas candidates: [String] = []) -> VocabularyReadingState {
        let key = VocabularyTerm.matchKey(text, language: language)
        if let state = expressions[key] { return state }
        let states = Set(candidates.map { VocabularyTerm.matchKey($0, language: language) }
            .map { lemmas[$0] ?? expressions[$0] ?? .unassessed })
        if !states.isEmpty, states.allSatisfy({ $0 == .known || $0 == .ignored }) {
            return states.contains(.known) ? .known : .ignored
        }
        if states.contains(.learning) { return .learning }
        return .unassessed
    }
}

/// One requested change in a bulk judgment.
public struct VocabularyJudgmentEntry: Codable, Equatable, Sendable {
    public var term: VocabularyTerm
    public var judgment: VocabularyJudgment

    public init(term: VocabularyTerm, judgment: VocabularyJudgment) {
        self.term = term
        self.judgment = judgment
    }
}

public struct VocabularyBatchReceipt: Codable, Equatable, Sendable {
    public let batchID: UUID
    /// Judgments written by this batch.
    public let recorded: Int
    /// Requested judgments that already applied and were skipped.
    public let unchanged: Int
    /// The changes the batch wrote, so callers can update local state without a reload.
    public let changes: [VocabularyJudgmentChange]
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
    case invalidJudgment, batchTooLarge, batchNotFound
    public var errorDescription: String? {
        switch self {
        case .invalidTerm: "Choose a language and enter a word or phrase."
        case .missingMeaning: "Enter a short meaning and choose its language."
        case .invalidOccurrence: "Choose the exact word or phrase in a complete example sentence."
        case .exposedAnswer: "Choose a sentence that shows the missing form only once."
        case .changedPreset: "The Vocabulary Set card setup was edited. Restore it before adding another set."
        case .idConflict: "This request already created a different vocabulary set."
        case .invalidJudgment: "Choose Known, Not known, Ignored, or Use review history."
        case .batchTooLarge: "Import at most 20,000 words at a time."
        case .batchNotFound: "That bulk change is no longer available to undo."
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
