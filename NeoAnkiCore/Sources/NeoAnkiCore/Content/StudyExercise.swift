import Foundation

/// An authored response and its stimulus, independent of a deck's subject.
public struct StudyExercise: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Equatable, Sendable {
        case target, rewrite, choose

        public var title: String {
            switch self {
            case .target: "Type the target"
            case .rewrite: "Type a rewrite"
            case .choose: "Choose"
            }
        }
    }

    public struct Target: Codable, Equatable, Sendable {
        public var original: String?
        public var choices: [String]
        public var allowsOmission: Bool

        public init(original: String? = nil, choices: [String] = [], allowsOmission: Bool = false) {
            self.original = original
            self.choices = choices
            self.allowsOmission = allowsOmission
        }
    }

    public struct Choice: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var label: String

        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }
    }

    public var mode: Mode
    public var prompt: String
    public var parts: [String]
    public var targets: [Target]
    public var options: [Choice]
    /// Each row is one accepted complete response. An empty element means an explicit omission.
    public var answers: [[String]]
    public var correctOptionID: String?

    public init(
        mode: Mode, prompt: String = "", parts: [String] = [], targets: [Target] = [],
        options: [Choice] = [], answers: [[String]] = [], correctOptionID: String? = nil
    ) {
        self.mode = mode
        self.prompt = prompt
        self.parts = parts
        self.targets = targets
        self.options = options
        self.answers = answers
        self.correctOptionID = correctOptionID
    }

    public var stimulus: String {
        guard mode == .target, parts.count == targets.count + 1 else { return prompt }
        return targets.indices.reduce(into: parts[0]) { text, index in
            let target = targets[index]
            if let original = target.original {
                text += "‹\(original)›"
            } else if targets.count == 1 {
                text += "[…]"
            } else {
                text += "[\(index + 1)]"
            }
            text += parts[index + 1]
        }
    }

    public func validate() throws {
        func nonempty(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let valid: Bool
        switch mode {
        case .target:
            valid = (1...16).contains(targets.count) && parts.count == targets.count + 1
                && nonempty(stimulus) && options.isEmpty && correctOptionID == nil
                && !answers.isEmpty && answers.allSatisfy { row in
                    row.count == targets.count && zip(row, targets).allSatisfy { answer, target in
                        nonempty(answer) || (answer.isEmpty && target.allowsOmission)
                    }
                }
                && targets.allSatisfy { target in target.choices.allSatisfy(nonempty) }
        case .rewrite:
            valid = nonempty(prompt) && parts.isEmpty && targets.isEmpty
                && options.isEmpty && correctOptionID == nil && !answers.isEmpty
                && answers.allSatisfy { $0.count == 1 && nonempty($0[0]) }
        case .choose:
            valid = parts.isEmpty && targets.isEmpty && answers.isEmpty
                && (2...8).contains(options.count)
                && Set(options.map(\.id)).count == options.count
                && options.allSatisfy { nonempty($0.id) && nonempty($0.label) }
                && options.contains { $0.id == correctOptionID }
        }
        guard valid else { throw DatabaseError.invalidItem("Invalid study exercise or answer.") }
    }

    public func accepts(_ response: [String]) -> Bool {
        acceptedAnswer(matching: response) != nil
    }

    public func acceptedAnswer(matching response: [String]) -> [String]? {
        answers.first { row in
            row.count == response.count && zip(row, response).allSatisfy {
                Self.normalized($0) == Self.normalized($1)
            }
        }
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// The text editor and portable formats use a readable JSON form for the structured field.
    public var editorText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    public init(editorText: String) throws {
        self = try JSONDecoder().decode(Self.self, from: Data(editorText.utf8))
        try validate()
    }
}

public extension DueCard {
    var studyExercise: StudyExercise? {
        for value in SideContent.values(for: .question, in: template, from: item) {
            if case let .studyExercise(exercise) = value { return exercise }
        }
        return nil
    }
}
