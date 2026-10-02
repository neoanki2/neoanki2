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
        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ProseDeckBuilderError.missingTitle }
        guard let destinationDeckID = input.destinationDeckID else {
            throw ProseDeckBuilderError.missingDestinationDeck
        }
        let units = reviewedUnits ?? ProseText.parse(input.text)
        guard !units.isEmpty else { throw ProseDeckBuilderError.emptyText }
        guard valid(units) else { throw ProseDeckBuilderError.invalidUnits }

        let workspace = try workspaceProvider.makeWorkspace()
        do {
            try writeBundle(
                at: workspace.bundleURL,
                author: input.author.trimmingCharacters(in: .whitespacesAndNewlines),
                title: title,
                units: units
            )
            let diagnostics = AuthoredDeck.validate(at: workspace.bundleURL, limits: limits)
            guard diagnostics.isEmpty else {
                throw ProseDeckBuilderError.invalidGeneratedDeck(diagnostics)
            }
            return workspace.placed(under: destinationDeckID)
        } catch {
            workspace.cleanup()
            throw error
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

    private static func writeBundle(
        at bundleURL: URL,
        author: String,
        title: String,
        units: [ProseUnit]
    ) throws {
        let itemsDirectory = bundleURL.appendingPathComponent("items", isDirectory: true)
        try FileManager.default.createDirectory(
            at: itemsDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        var manifestData = Data()
        try append(
            ProseManifestRecord(kind: "neoanki", version: 5, root: "prose", parts: ["items/prose.jsonl"]),
            to: &manifestData
        )
        try append(proseTypeRecord, to: &manifestData)
        try append(
            ProseDeckRecord(
                kind: "deck",
                id: "prose",
                name: title,
                parent: nil,
                itemTypes: ["prose-unit"],
                defaultType: "prose-unit"
            ),
            to: &manifestData
        )
        try manifestData.write(
            to: bundleURL.appendingPathComponent(AuthoredDeck.manifestName),
            options: .atomic
        )

        let attribution = author.isEmpty ? title : "\(title) · \(author)"
        let prompts = ProsePromptPlanner.prompts(for: units)
        var itemData = Data()
        for (index, unit) in units.enumerated() {
            let fields = [
                "front": ProseTextValue(text: prompts[index]),
                "back": ProseTextValue(text: unit.text),
                "attribution": ProseTextValue(text: attribution),
                "order": ProseTextValue(text: String(index)),
                "separator": ProseTextValue(text: unit.separator),
            ]
            try append(
                ProseItemRecord(
                    kind: "item",
                    deck: "prose",
                    type: "prose-unit",
                    fields: fields,
                    tags: author.isEmpty ? [] : ["author:\(author)"]
                ),
                to: &itemData
            )
        }
        try itemData.write(
            to: itemsDirectory.appendingPathComponent("prose.jsonl"),
            options: .atomic
        )
    }

    private static func append<Value: Encodable>(_ value: Value, to data: inout Data) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        data.append(try encoder.encode(value))
        data.append(0x0A)
    }

    private static let proseTypeRecord = ProseTypeRecord(
        kind: "type",
        id: "prose-unit",
        name: "Prose Unit",
        fields: [
            .init(id: "front", name: "Front", type: "text", required: true),
            .init(id: "back", name: "Back", type: "text", required: true),
            .init(id: "attribution", name: "Attribution", type: "text", required: true),
            .init(id: "order", name: "Order", type: "text", required: true),
            .init(id: "separator", name: "Separator", type: "text", required: false),
        ],
        templates: [
            .init(
                name: "Card",
                layout: "focus",
                components: [
                    .init(region: "label", purpose: "supporting", field: "attribution", reveal: "always"),
                    .init(region: "primary", purpose: "question", field: "front", reveal: "always"),
                    .init(
                        region: "secondary",
                        purpose: "expectedAnswer",
                        field: "back",
                        reveal: "hiddenUntilAnswer"
                    ),
                ],
                prompt: [.init(field: "attribution"), .init(field: "front")],
                answer: [.init(field: "back", reveal: "hiddenUntilAnswer")],
                interaction: "reveal",
                skill: .init(input: "text", output: "text", operation: "recall")
            ),
        ]
    )
}

private struct ProseManifestRecord: Encodable {
    let kind: String
    let version: Int
    let root: String
    let parts: [String]
}

private struct ProseDeckRecord: Encodable {
    let kind: String
    let id: String
    let name: String
    let parent: String?
    let itemTypes: [String]
    let defaultType: String
}

private struct ProseTypeRecord: Encodable {
    let kind: String
    let id: String
    let name: String
    let fields: [ProseFieldRecord]
    let templates: [ProseTemplateRecord]
}

private struct ProseFieldRecord: Encodable {
    let id: String
    let name: String
    let type: String
    let required: Bool
}

private struct ProseTemplateRecord: Encodable {
    let name: String
    let layout: String
    let components: [ProseComponentRecord]
    let prompt: [ProseSlotRecord]
    let answer: [ProseSlotRecord]
    let interaction: String
    let skill: ProseSkillRecord
}

private struct ProseSlotRecord: Encodable {
    let field: String
    let reveal: String?

    init(field: String, reveal: String? = nil) {
        self.field = field
        self.reveal = reveal
    }
}

private struct ProseComponentRecord: Encodable {
    let region: String
    let purpose: String
    let field: String
    let reveal: String
}

private struct ProseSkillRecord: Encodable {
    let input: String
    let output: String
    let operation: String
}

private struct ProseTextValue: Encodable {
    let text: String
}

private struct ProseItemRecord: Encodable {
    let kind: String
    let deck: String
    let type: String
    let fields: [String: ProseTextValue]
    let tags: [String]
}
