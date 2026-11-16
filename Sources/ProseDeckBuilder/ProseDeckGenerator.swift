import Foundation
import NeoAnkiCore
import NeoAnkiDeckBuilderKit

public struct ProseDeckInput: Sendable, Equatable {
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

public enum ProseDeckBuilderError: Error, Sendable, Equatable, LocalizedError {
    case missingTitle
    case missingDestinationDeck
    case emptyText
    case invalidUnits
    case invalidGeneratedDeck([AuthoredDeckDiagnostic])

    public var errorDescription: String? {
        switch self {
        case .missingTitle: return "Enter a title for the passage."
        case .missingDestinationDeck: return "Choose a root deck."
        case .emptyText: return "Paste some prose to learn."
        case .invalidUnits: return "Review the passage units. Each unit needs text and a valid boundary."
        case let .invalidGeneratedDeck(diagnostics):
            let message = diagnostics.first?.localizedDescription ?? "The generated deck is invalid."
            return "\(message) If this passage is too large, divide it into separate decks."
        }
    }
}

public enum ProseDeckGenerator {
    public static func generate(
        input: ProseDeckInput,
        reviewedUnits: [ProseUnit]? = nil,
        workspaceProvider: any DeckBuildWorkspaceProviding = SystemDeckBuildWorkspaceProvider(),
        limits: AuthoredDeckLimits = .default
    ) throws -> GeneratedDeckBundle {
        try prepare(input: input, reviewedUnits: reviewedUnits, limits: limits).materialize(using: workspaceProvider)
    }

    public static func prepare(
        input: ProseDeckInput,
        reviewedUnits: [ProseUnit]? = nil,
        limits: AuthoredDeckLimits = .default
    ) throws -> GeneratedDeckCreation {
        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ProseDeckBuilderError.missingTitle }
        guard let destinationDeckID = input.destinationDeckID else {
            throw ProseDeckBuilderError.missingDestinationDeck
        }
        let units = reviewedUnits ?? ProseText.parse(input.text)
        guard !units.isEmpty else { throw ProseDeckBuilderError.emptyText }
        guard valid(units) else { throw ProseDeckBuilderError.invalidUnits }

        let author = input.author.trimmingCharacters(in: .whitespacesAndNewlines)
        let attribution = author.isEmpty ? title : "\(title) · \(author)"
        let prompts = ProsePromptPlanner.prompts(for: units)
        let items = units.enumerated().map { index, unit in
            AuthoredDeckDraft.TextItem(fields: ["front": prompts[index], "back": unit.text,
                "attribution": attribution, "order": String(index), "separator": unit.separator],
                tags: author.isEmpty ? [] : ["author:\(author)"])
        }
        do {
            let prepared = try AuthoredDeck.prepare(.init(key: "prose", title: title,
                definition: proseTypeRecord, items: items), limits: limits)
            return GeneratedDeckCreation(prepared: prepared, parentDeckID: destinationDeckID)
        } catch let AuthoredDeckError.invalid(diagnostics) {
            throw ProseDeckBuilderError.invalidGeneratedDeck(diagnostics)
        }
    }

    public static func valid(_ units: [ProseUnit]) -> Bool {
        !units.isEmpty && units.enumerated().allSatisfy { index, unit in
            !unit.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !unit.text.contains("\n")
                && (index > 0 || unit.separator.isEmpty)
                && (index == 0 || unit.separator.isEmpty
                    || unit.separator == " " || unit.separator == "\n\n")
        }
    }

    private static let proseTypeRecord = AuthoredDeckDraft.Definition(
        id: "prose-unit",
        name: "Prose Unit",
        fields: [
            .init(id: "front", name: "Front", type: .text, required: true),
            .init(id: "back", name: "Back", type: .text, required: true),
            .init(id: "attribution", name: "Attribution", type: .text, required: true),
            .init(id: "order", name: "Order", type: .text, required: true),
            .init(id: "separator", name: "Separator", type: .text, required: false),
        ],
        templates: [
            .init(
                name: "Card",
                layout: .focus,
                components: [
                    .init(region: .label, purpose: .supporting, field: "attribution", reveal: .always),
                    .init(region: .primary, purpose: .question, field: "front", reveal: .always),
                    .init(
                        region: .secondary,
                        purpose: .expectedAnswer,
                        field: "back",
                        reveal: .hiddenUntilAnswer
                    ),
                ],
                interaction: .reveal,
                skill: .init(input: .text, output: .text, operation: .recall)
            ),
        ]
    )
}
