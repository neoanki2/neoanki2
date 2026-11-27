import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiVocabularyKit

public actor VocabularyExampleLookup {
    public static let shared = VocabularyExampleLookup()

    public struct Example: Identifiable, Sendable {
        public let id: Int
        public let sentence: String
        public let form: String?
        public let citation: String?
    }

    public struct Meaning: Identifiable, Sendable {
        public let id: String
        public let lemma: String
        public let headword: String
        public let text: String
        public let language: String
        public let forms: [String]
        public let examples: [Example]
    }

    private let generator: any ContextGenerating
    private var openedPacks: [URL: Task<VocabularyPack, Error>] = [:]

    public init(generator: any ContextGenerating = AppleContextGenerator()) {
        self.generator = generator
    }

    public func meanings(for expression: String, language: String, meaningLanguage: String, root: URL) async throws -> [Meaning] {
        let packs = try await InstalledVocabularyPackStore(rootURL: root).installedPacks()
        let installedURLs = Set(packs.map(\.packageURL))
        openedPacks = openedPacks.filter { installedURLs.contains($0.key) }
        let primary = Self.primaryLanguage(language)
        var choices: [Meaning] = []
        for installed in packs where installed.languages.contains(where: { Self.primaryLanguage($0) == primary }) {
            try Task.checkCancellation()
            let url = installed.packageURL
            // Managed replacements install at a new URL. Reuse each validated handle
            // while it remains installed, including during overlapping lookups.
            let opening = openedPacks[url] ?? Task { try await VocabularyPack.open(at: url) }
            openedPacks[url] = opening
            let pack: VocabularyPack
            do { pack = try await opening.value }
            catch {
                openedPacks.removeValue(forKey: url)
                throw error
            }
            try Task.checkCancellation()
            for entry in try await pack.search(query: expression, mode: .exact, limit: 20)
            where Self.primaryLanguage(entry.language) == primary {
                let lemma = entry.canonicalForm.text.value
                let forms = entry.forms.map(\.text.value)
                for sense in entry.senses {
                    guard let definition = sense.definitions.first(where: {
                        !$0.text.value.isEmpty &&
                            Self.primaryLanguage($0.text.language ?? meaningLanguage) == Self.primaryLanguage(meaningLanguage)
                    }) else { continue }
                    let text = definition.text.value
                    let id = VocabularyTerm.matchKey(lemma, language: primary) + "\u{1F}" + text
                    let examples = sense.examples.filter {
                        Self.primaryLanguage($0.text.language ?? language) == primary
                    }.enumerated().map { index, example in
                        let sentence = example.text.value
                        let form = example.target?.exactText
                        return Example(id: index, sentence: sentence, form: form,
                                       citation: Self.citation(for: example.provenance))
                    }
                    let choice = Meaning(id: id, lemma: lemma,
                                         headword: entry.forms.first(where: { $0.kind == "stressed" })?.text.value ?? lemma,
                                         text: text, language: definition.text.language ?? meaningLanguage, forms: forms, examples: examples)
                    if let duplicate = choices.firstIndex(where: { $0.id == id }) {
                        if choices[duplicate].examples.count < examples.count { choices[duplicate] = choice }
                    } else {
                        choices.append(choice)
                    }
                }
            }
        }
        return choices
    }

    public func generationAvailability(language: String) async -> ContextCapability {
        await generator.availability(language: language)
    }

    public func generate(target: ContextTarget) async throws -> ContextExample? {
        try await generator.examples(for: target, count: 1, excluding: [], simpler: false).first {
            $0.language.map { Self.primaryLanguage($0) == Self.primaryLanguage(target.language) } ?? true
        }
    }

    public static func citation(for provenance: Provenance?) -> String? {
        guard let provenance else { return nil }
        return [provenance.sourceName ?? provenance.sourceID, provenance.attribution, provenance.sourceURL]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func primaryLanguage(_ code: String) -> String {
        String(VocabularyTerm.languageCode(code).split(separator: "-").first ?? "")
    }
}
