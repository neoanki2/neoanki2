import Foundation
import NaturalLanguage

public struct ProseUnit: Sendable, Equatable {
    public var text: String
    /// Empty for the first unit, a space within a paragraph, or two line breaks.
    public var separator: String

    public init(text: String, separator: String) {
        self.text = text
        self.separator = separator
    }
}

public enum ProseText {
    public static func parse(_ source: String) -> [ProseUnit] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        let paragraphPattern = try! NSRegularExpression(pattern: #"\n[ \t]*\n+"#)
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        let matches = paragraphPattern.matches(in: normalized, range: range)
        var paragraphs: [String] = []
        var start = normalized.startIndex
        for match in matches {
            guard let boundary = Range(match.range, in: normalized) else { continue }
            paragraphs.append(String(normalized[start..<boundary.lowerBound]))
            start = boundary.upperBound
        }
        paragraphs.append(String(normalized[start...]))

        var units: [ProseUnit] = []
        for rawParagraph in paragraphs {
            let paragraph = rawParagraph
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
                .precomposedStringWithCanonicalMapping
            guard !paragraph.isEmpty else { continue }
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = paragraph
            var sentences: [(text: String, separator: String)] = []
            var previousEnd = paragraph.startIndex
            tokenizer.enumerateTokens(in: paragraph.startIndex..<paragraph.endIndex) { range, _ in
                var lower = range.lowerBound
                var upper = range.upperBound
                while lower < upper, paragraph[lower].isWhitespace {
                    lower = paragraph.index(after: lower)
                }
                while lower < upper {
                    let prior = paragraph.index(before: upper)
                    guard paragraph[prior].isWhitespace else { break }
                    upper = prior
                }
                if lower < upper {
                    sentences.append((
                        text: String(paragraph[lower..<upper]),
                        separator: String(paragraph[previousEnd..<lower])
                    ))
                    previousEnd = upper
                }
                return true
            }
            let reconstructed = sentences.map { $0.separator + $0.text }.joined()
            if sentences.isEmpty || reconstructed != paragraph {
                sentences = [(paragraph, "")]
            }
            for (sentenceIndex, sentence) in sentences.enumerated() {
                for (partIndex, part) in splitLongSentence(sentence.text).enumerated() {
                    let separator: String
                    if units.isEmpty {
                        separator = ""
                    } else if sentenceIndex == 0 && partIndex == 0 {
                        separator = "\n\n"
                    } else if partIndex == 0 {
                        separator = sentence.separator
                    } else {
                        separator = sentence.text.contains(" ") ? " " : ""
                    }
                    units.append(ProseUnit(text: part, separator: separator))
                }
            }
        }
        return units
    }

    public static func source(from units: [ProseUnit]) -> String {
        units.map { $0.separator + $0.text }.joined()
    }

    /// Keep reviewed boundaries in paragraphs whose words did not change.
    public static func parse(_ source: String, preserving existing: [ProseUnit]) -> [ProseUnit] {
        let fresh = parse(source)
        guard !existing.isEmpty else { return fresh }
        let oldParagraphs = paragraphs(in: existing)
        let newParagraphs = paragraphs(in: fresh)
        let oldTexts = oldParagraphs.map {
            Self.source(from: $0).trimmingCharacters(in: .newlines)
        }
        let newTexts = newParagraphs.map {
            Self.source(from: $0).trimmingCharacters(in: .newlines)
        }
        let difference = newTexts.difference(from: oldTexts)
        let removed = Set(difference.removals.compactMap { change -> Int? in
            if case let .remove(offset, _, _) = change { return offset }
            return nil
        })
        let inserted = Set(difference.insertions.compactMap { change -> Int? in
            if case let .insert(offset, _, _) = change { return offset }
            return nil
        })
        var matching: [Int: Int] = [:]
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldTexts.count && newIndex < newTexts.count {
            if removed.contains(oldIndex) { oldIndex += 1; continue }
            if inserted.contains(newIndex) { newIndex += 1; continue }
            matching[newIndex] = oldIndex
            oldIndex += 1
            newIndex += 1
        }
        return newParagraphs.enumerated().flatMap { index, paragraph -> [ProseUnit] in
            var selected = matching[index].map { oldParagraphs[$0] } ?? paragraph
            if !selected.isEmpty { selected[0].separator = index == 0 ? "" : "\n\n" }
            return selected
        }
    }

