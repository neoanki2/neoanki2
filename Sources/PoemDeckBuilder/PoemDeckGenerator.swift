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

        let workspace = try workspaceProvider.makeWorkspace()
        do {
            try writeBundle(
                at: workspace.bundleURL,
                author: author,
                title: title,
                poem: poem
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

    private static func writeBundle(
        at bundleURL: URL,
        author: String,
        title: String,
        poem: ParsedPoem
    ) throws {
        let itemsDirectory = bundleURL.appendingPathComponent("items", isDirectory: true)
        try FileManager.default.createDirectory(
            at: itemsDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        var manifestData = Data()
        try append(
            ManifestRecord(kind: "neoanki", version: 5, root: "poem", parts: ["items/poem.jsonl"]),
            to: &manifestData
        )
        try append(poemTypeRecord, to: &manifestData)
        try append(
            DeckRecord(
                kind: "deck",
                id: "poem",
                name: title,
                parent: nil,
                itemTypes: ["poem-line"],
                defaultType: "poem-line"
            ),
            to: &manifestData
        )
        try manifestData.write(
            to: bundleURL.appendingPathComponent(AuthoredDeck.manifestName),
            options: .atomic
        )

        var itemData = Data()
        let attribution = "\(title) · \(author)"
        let lines = poem.lines
        for answerIndex in 1 ..< lines.count {
            let promptStart = max(0, answerIndex - 2)
            let prompt = lines[promptStart ..< answerIndex]
                .map(\.text)
                .joined(separator: "\n")
            var fields = [
                "front": TextValue(text: prompt),
                "back": TextValue(text: lines[answerIndex].text),
                "attribution": TextValue(text: attribution),
            ]
            if lines[answerIndex].startsStanza {
                fields["stanza-break"] = TextValue(text: "Stanza break")
            }
            let item = ItemRecord(
                kind: "item",
                deck: "poem",
                type: "poem-line",
                fields: fields,
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

    private static let poemTypeRecord = TypeRecord(
        kind: "type",
        id: "poem-line",
        name: "Poem Line",
        fields: [
            FieldRecord(id: "front", name: "Front", type: "text", required: true),
            FieldRecord(id: "back", name: "Back", type: "text", required: true),
            FieldRecord(id: "attribution", name: "Attribution", type: "text", required: true),
            FieldRecord(id: "stanza-break", name: "Stanza Break", type: "text", required: false),
        ],
        templates: [
            TemplateRecord(
                name: "Card",
                layout: "focus",
                components: [
                    ComponentRecord(
                        region: "label",
                        purpose: "supporting",
                        field: "attribution",
                        reveal: "always"
                    ),
                    ComponentRecord(
                        region: "primary",
                        purpose: "question",
                        field: "front",
                        reveal: "always"
                    ),
                    ComponentRecord(
                        region: "secondary",
                        purpose: "expectedAnswer",
                        field: "stanza-break",
                        reveal: "hiddenUntilAnswer"
                    ),
                    ComponentRecord(
                        region: "secondary",
                        purpose: "expectedAnswer",
                        field: "back",
                        reveal: "hiddenUntilAnswer"
                    ),
                ],
                prompt: [
                    SlotRecord(field: "attribution"),
                    SlotRecord(field: "front"),
                ],
                answer: [
                    SlotRecord(field: "stanza-break", reveal: "hiddenUntilAnswer"),
                    SlotRecord(field: "back", reveal: "hiddenUntilAnswer"),
                ],
                interaction: "reveal",
                skill: SkillRecord(input: "text", output: "text", operation: "recall")
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
    let itemTypes: [String]?
    let defaultType: String?
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
    let layout: String
    let components: [ComponentRecord]
    let prompt: [SlotRecord]
    let answer: [SlotRecord]
    let interaction: String
    let skill: SkillRecord
}

private struct SlotRecord: Encodable {
    let field: String
    let reveal: String?

    init(field: String, reveal: String? = nil) {
        self.field = field
        self.reveal = reveal
    }
}

private struct ComponentRecord: Encodable {
    let region: String
    let purpose: String
    let field: String
    let reveal: String
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
