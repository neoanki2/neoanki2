import Foundation

/// The semantic result of a learner response. Presentation wording and color
/// deliberately live outside Core.
public enum AnswerEvaluation: Sendable, Equatable {
    case correct
    case incorrect
    case unavailable
}

public struct Arrangement: Sendable, Equatable {
    public let expected: [String]
    public let initial: [String]

    public init(expected: [String], initial: [String]) {
        self.expected = expected
        self.initial = initial
    }
}

/// Platform-neutral study rules shared by macOS, iPhone, and iPad.
public enum StudyResponseEvaluator {
    public static func acceptedAnswers(for card: DueCard) -> [String] {
        if card.template.responseOverride == .type {
            for component in card.studyComponents where component.purpose == .question {
                switch component.value {
                case let .cloze(text, blanks):
                    guard let group = card.card.clozeGroup else { continue }
                    let answers = ClozeValidation.sanitize(text: text, blanks: blanks)
                        .filter { $0.group == group }
                        .map { String(text.dropFirst($0.start).prefix($0.length)) }
                    if !answers.isEmpty { return [answers.joined(separator: " ")] }
                case let .imageOcclusion(content):
                    if let group = card.card.occlusionGroup {
                        let answer = content.revealedAnswerText(group: group, revealed: true)
                        if !answer.isEmpty { return [answer] }
                    }
                default: break
                }
            }
        }
        let values = card.studyComponents.filter { $0.purpose == .expectedAnswer }.map(\.value)
        let answers = values.flatMap(textRepresentations)
            .map(trimmed)
            .filter { !$0.isEmpty }
        let combined = trimmed(answers.joined(separator: " "))
        return unique(answers + (combined.isEmpty ? [] : [combined]))
    }

    public static func evaluate(_ response: String, for card: DueCard) -> AnswerEvaluation {
        if VocabularySet.supportsTypedResponse(card) { return VocabularySet.check(response, for: card) }
        let answers = acceptedAnswers(for: card)
        guard !answers.isEmpty else { return .unavailable }
        let normalizedResponse = normalized(response)
        guard !normalizedResponse.isEmpty else { return .incorrect }
        return answers.contains { normalized($0) == normalizedResponse } ? .correct : .incorrect
    }

    public static func hasReferenceAudio(for card: DueCard) -> Bool {
        SideContent.values(for: .expectedAnswer, in: card.template, from: card.studyItem).contains { value in
            guard case let .media(reference) = value else { return false }
            return reference.kind == .audio
        }
    }

    public static func choiceOptions(for card: DueCard, maximum: Int = 4) -> [String] {
        guard let correct = acceptedAnswers(for: card).first else { return [] }
        let available = card.studyItem.fields.flatMap { textRepresentations($0.value) }
            + SideContent.values(for: .question, in: card.template, from: card.studyItem)
                .flatMap(textRepresentations)
        var options = unique([correct] + available.map(trimmed).filter {
            !$0.isEmpty && normalized($0) != normalized(correct)
        })
        if options.count == 1 {
            options.append("No matching answer")
        }
        options = Array(options.prefix(max(2, maximum)))
        return deterministicallyReordered(
            options,
            seed: card.template.id.uuidString + card.item.id.uuidString
        )
    }

    public static func arrangement(for card: DueCard) -> Arrangement? {
        guard let answer = acceptedAnswers(for: card).first else { return nil }
        let lines = answer.split(whereSeparator: \.isNewline).map { trimmed(String($0)) }
        let words = answer.split(whereSeparator: \.isWhitespace).map(String.init)
        let units = lines.count > 1 ? lines : (words.count > 1 ? words : answer.map(String.init))
        guard units.count > 1 else { return nil }

        var shuffled = deterministicallyReordered(
            units,
            seed: card.template.id.uuidString + card.item.id.uuidString
        )
        if shuffled == units {
            shuffled = Array(units.dropFirst()) + [units[0]]
        }
        return Arrangement(expected: units, initial: shuffled)
    }

    public static func isCorrectArrangement(
        _ response: [String],
        for card: DueCard
    ) -> AnswerEvaluation {
        guard let arrangement = arrangement(for: card) else { return .unavailable }
        return response == arrangement.expected ? .correct : .incorrect
    }

    private static func textRepresentations(_ value: ContentValue) -> [String] {
        switch value {
        case let .text(text, _): [text]
        case let .rich(spans): [spans.map(\.text).joined()]
        case .imageOcclusion: []
        case let .cloze(text, _): [text]
        case let .studyExercise(exercise): [exercise.stimulus]
        case let .number(number): [number.formatted(.number.grouping(.never))]
        case let .media(reference): reference.altText.map { [$0] } ?? []
        case let .checkbox(value): [value ? "Yes" : "No"]
        case .empty, .rows: []
        }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unique(_ values: [String]) -> [String] {
        values.reduce(into: []) { result, value in
            guard !result.contains(where: { normalized($0) == normalized(value) }) else { return }
            result.append(value)
        }
    }

    private static func deterministicallyReordered(_ values: [String], seed: String) -> [String] {
        guard values.count > 1 else { return values }
        let offset = seed.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) % values.count }
        let rotated = Array(values[offset...]) + Array(values[..<offset])
        return offset.isMultiple(of: 2) ? rotated : rotated.reversed()
    }
}
