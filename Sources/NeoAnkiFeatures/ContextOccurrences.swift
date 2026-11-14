import Foundation
import NaturalLanguage
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiVocabularyKit

public enum ContextOccurrences {
    public static func validated(_ spans: [ContextSpan], in text: String) -> Bool {
        guard !spans.isEmpty else { return false }
        var end = 0
        for span in spans.sorted(by: { $0.start < $1.start }) {
            guard span.start >= end, span.length > 0, span.start <= text.count,
                  span.length <= text.count - span.start else { return false }
            end = span.start + span.length
        }
        return true
    }

    public static func fromPack(_ target: ExampleTarget?, text: String) -> [ContextSpan] {
        guard let target else { return [] }
        if let range = target.scalarRange {
            guard range.location >= 0, range.length > 0, range.location <= text.unicodeScalars.count,
                  range.length <= text.unicodeScalars.count - range.location else { return [] }
            let start = text.unicodeScalars.index(text.unicodeScalars.startIndex, offsetBy: range.location)
            let end = text.unicodeScalars.index(start, offsetBy: range.length)
            guard String(text[start..<end]) == target.exactText,
                  text.indices.contains(start), end == text.endIndex || text.indices.contains(end) else { return [] }
            return [.init(start: text.distance(from: text.startIndex, to: start), length: text.distance(from: start, to: end))]
        }
        return exact(target.exactText, in: text, language: nil)
    }

    /// Exact forms are authoritative. Inferred forms stay sentence-local and bounded;
    /// the caller still decides whether its source establishes the intended meaning.
    public static func find(target: ContextTarget, in text: String) -> (spans: [ContextSpan], uncertain: Bool) {
        let exactMatches = ([target.expression] + target.forms).flatMap { exact($0, in: text, language: target.language) }
        let tokens = lexicalTokens(in: text, language: target.language)
        let expression = target.expression.trimmingCharacters(in: .whitespacesAndNewlines)
        let slotPattern = try? NSRegularExpression(pattern: "\\[[^\\]]+\\]|\\{[^}]+\\}")
        let slots = slotPattern?.matches(in: expression, range: NSRange(expression.startIndex..., in: expression))
            .compactMap { Range($0.range, in: expression) } ?? []
        let pattern = lexicalTokens(in: expression, language: target.language).filter { token in
            !slots.contains { $0.overlaps(token.range) }
        }
        guard !pattern.isEmpty else { return (merged(exactMatches), exactMatches.isEmpty) }
        var inferred: [ContextSpan] = []
        var start = 0
        while start < tokens.count {
            guard equivalent(tokens[start], pattern[0]) else { start += 1; continue }
            var indices = [start]
            var cursor = start + 1
            for component in pattern.indices.dropFirst() {
                let previous = pattern[component - 1]
                let permitsObject = component == 1 && pattern[0].isVerb
                let hasSlot = slots.contains { $0.lowerBound >= previous.range.upperBound && $0.upperBound <= pattern[component].range.lowerBound }
                let maySeparate = permitsObject || hasSlot
                let previousIndex = indices.last!
                while cursor < tokens.count {
                    let passage = text[tokens[start].range.lowerBound..<tokens[cursor].range.upperBound]
                    // A phrase cannot continue across a sentence boundary. The gap limit is
                    // checked before matching as well as while skipping intervening words.
                    guard !passage.contains(where: { ".!?。！？\n\r".contains($0) }),
                          passage.count <= 100, cursor - previousIndex <= 7 else { break }
                    if equivalent(tokens[cursor], pattern[component]) { indices.append(cursor); cursor += 1; break }
                    if !maySeparate { break }
                    cursor += 1
                }
                if indices.count != component + 1 { break }
            }
            if indices.count == pattern.count {
                inferred += indices.map { index in
                    let range = tokens[index].range
                    return ContextSpan(start: text.distance(from: text.startIndex, to: range.lowerBound),
                                       length: text.distance(from: range.lowerBound, to: range.upperBound))
                }
                start = (indices.last ?? start) + 1
            } else { start += 1 }
        }
        return (merged(exactMatches + inferred), exactMatches.isEmpty)
    }

