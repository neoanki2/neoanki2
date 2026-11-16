import Foundation
import NeoAnkiCore
import NeoAnkiDeckBuilderKit

public struct PoemDeckInput: Sendable, Equatable {
    public var destinationDeckID: UUID?
    public var author: String
    public var title: String
    public var text: String

    public init(
        destinationDeckID: UUID? = nil,
        author: String = "",
        title: String = "",
        text: String = ""
    ) {
        self.destinationDeckID = destinationDeckID
        self.author = author
        self.title = title
        self.text = text
    }
}

public struct ParsedPoemLine: Sendable, Equatable {
    public let text: String
    public let startsStanza: Bool

    public init(text: String, startsStanza: Bool) {
        self.text = text
        self.startsStanza = startsStanza
    }
}

public struct ParsedPoem: Sendable, Equatable {
    public let stanzas: [[String]]

    public init(stanzas: [[String]]) {
        self.stanzas = stanzas
    }

    public var lines: [ParsedPoemLine] {
        stanzas.enumerated().flatMap { stanzaIndex, stanza in
            stanza.enumerated().map { lineIndex, line in
                ParsedPoemLine(
                    text: line,
                    startsStanza: stanzaIndex > 0 && lineIndex == 0
                )
            }
        }
    }
}

public enum PoemDeckBuilderError: Error, Sendable, Equatable, LocalizedError {
    case missingAuthor
    case missingTitle
    case missingDestinationDeck
    case tooFewLines
    case invalidGeneratedDeck([AuthoredDeckDiagnostic])

    public var errorDescription: String? {
        switch self {
        case .missingAuthor:
            "Enter the poem’s author."
        case .missingTitle:
            "Enter the poem’s title."
        case .missingDestinationDeck:
            "Choose a root deck."
        case .tooFewLines:
            "Enter at least two nonblank lines."
        case let .invalidGeneratedDeck(diagnostics):
            diagnostics.first?.localizedDescription ?? "The generated deck is invalid."
        }
    }
}

public enum PoemDeckGenerator {
    public static func generate(
        input: PoemDeckInput,
        workspaceProvider: any DeckBuildWorkspaceProviding = SystemDeckBuildWorkspaceProvider(),
        limits: AuthoredDeckLimits = .default
    ) throws -> GeneratedDeckBundle {
        try prepare(input: input, limits: limits).materialize(using: workspaceProvider)
    }

    public static func prepare(
        input: PoemDeckInput,
        limits: AuthoredDeckLimits = .default
    ) throws -> GeneratedDeckCreation {
        let author = input.author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !author.isEmpty else { throw PoemDeckBuilderError.missingAuthor }

        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw PoemDeckBuilderError.missingTitle }
        guard let destinationDeckID = input.destinationDeckID else {
            throw PoemDeckBuilderError.missingDestinationDeck
        }

        let poem = parse(input.text)
        let lines = poem.lines
        guard lines.count >= 2 else { throw PoemDeckBuilderError.tooFewLines }

        let attribution = "\(title) · \(author)"
        let items = PoemCardPlanner.cards(for: poem, title: title).map { card in
            AuthoredDeckDraft.TextItem(fields: ["front": card.prompt, "back": card.answer, "attribution": attribution],
                tags: ["author:\(author)"] + (card.isOpening ? [PoemCardPlanner.openingTag] : []))
        }
        do {
            let prepared = try AuthoredDeck.prepare(.init(key: "poem", title: title,
                definition: poemTypeRecord, items: items), limits: limits)
            return GeneratedDeckCreation(prepared: prepared, parentDeckID: destinationDeckID)
        } catch let AuthoredDeckError.invalid(diagnostics) {
            throw PoemDeckBuilderError.invalidGeneratedDeck(diagnostics)
        }
    }

    public static func parse(_ text: String) -> ParsedPoem {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .map {
                $0.trimmingCharacters(in: .whitespaces)
                    .precomposedStringWithCanonicalMapping
            }

        var stanzas: [[String]] = []
        var current: [String] = []
        for line in normalized {
            if line.isEmpty {
                if !current.isEmpty {
                    stanzas.append(current)
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { stanzas.append(current) }
        return ParsedPoem(stanzas: stanzas)
    }

    public static func usableLines(in text: String) -> [String] {
        parse(text).lines.map(\.text)
    }

    private static let poemTypeRecord = AuthoredDeckDraft.Definition(
        id: "poem-line",
        name: "Poem Line",
        fields: [
            AuthoredDeckDraft.Field(id: "front", name: "Front", type: .text, required: true),
            AuthoredDeckDraft.Field(id: "back", name: "Back", type: .text, required: true),
            AuthoredDeckDraft.Field(id: "attribution", name: "Attribution", type: .text, required: true),
        ],
        templates: [
            AuthoredDeckDraft.CardTemplate(
                name: "Card",
                layout: .focus,
                components: [
                    AuthoredDeckDraft.Component(
                        region: .label,
                        purpose: .supporting,
                        field: "attribution",
                        reveal: .always
                    ),
                    AuthoredDeckDraft.Component(
                        region: .primary,
                        purpose: .question,
                        field: "front",
                        reveal: .always
                    ),
                    AuthoredDeckDraft.Component(
                        region: .secondary,
                        purpose: .expectedAnswer,
                        field: "back",
                        reveal: .hiddenUntilAnswer
                    ),
                ],
                interaction: .reveal,
                skill: Skill(input: .text, output: .text, operation: .recall)
            ),
        ]
    )
}
