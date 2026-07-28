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
        let author = input.author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !author.isEmpty else { throw PoemDeckBuilderError.missingAuthor }

        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw PoemDeckBuilderError.missingTitle }
        guard let destinationDeckID = input.destinationDeckID else {
            throw PoemDeckBuilderError.missingDestinationDeck
        }

        let lines = usableLines(in: input.text)
        guard lines.count >= 2 else { throw PoemDeckBuilderError.tooFewLines }

        let workspace = try workspaceProvider.makeWorkspace()
        do {
            try writeBundle(
                at: workspace.bundleURL,
                author: author,
                title: title,
                lines: lines
            )
            let diagnostics = AuthoredDeck.validate(at: workspace.bundleURL, limits: limits)
            guard diagnostics.isEmpty else {
                throw PoemDeckBuilderError.invalidGeneratedDeck(diagnostics)
            }
            return workspace.placed(under: destinationDeckID)
        } catch {
            workspace.cleanup()
            throw error
        }
    }

    public static func usableLines(in text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private static func writeBundle(
        at bundleURL: URL,
        author: String,
        title: String,
        lines: [String]
    ) throws {
        let itemsDirectory = bundleURL.appendingPathComponent("items", isDirectory: true)
        try FileManager.default.createDirectory(
            at: itemsDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        var manifestData = Data()
        try append(
            ManifestRecord(kind: "neoanki", version: 1, root: "poem", parts: ["items/poem.jsonl"]),
            to: &manifestData
        )
        try append(basicTypeRecord, to: &manifestData)
        try append(DeckRecord(kind: "deck", id: "poem", name: title, parent: nil), to: &manifestData)
        try manifestData.write(
            to: bundleURL.appendingPathComponent(AuthoredDeck.manifestName),
            options: .atomic
        )

        var itemData = Data()
        for answerIndex in 1 ..< lines.count {
            let promptStart = max(0, answerIndex - 2)
            let prompt = lines[promptStart ..< answerIndex].joined(separator: "\n")
            let item = ItemRecord(
                kind: "item",
                deck: "poem",
                type: "basic",
                fields: [
                    "front": TextValue(text: prompt),
                    "back": TextValue(text: lines[answerIndex]),
                ],
                tags: ["author:\(author)"]
            )
            try append(item, to: &itemData)
        }
        try itemData.write(
            to: itemsDirectory.appendingPathComponent("poem.jsonl"),
            options: .atomic
        )
    }

    private static func append<Value: Encodable>(_ value: Value, to data: inout Data) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        data.append(try encoder.encode(value))
        data.append(0x0A)
    }

    private static let basicTypeRecord = TypeRecord(
        kind: "type",
        id: "basic",
        name: "Basic",
        fields: [
            FieldRecord(id: "front", name: "Front", type: "text", required: true),
            FieldRecord(id: "back", name: "Back", type: "text", required: true),
        ],
        templates: [
            TemplateRecord(
                name: "Card",
                prompt: [SlotRecord(field: "front")],
                answer: [SlotRecord(field: "back")],
                interaction: "reveal",
                skill: SkillRecord(input: "text", output: "text", operation: "recognize")
            ),
        ]
    )
}

private struct ManifestRecord: Encodable {
    let kind: String
    let version: Int
    let root: String
    let parts: [String]
}

private struct DeckRecord: Encodable {
    let kind: String
    let id: String
    let name: String
    let parent: String?
}

private struct TypeRecord: Encodable {
    let kind: String
    let id: String
    let name: String
    let fields: [FieldRecord]
    let templates: [TemplateRecord]
}

private struct FieldRecord: Encodable {
    let id: String
    let name: String
    let type: String
    let required: Bool
}

private struct TemplateRecord: Encodable {
    let name: String
    let prompt: [SlotRecord]
    let answer: [SlotRecord]
    let interaction: String
    let skill: SkillRecord
}

private struct SlotRecord: Encodable {
    let field: String
}

private struct SkillRecord: Encodable {
    let input: String
    let output: String
    let operation: String
}

private struct ItemRecord: Encodable {
    let kind: String
    let deck: String
    let type: String
    let fields: [String: TextValue]
    let tags: [String]
}

private struct TextValue: Encodable {
    let text: String
}
