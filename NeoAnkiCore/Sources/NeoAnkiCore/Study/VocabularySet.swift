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

public struct VocabularySetMatch: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let exampleCount: Int
    public let firstExample: String
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
    public static let legacyTypeID = uuid("1000")
    static let legacyReadingID = uuid("1001")
    static let legacyProductionID = uuid("1002")
    public static let typeID = uuid("1100")
    public static let readingID = uuid("1101")
    public static let productionID = uuid("1102")
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

    static let legacyItemType = ItemType(id: legacyTypeID, name: "Vocabulary Set",
        fields: [target, reading, meaning, cloze, metadata, source], templates: [
            .init(id: legacyReadingID, name: "Understand in context", layout: .focus, components: [
                .init(id: uuid("1026"), region: .label, purpose: .supporting,
                      source: .literal("What does the highlighted expression mean here?")),
                .init(id: uuid("1020"), region: .primary, purpose: .question, source: .field(reading.id)),
                .init(id: uuid("1021"), region: .secondary, purpose: .expectedAnswer, source: .field(meaning.id),
                      presentation: .init(reveal: .hiddenUntilAnswer)),
                .init(id: uuid("1022"), region: .supporting, purpose: .supporting, source: .field(source.id),
                      presentation: .init(reveal: .hiddenUntilAnswer)),
            ], interaction: .reveal, skill: .init(input: .text, output: .freeResponse, operation: .recall)),
            .init(id: legacyProductionID, name: "Complete the sentence", layout: .focus, components: [
                .init(id: uuid("1023"), region: .primary, purpose: .question, source: .field(cloze.id)),
                .init(id: uuid("1024"), region: .supporting, purpose: .supporting, source: .field(meaning.id)),
                .init(id: uuid("1025"), region: .secondary, purpose: .expectedAnswer, source: .field(cloze.id),
                      presentation: .init(reveal: .hiddenUntilAnswer)),
            ], interaction: .cloze, skill: .init(input: .text, output: .freeResponse, operation: .recall)),
        ])

    private static let wordField = FieldDef(id: uuid("1110"), name: target.name, type: .text, isRequired: true)
    private static let meaningField = FieldDef(id: uuid("1112"), name: meaning.name, type: .text, isRequired: true)
    private static let termField = FieldDef(id: uuid("1114"), name: metadata.name, type: .text, isRequired: true)
    private static let readingColumn = FieldDef(id: uuid("1111"), name: reading.name, type: .richText)
    private static let clozeColumn = FieldDef(id: uuid("1113"), name: cloze.name, type: .cloze)
    private static let sourceColumn = FieldDef(id: uuid("1115"), name: source.name, type: .text)
    private static let acceptedColumn = FieldDef(id: uuid("1116"), name: "Accepted answers", type: .richText)
    private static let recognizeColumn = FieldDef(id: uuid("1117"), name: "Recognition", type: .checkbox)
    private static let produceColumn = FieldDef(id: uuid("1118"), name: "Cloze card", type: .checkbox)
    private static let originalTermColumn = FieldDef(id: uuid("1119"), name: "Original vocabulary identity", type: .text)
    static let courseSentence = FieldDef(id: uuid("1120"), name: "Course sentence", type: .text)
    static let importedRecognitionPrompt = FieldDef(id: uuid("1121"), name: "Imported recognition prompt", type: .text)
    static let examples = ItemList(id: uuid("1130"), name: "Examples", columns: [
        readingColumn, clozeColumn, sourceColumn, acceptedColumn, recognizeColumn, produceColumn, originalTermColumn
    ])

    public static let itemType = ItemType(id: typeID, name: "Vocabulary Set with Examples",
        fields: [wordField, meaningField, termField],
        templates: legacyItemType.templates.map { legacy in
            let reading = legacy.id == legacyReadingID
            let fields = [Self.reading.id: readingColumn.id, cloze.id: clozeColumn.id,
                          meaning.id: meaningField.id, source.id: sourceColumn.id]
            return Template(
                id: reading ? readingID : productionID, name: legacy.name, layout: legacy.layout,
                components: legacy.components.map { component in
                    var mapped = component
                    if case let .field(id) = component.source, let replacement = fields[id] {
                        mapped.source = .field(replacement)
                    }
                    return mapped
                },
                interaction: legacy.interaction, skill: legacy.skill,
                generateWhen: .fieldNotEmpty(reading ? readingColumn.id : clozeColumn.id),
                cardCreation: CardCreation(listIDs: [examples.id],
                                           checkedFieldIDs: [reading ? recognizeColumn.id : produceColumn.id]),
                responseOverride: reading ? nil : .type
            )
        }, lists: [examples])

    static let supportedItemTypeIDs = [legacyTypeID, typeID]
    static func isReading(_ templateID: UUID) -> Bool { templateID == readingID || templateID == legacyReadingID }
    static func isProduction(_ templateID: UUID) -> Bool { templateID == productionID || templateID == legacyProductionID }

    static func courseRecognitionTemplate(in type: ItemType) -> Template? {
        guard type.id == typeID, type.sourceField(courseSentence.id)?.type == .text else { return nil }
        return type.templates.first {
            $0.promptFormat == .standard && $0.cardCreation?.listIDs == [examples.id]
                && $0.cardCreation?.checkedFieldIDs == [recognizeColumn.id]
                && $0.generateWhen == .fieldNotEmpty(courseSentence.id)
        }
    }

    public static func isCourseRecognition(_ card: DueCard) -> Bool {
        card.template.id == courseRecognitionTemplate(in: card.itemType)?.id
    }

    static func hasCourseExample(in item: Item) -> Bool {
        item.itemTypeID == typeID && examples.rows(in: item).contains { row in
            row.values.contains { $0.fieldID == courseSentence.id && !$0.value.isEmpty }
        }
    }

    /// The course can add optional fields and a recognition layout while normal
    /// examples continue to use the two standard setups and the same identities.
    static func supportsDefinition(_ type: ItemType) -> Bool {
        guard type.id == typeID, type.name == itemType.name,
              type.fields.starts(with: itemType.fields),
              type.fields.dropFirst(itemType.fields.count).allSatisfy({ !$0.isRequired }),
              type.templates.starts(with: itemType.templates),
              type.lists.count == 1, let list = type.lists.first,
              list.id == examples.id, list.name == examples.name, list.sharedRows == nil,
              list.columns.starts(with: examples.columns) else { return false }
        let optionalColumns = list.columns.dropFirst(examples.columns.count)
        let optionalIDs = Set(optionalColumns.map(\.id))
        return optionalColumns.allSatisfy { !$0.isRequired } &&
            type.templates.dropFirst(itemType.templates.count).allSatisfy { template in
                template.cardCreation?.listIDs == [examples.id]
                    && template.generateWhen.map { requiresExtensionValue($0, from: optionalIDs) } == true
            }
    }

    private static func requiresExtensionValue(_ condition: SlotCondition, from fields: Set<UUID>) -> Bool {
        switch condition {
        case let .fieldNotEmpty(id): fields.contains(id)
        case .fieldEmpty: false
        case let .all(conditions): conditions.contains { requiresExtensionValue($0, from: fields) }
        case let .any(conditions): !conditions.isEmpty && conditions.allSatisfy { requiresExtensionValue($0, from: fields) }
        }
    }

    /// Combine compatible additions while preserving existing field and setup identities.
    static func extending(_ existing: ItemType, with incoming: ItemType) -> ItemType? {
        guard supportsDefinition(existing), supportsDefinition(incoming),
              var list = existing.lists.first, let incomingList = incoming.lists.first,
              let fields = merging(existing.fields, with: incoming.fields),
              let templates = merging(existing.templates, with: incoming.templates),
              let columns = merging(list.columns, with: incomingList.columns) else { return nil }
        list.columns = columns
        var result = existing
        result.fields = fields
        result.templates = templates
        result.lists = [list]
        guard (try? ItemTypeValidation.validate(result)) != nil else { return nil }
        return result
    }

    private static func merging<T: Identifiable & Equatable>(_ existing: [T], with incoming: [T]) -> [T]? {
        var result = existing
        let byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for value in incoming {
            if let prior = byID[value.id] {
                guard prior == value else { return nil }
            } else {
                result.append(value)
            }
        }
        return result
    }

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
        try makeExampleItem(draft, id: id, recognition: true, cloze: true)
    }

    static func makeExampleItem(_ draft: VocabularySetDraft, id: UUID, recognition: Bool, cloze: Bool) throws -> Item {
        guard recognition || cloze else { throw VocabularySetError.invalidOccurrence }
        let legacy = try makeLegacyItem(draft, id: id)
        return try modernItem(from: legacy, recognition: recognition, production: cloze)
    }

    static func makeLegacyItem(_ draft: VocabularySetDraft, id: UUID) throws -> Item {
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
        return Item(id: id, itemTypeID: legacyTypeID, fields: [
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

    static func modernItem(from legacy: Item, recognition: Bool = true, production: Bool = true) throws -> Item {
        guard let identity = identity(in: legacy) else { throw VocabularySetError.invalidTerm }
        let row = ItemListRow(id: legacy.id, values: [
            FieldValue(fieldID: readingColumn.id, value: legacy.value(for: reading.id) ?? .empty),
            FieldValue(fieldID: clozeColumn.id, value: legacy.value(for: cloze.id) ?? .empty),
            FieldValue(fieldID: sourceColumn.id, value: legacy.value(for: source.id) ?? .empty),
            FieldValue(fieldID: acceptedColumn.id, value: .rich(identity.acceptedVariants.enumerated().flatMap { index, answer in
                index == 0 ? [Span(answer, styles: [.code])] : [Span("\n"), Span(answer, styles: [.code])]
            })),
            FieldValue(fieldID: originalTermColumn.id, value: .text(try encodedIdentity(Identity(version: 1, term: identity.term, acceptedVariants: [])))),
            FieldValue(fieldID: recognizeColumn.id, value: .checkbox(recognition)),
            FieldValue(fieldID: produceColumn.id, value: .checkbox(production))
        ])
        return Item(id: legacy.id, itemTypeID: typeID, fields: [
            FieldValue(fieldID: wordField.id, value: legacy.value(for: target.id) ?? .empty),
            FieldValue(fieldID: meaningField.id, value: legacy.value(for: meaning.id) ?? .empty),
            FieldValue(fieldID: termField.id, value: .text(try encodedIdentity(Identity(version: 1, term: identity.term, acceptedVariants: [])))),
            FieldValue(fieldID: examples.id, value: .rows([row]))
        ], tags: legacy.tags, deckID: legacy.deckID)
    }

    static func matches(_ left: Item, _ right: Item) -> Bool {
        guard let termID = term(in: left)?.id else { return false }
        return left.deckID == right.deckID && termID == term(in: right)?.id
            && left.value(for: meaningField.id) == right.value(for: meaningField.id)
    }

    static func firstExampleLabel(in item: Item) -> String {
        let values = examples.rows(in: item).first?.values ?? []
        for field in [readingColumn, courseSentence] {
            if let value = values.first(where: { $0.fieldID == field.id })?.value, !value.isEmpty {
                return ItemDisplay.plainText(from: value)
            }
        }
        return ""
    }

    private static func encodedIdentity(_ identity: Identity) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(identity), as: UTF8.self)
    }

    private static func acceptedAnswers(in item: Item) -> [String] {
        if item.itemTypeID == legacyTypeID { return identity(in: item)?.acceptedVariants ?? [] }
        guard let value = item.value(for: acceptedColumn.id) else { return [] }
        if case let .rich(spans) = value {
            let originalAnswers = spans.filter { $0.styles == [.code] }.map(\.text)
            if !originalAnswers.isEmpty { return originalAnswers }
        }
        return ItemDisplay.plainText(from: value).components(separatedBy: .newlines).filter { !$0.isEmpty }
    }

    private static func containsContext(in sentence: String, outside span: Range<String.Index>) -> Bool {
        sentence[..<span.lowerBound].contains(where: \.isLetter)
            || sentence[span.upperBound...].contains(where: \.isLetter)
    }

    public static func authoringFields(in itemType: ItemType) -> [FieldDef] {
        guard supportedItemTypeIDs.contains(itemType.id) else { return itemType.fields }
        return itemType.fields.filter { $0.id != metadata.id && $0.id != termField.id }
    }

    public static func authoringList(_ list: ItemList, in itemType: ItemType) -> ItemList {
        guard itemType.id == typeID, list.id == examples.id else { return list }
        var visible = list
        visible.columns.removeAll { $0.id == originalTermColumn.id || $0.id == importedRecognitionPrompt.id }
        return visible
    }

    public static func term(in item: Item) -> VocabularyTerm? {
        guard let identity = identity(in: item),
              case let .text(expression, language)? = item.value(for: item.itemTypeID == legacyTypeID ? target.id : wordField.id),
              VocabularyTerm.normalized(expression) == VocabularyTerm.normalized(identity.term.expression),
              language == nil || language == identity.term.language else { return nil }
        return try? identity.term.validated()
    }

    private static func identity(in item: Item) -> Identity? {
        guard supportedItemTypeIDs.contains(item.itemTypeID),
              case let .text(json, _)? = item.value(for: item.itemTypeID == legacyTypeID ? metadata.id : termField.id),
              let identity = try? JSONDecoder().decode(Identity.self, from: Data(json.utf8)),
              identity.version == 1 else { return nil }
        return identity
    }

    public static func supportsTypedResponse(_ card: DueCard) -> Bool {
        card.template.interaction == .cloze && isProduction(card.template.id)
            && (card.item.itemTypeID == legacyTypeID || card.template.response == .type) && term(in: card.item) != nil
    }

    public static func productionAnswer(for card: DueCard) -> String? {
        guard supportsTypedResponse(card) else { return nil }
        return productionAnswer(in: card.studyItem, group: card.card.clozeGroup)
    }

    private static func productionAnswer(in item: Item, group: Int?) -> String? {
        guard let group, case let .cloze(sentence, blanks)? = item.value(for: item.itemTypeID == legacyTypeID ? cloze.id : clozeColumn.id),
              let blank = ClozeValidation.sanitize(text: sentence, blanks: blanks).first(where: { $0.group == group }) else { return nil }
        return String(sentence.dropFirst(blank.start).prefix(blank.length))
    }

    public static func studyComponents(for template: Template, from item: Item, clozeGroup: Int?) -> [ResolvedTemplateComponent] {
        var components = SideContent.resolvedComponents(for: template, from: item)
        if isProduction(template.id), let answer = productionAnswer(in: item, group: clozeGroup),
           let index = components.firstIndex(where: { $0.purpose == .expectedAnswer }) {
            components[index].value = .text(answer, lang: term(in: item)?.language)
        }
        return components
    }

    public static func check(_ response: String, for card: DueCard) -> AnswerEvaluation {
        guard let answer = productionAnswer(for: card) else { return .unavailable }
        func compare(_ value: String) -> String {
            value.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return ([answer] + acceptedAnswers(in: card.studyItem)).contains { compare($0) == compare(response) } ? .correct : .incorrect
    }

    static func prompt(for card: Card, item: Item, type: ItemType) -> String? {
        let legacy = item.itemTypeID == legacyTypeID
        guard let term = term(in: item),
              let actual = type.templates.first(where: { $0.id == card.templateID }),
              let bound = CardGenerator.boundItem(item, type: type, selections: card.rowSelections) else { return nil }
        if actual.id == courseRecognitionTemplate(in: type)?.id {
            let values = SideContent.resolvedComponents(for: actual, from: bound).map(\.value)
            return fingerprint(term: term, content: CoursePrompt(template: actual, values: values))
        }
        guard actual == (legacy ? legacyItemType : itemType).templates.first(where: { $0.id == card.templateID }) else {
            return nil
        }
        let readingCard = isReading(card.templateID)
        if !readingCard, productionAnswer(in: bound, group: card.clozeGroup) == nil { return nil }
        let gloss = bound.value(for: legacy ? meaning.id : meaningField.id)
        let sentence = bound.value(for: readingCard ? (legacy ? reading.id : readingColumn.id) : (legacy ? cloze.id : clozeColumn.id))
        let content: [ContentValue?]
        if readingCard, case let .rich(spans)? = sentence {
            content = [.rich(spans.map { Span($0.text, styles: $0.styles.contains(.bold) ? [.bold] : []) }), gloss]
        } else if readingCard {
            content = [sentence, gloss]
        } else {
            let identityValue: ContentValue?
            if legacy { identityValue = bound.value(for: metadata.id) }
            else {
                let originalTerm: VocabularyTerm? = if case let .text(json, _)? = bound.value(for: originalTermColumn.id) {
                    (try? JSONDecoder().decode(Identity.self, from: Data(json.utf8)))?.term
                } else { nil }
                identityValue = (try? encodedIdentity(Identity(version: 1, term: originalTerm ?? term, acceptedVariants: acceptedAnswers(in: bound))))
                    .map { .text($0) }
            }
            content = [sentence, gloss, identityValue]
        }
        return fingerprint(term: term, content: content)
    }

    static func importedPrompt(for card: Card, item: Item, type: ItemType) -> String? {
        guard card.templateID == courseRecognitionTemplate(in: type)?.id,
              let bound = CardGenerator.boundItem(item, type: type, selections: card.rowSelections),
              case let .text(prompt, _)? = bound.value(for: importedRecognitionPrompt.id) else { return nil }
        return prompt
    }

    private struct CoursePrompt: Encodable {
        let template: Template
        let values: [ContentValue]
    }

    private static func fingerprint(term: VocabularyTerm, content: some Encodable) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let values = try? encoder.encode(content) else { return nil }
        return SHA256.hash(data: Data(term.id.utf8) + values).map { String(format: "%02x", $0) }.joined()
    }
}
