import Foundation

/// Compare spellings as a reader would. Must match `VocabularyTerm.matchKey` in NeoAnkiCore and
/// `matchKey` in the Chrome companion; `NeoAnkiCore/Tests/Fixtures/vocabulary-match-keys.json`
/// holds the shared test vectors.
public enum VocabularyMatchKey {
    static let stressMarkedLanguages: Set<String> = ["uk", "ru", "be"]
    static let apostropheLanguages: Set<String> = ["uk", "be"]
    static let stressableVowels: Set<Character> = ["а", "е", "є", "и", "і", "ї", "о", "у", "ю", "я", "ё", "э", "ы"]

    public static func primaryLanguage(_ language: String) -> String {
        language.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-")
            .lowercased().split(separator: "-").first.map(String.init) ?? ""
    }

    public static func make(_ text: String, language: String) -> String {
        let primary = primaryLanguage(language)
        var value = text.precomposedStringWithCanonicalMapping.lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: "\u{3C2}", with: "\u{3C3}")
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

    /// Spellings a dictionary may store for `key`: as written and, for languages whose dictionaries
    /// mark stress, with an acute accent on each vowel, and with each apostrophe variant.
    static func dictionarySpellings(of key: String, language: String) -> [String] {
        let primary = primaryLanguage(language)
        var spellings = [key]
        if stressMarkedLanguages.contains(primary) {
            let characters = Array(key)
            for (index, character) in characters.enumerated() where stressableVowels.contains(character) {
                var stressed = characters
                stressed.insert("\u{301}", at: index + 1)
                spellings.append(String(stressed))
            }
        }
        if apostropheLanguages.contains(primary), key.contains("'") {
            spellings += spellings.flatMap { spelling in
                ["\u{2019}", "\u{02BC}"].map { spelling.replacingOccurrences(of: "'", with: $0) }
            }
        }
        return spellings
    }
}

public extension VocabularyPack {
    /// The largest number of words resolved in one call.
    static let maximumResolvedWords = 2_000

    /// The dictionary forms each word may belong to, keyed by the word as given. Words the pack
    /// does not contain are omitted. Each word lists at most eight dictionary forms.
    func resolveDictionaryForms(of words: [String], language: String) throws -> [String: [String]] {
        guard words.count <= Self.maximumResolvedWords else {
            throw VocabularyPackError.limitExceeded("resolve at most \(Self.maximumResolvedWords) words at a time")
        }
        let primary = VocabularyMatchKey.primaryLanguage(language)
        var searchKeysByWord: [String: [String]] = [:]
        for word in Set(words) where !word.isEmpty && word.utf8.count <= 256 {
            let key = VocabularyMatchKey.make(word, language: language)
            searchKeysByWord[word] = VocabularyMatchKey.dictionarySpellings(of: key, language: language)
                .map(VocabularySearchKey.make)
        }
        let found = try database.canonicalForms(searchKeys: searchKeysByWord.values.flatMap { $0 },
                                                languagePrimary: primary)
        var result: [String: [String]] = [:]
        for (word, keys) in searchKeysByWord {
            var seen: Set<String> = []
            let forms = keys.flatMap { found[$0] ?? [] }.filter { seen.insert(VocabularyMatchKey.make($0, language: language)).inserted }
            if !forms.isEmpty { result[word] = Array(forms.prefix(8)) }
        }
        return result
    }

    /// Dictionary forms ranked from most to least frequent. `offset` and `limit` select a band;
    /// `sample` picks that many evenly spaced words from the band instead of all of them.
    func frequencyBand(language: String, offset: Int, limit: Int, sample: Int? = nil) throws -> (words: [String], total: Int) {
        guard offset >= 0, (1...20_000).contains(limit) else {
            throw VocabularyPackError.limitExceeded("choose a band of 1 to 20,000 words")
        }
        let band = try database.rankedCanonicalForms(languagePrimary: VocabularyMatchKey.primaryLanguage(language),
                                                     offset: offset, limit: limit)
        guard let sample, sample > 0, sample < band.words.count else { return band }
        let step = Double(band.words.count) / Double(sample)
        return ((0..<sample).map { band.words[Int(Double($0) * step + step / 2)] }, band.total)
    }
}
