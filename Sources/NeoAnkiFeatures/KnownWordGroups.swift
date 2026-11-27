import Foundation
import NeoAnkiCore
import NeoAnkiVocabularyKit

public struct KnownWordGroup: Identifiable, Sendable {
    public let term: VocabularyTerm
    private let statuses: [VocabularyStatus]

    public var id: String { term.language + "\u{1F}" + term.matchKey }
    public var clozeMature: Bool { statuses.contains(where: \.clozeMature) }
    public var hasJudgment: Bool { statuses.contains { $0.explicitJudgment != nil } }

    public var state: VocabularyReadingState {
        let state = VocabularyStatus.lemmaState(of: statuses)
        if state == .unfamiliar, statuses.contains(where: \.hasCards) { return .learning }
        // A form can be ignored without hiding other forms in Reading Mode. Keep
        // its group accessible in the Ignored list when it has no other status.
        if state == .unassessed, statuses.contains(where: { $0.state == .ignored }) { return .ignored }
        return state
    }

    public var knownOrigin: VocabularyJudgmentOrigin? {
        markedKnown ? nil : statuses.first { $0.explicitJudgment == .known }?.origin
    }

    public var markedKnown: Bool {
        statuses.contains { $0.explicitJudgment == .known && $0.origin == nil }
    }

    public var sense: String? {
        let senses = Set(statuses.compactMap(\.term.sense).filter { !$0.isEmpty })
        return senses.count == 1 ? senses.first : nil
    }

    public func matches(_ query: String) -> Bool {
        term.expression.localizedStandardContains(query) || statuses.contains {
            $0.term.expression.localizedStandardContains(query) || ($0.term.sense?.localizedStandardContains(query) ?? false)
        }
    }

    public func entries(for judgment: VocabularyJudgment) -> [VocabularyJudgmentEntry] {
        let terms = judgment == .reviewHistory
            ? statuses.filter { $0.explicitJudgment != nil }.map(\.term)
            : [term]
        return terms.map { .init(term: $0, judgment: judgment) }
    }

    static func group(_ statuses: [VocabularyStatus], dictionaryForms: [String: [String]]) -> [Self] {
        var recordedForms: [String: [String]] = [:]
        for status in statuses {
            if let lemma = status.term.lemma {
                recordedForms[status.expressionKey, default: []].append(lemma)
            }
        }
        let resolved = statuses.map { status in
            let term = status.term
            guard term.lemma == nil else { return status }
            let candidates = recordedForms[status.expressionKey] ?? dictionaryForms[status.expressionKey] ?? []
            let keys = Set(candidates.map { VocabularyTerm.matchKey($0, language: term.language) })
            guard keys.count == 1, let lemma = candidates.first else { return status }
            return VocabularyStatus(term: .init(language: term.language, expression: term.expression, sense: term.sense, lemma: lemma),
                                    judgment: status.judgment, readingMature: status.readingMature, clozeMature: status.clozeMature,
                                    hasCards: status.hasCards, expressionState: status.expressionState,
                                    origin: status.origin, judgedAt: status.judgedAt)
        }
        return Dictionary(grouping: resolved, by: \.lemmaKey).values.map { members in
            // A recorded dictionary headword is preferred to incidental page casing.
            let term = members[0].term
            let headword = members.compactMap(\.term.lemma).sorted().first
            return Self(term: .init(language: term.language, expression: headword ?? term.expression, lemma: headword),
                        statuses: members)
        }.sorted { $0.term.expression.localizedStandardCompare($1.term.expression) == .orderedAscending }
    }
}

/// Resolves old entries for display without rewriting imported judgments or study cards.
public actor KnownWordsIndex {
    private var openedPacks: [URL: Task<VocabularyPack, Error>] = [:]

    public init() {}

    public func groups(for statuses: [VocabularyStatus], language: String, packRoot: URL?) async -> [KnownWordGroup] {
        let words = Set(statuses.lazy.filter { $0.term.lemma == nil }.map(\.term.expression))
        guard !words.isEmpty, let packRoot else { return KnownWordGroup.group(statuses, dictionaryForms: [:]) }
        let languageKey = VocabularyMatchKey.primaryLanguage(language)
        let installed = (try? await InstalledVocabularyPackStore(rootURL: packRoot).installedPacks()) ?? []
        let urls = Set(installed.map(\.packageURL))
        openedPacks = openedPacks.filter { urls.contains($0.key) }
        var forms: [String: [String]] = [:]
        let expressions = words.sorted()
        let limit = VocabularyPack.maximumResolvedWords
        for descriptor in installed where descriptor.languages.contains(where: { VocabularyMatchKey.primaryLanguage($0) == languageKey }) {
            if Task.isCancelled { break }
            let url = descriptor.packageURL
            let opening = openedPacks[url] ?? Task { try await VocabularyPack.open(at: url) }
            openedPacks[url] = opening
            guard let pack = try? await opening.value else {
                openedPacks[url] = nil
                continue
            }
            for offset in stride(from: 0, to: expressions.count, by: limit) {
                let batch = Array(expressions[offset..<min(offset + limit, expressions.count)])
                if let resolved = try? await pack.resolveDictionaryForms(of: batch, language: language) {
                    for (word, candidates) in resolved {
                        let key = language + "\u{1F}" + VocabularyTerm.matchKey(word, language: language)
                        forms[key, default: []].append(contentsOf: candidates)
                    }
                }
            }
        }
        return KnownWordGroup.group(statuses, dictionaryForms: forms)
    }
}