    private struct LexicalToken {
        let surface: String
        let lemma: String
        let range: Range<String.Index>
        let isVerb: Bool
    }

    private static func lexicalTokens(in text: String, language: String) -> [LexicalToken] {
        guard !text.isEmpty else { return [] }
        let base = Locale(identifier: language).language.languageCode?.identifier ?? language
        let tokenizer = NLTokenizer(unit: .word); tokenizer.string = text
        tokenizer.setLanguage(NLLanguage(rawValue: base))
        let tagger = NLTagger(tagSchemes: [.lemma, .lexicalClass]); tagger.string = text
        tagger.setLanguage(NLLanguage(rawValue: base), range: text.startIndex..<text.endIndex)
        var result: [LexicalToken] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let surface = String(text[range]).lowercased()
            let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue.lowercased() ?? surface
            let kind = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lexicalClass).0
            result.append(.init(surface: surface, lemma: lemma, range: range, isVerb: kind == .verb))
            return true
        }
        return result
    }

    private static func equivalent(_ value: LexicalToken, _ pattern: LexicalToken) -> Bool {
        value.surface == pattern.surface || value.lemma == pattern.lemma
    }

    public static func exact(_ expression: String, in text: String, language: String?) -> [ContextSpan] {
        let expression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty else { return [] }
        var search = text.startIndex..<text.endIndex
        var matches: [ContextSpan] = []
        // Japanese and Chinese token boundaries do not follow Latin word-boundary rules.
        let base = language.map { Locale(identifier: $0).language.languageCode?.identifier ?? $0 }
        let unspaced = ["ja", "zh"].contains(base ?? "")
        var boundaries: Set<String.Index> = []
        if unspaced {
            let tokenizer = NLTokenizer(unit: .word); tokenizer.string = text
            if let base { tokenizer.setLanguage(NLLanguage(rawValue: base)) }
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                boundaries.insert(range.lowerBound); boundaries.insert(range.upperBound); return true
            }
        }
        while let range = text.range(of: expression, options: [.caseInsensitive], range: search) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            let characterAligned = text.indices.contains(range.lowerBound) && (range.upperBound == text.endIndex || text.indices.contains(range.upperBound))
            if characterAligned && ((unspaced && boundaries.contains(range.lowerBound) && boundaries.contains(range.upperBound))
                || (!unspaced && before?.isLetter != true && before?.isNumber != true && after?.isLetter != true && after?.isNumber != true)) {
                matches.append(.init(start: text.distance(from: text.startIndex, to: range.lowerBound),
                                     length: text.distance(from: range.lowerBound, to: range.upperBound)))
            }
            guard range.upperBound < text.endIndex else { break }
            search = range.upperBound..<text.endIndex
        }
        return matches
    }

    public static func clozeSpans(for example: ContextExample, target: ContextTarget) -> [ContextSpan] {
        merged(example.spans + find(target: target, in: example.sentence).spans)
    }
    private static func merged(_ spans: [ContextSpan]) -> [ContextSpan] {
        var result: [ContextSpan] = []
        for span in spans.sorted(by: { $0.start == $1.start ? $0.length > $1.length : $0.start < $1.start }) {
            if let last = result.last, last.start + last.length > span.start {
                result[result.count - 1].length = max(last.start + last.length, span.start + span.length) - last.start
            } else { result.append(span) }
        }
        return result
    }

    public static func richText(_ text: String, spans: [ContextSpan]) -> [Span] {
        guard validated(spans, in: text) else { return [Span(text)] }
        let characters = Array(text)
        var result: [Span] = [], cursor = 0
        for span in spans.sorted(by: { $0.start < $1.start }) {
            if cursor < span.start { result.append(Span(String(characters[cursor..<span.start]))) }
            result.append(Span(String(characters[span.start..<(span.start + span.length)]), styles: [.bold]))
            cursor = span.start + span.length
        }
        if cursor < characters.count { result.append(Span(String(characters[cursor...]))) }
        return result
    }

    public static func key(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