    public static func paragraphCount(in units: [ProseUnit]) -> Int {
        guard !units.isEmpty else { return 0 }
        return 1 + units.dropFirst().filter { $0.separator == "\n\n" }.count
    }

    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    public static func splitPositionCount(_ text: String) -> Int {
        let words = wordCount(text)
        return words > 1 ? words : text.count
    }

    public static func split(_ unit: ProseUnit, afterWord count: Int) -> (ProseUnit, ProseUnit)? {
        let words = unit.text.split(separator: " ").map(String.init)
        if words.count > 1 {
            guard count > 0, count < words.count else { return nil }
            return (
                ProseUnit(text: words[..<count].joined(separator: " "), separator: unit.separator),
                ProseUnit(text: words[count...].joined(separator: " "), separator: " ")
            )
        }
        let characters = Array(unit.text)
        guard count > 0, count < characters.count else { return nil }
        return (
            ProseUnit(text: String(characters[..<count]), separator: unit.separator),
            ProseUnit(text: String(characters[count...]), separator: "")
        )
    }

    private static func paragraphs(in units: [ProseUnit]) -> [[ProseUnit]] {
        var result: [[ProseUnit]] = []
        for unit in units {
            if unit.separator == "\n\n" || result.isEmpty { result.append([]) }
            result[result.count - 1].append(unit)
        }
        return result
    }

    private static func splitLongSentence(_ sentence: String) -> [String] {
        let words = sentence.split(separator: " ").map(String.init)
        // A reading-stage heuristic, not a research-derived optimal chunk size.
        if words.count <= 1, sentence.count > 160 {
            let characters = Array(sentence)
            var parts: [String] = []
            var start = 0
            while characters.count - start > 160 {
                let punctuation = ((start + 70)..<min(start + 161, characters.count))
                    .reversed()
                    .first { "，；：、,;:—–".contains(characters[$0]) }
                let end = punctuation.map { $0 + 1 } ?? start + 120
                parts.append(String(characters[start..<end]))
                start = end
            }
            if start < characters.count { parts.append(String(characters[start...])) }
            return parts
        }
        // Forty-five words keeps an answer readable in the fixed study stage.
        // The preview lets the author choose a more natural boundary.
        guard words.count > 45 else { return [sentence] }
        var parts: [String] = []
        var start = 0
        while words.count - start > 45 {
            let preferred = (start + 20)..<min(start + 46, words.count)
            let punctuation = preferred.reversed().first {
                words[$0].last.map { ",;:—–".contains($0) } == true
            }
            let end = punctuation.map { $0 + 1 } ?? start + 35
            parts.append(words[start..<end].joined(separator: " "))
            start = end
        }
        if start < words.count { parts.append(words[start...].joined(separator: " ")) }
        return parts
    }
}

public enum ProsePromptPlanner {
    public static func prompts(for units: [ProseUnit]) -> [String] {
        guard !units.isEmpty else { return [] }
        var lengths = units.indices.map { min(1, $0) }
        while true {
            let prompts = units.indices.map { index in
                context(units, before: index, length: lengths[index])
            }
            let groups = Dictionary(grouping: prompts.indices, by: { prompts[$0] })
            var extended = false
            for indices in groups.values where indices.count > 1 {
                for index in indices where lengths[index] < min(3, index) {
                    lengths[index] += 1
                    extended = true
                }
            }
            if !extended {
                let duplicates = Dictionary(grouping: prompts.indices, by: { prompts[$0] })
                return prompts.enumerated().map { index, prompt in
                    guard (duplicates[prompt]?.count ?? 0) > 1 else { return prompt }
                    let paragraph = 1 + units[...index].dropFirst()
                        .filter { $0.separator == "\n\n" }.count
                    return "\(prompt)\nParagraph \(paragraph), unit \(index + 1)"
                }
            }
        }
    }

    private static func context(_ units: [ProseUnit], before index: Int, length: Int) -> String {
        guard index > 0 else { return "Begin the passage." }
        let start = index - length
        var result = excerpt(units[start].text)
        if start + 1 < index {
            for prior in (start + 1)..<index {
                result += units[prior].separator + excerpt(units[prior].text)
            }
        }
        if units[index].separator == "\n\n" { result += "\n\n" }
        return result
    }

    private static func excerpt(_ text: String) -> String {
        let words = text.split(separator: " ")
        if words.count > 24 {
            return "…" + words.suffix(24).joined(separator: " ")
        }
        if words.count <= 1, text.count > 90 {
            return "…" + String(text.suffix(90))
        }
        return text
    }
}
