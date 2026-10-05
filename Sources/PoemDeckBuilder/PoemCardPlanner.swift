import Foundation

public struct PlannedPoemCard: Sendable, Equatable {
    public let prompt: String
    public let answer: String
    public let isOpening: Bool
}

/// The same opening policy is used by the builder, editor, and repair tool.
public enum PoemCardPlanner {
    public static let openingTag = "neoanki:poem-opening"
    public static let openingPrompt = "Recall the first line."

    public static func needsOpeningCard(title: String, firstLine: String) -> Bool {
        let title = comparisonText(title)
        let line = comparisonText(firstLine)
        return title.isEmpty || line.isEmpty || title != line
    }

    public static func cards(for poem: ParsedPoem, title: String) -> [PlannedPoemCard] {
        let lines = poem.lines
        guard lines.count >= 2 else { return [] }
        var cards: [PlannedPoemCard] = []
        if needsOpeningCard(title: title, firstLine: lines[0].text) {
            cards.append(.init(prompt: openingPrompt, answer: lines[0].text, isOpening: true))
        }
        let prompts = PoemPromptPlanner.prompts(for: poem)
        cards += lines.dropFirst().enumerated().map { index, line in
            .init(
                prompt: prompts[index],
                answer: (line.startsStanza ? "\n" : "") + line.text,
                isOpening: false
            )
        }
        return cards
    }

    private static func comparisonText(_ text: String) -> String {
        let normalized = text.precomposedStringWithCanonicalMapping.lowercased()
        let unpunctuated = String(String.UnicodeScalarView(normalized.unicodeScalars.filter {
            !CharacterSet.punctuationCharacters.contains($0)
        }))
        return unpunctuated.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
