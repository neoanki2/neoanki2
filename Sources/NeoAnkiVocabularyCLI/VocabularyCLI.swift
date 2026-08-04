import Foundation
import NeoAnkiVocabularyKit

public struct VocabularyCLI {
    public static let usage = """
    neoanki-vocab — local-only vocabulary pack tools

    Commands:
      compile  --input entries.jsonl --output Pack.neovocab --id ID --title TITLE
               --language CODE [--language CODE ...] --capability NAME [...]
               [--media-directory DIR] [--source-id ID] [--source-name NAME]
               [--attribution TEXT] [--license TEXT] [--source-url URL]
      validate --pack Pack.neovocab
      search   --pack Pack.neovocab --query TEXT [--exact] [--language CODE]
               [--limit 1...500] [--json]

    This executable never downloads data. Every input, output, pack, and media
    argument must be a local filesystem path.
    """

    public init() {}

    public func run(
        arguments: [String],
        output: @escaping (String) -> Void = { print($0) },
        errorOutput: @escaping (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) async -> Int32 {
        do {
            guard let command = arguments.first, !["help", "--help", "-h"].contains(command) else {
                output(Self.usage)
                return 0
            }
            let options = try ParsedOptions(Array(arguments.dropFirst()))
            switch command {
            case "compile":
                try compile(options: options, output: output)
            case "validate":
                try await validate(options: options, output: output)
            case "search":
                try await search(options: options, output: output)
            default:
                throw CLIError.usage("Unknown command \(command).")
            }
            return 0
        } catch {
            errorOutput("error: \(error.localizedDescription)")
            if error is CLIError { errorOutput("Run neoanki-vocab --help for usage.") }
            return 1
        }
    }

    private func compile(options: ParsedOptions, output: (String) -> Void) throws {
        try options.rejectUnknown([
            "input", "output", "id", "title", "summary", "language", "capability",
            "media-directory", "source-id", "source-name", "record-id", "attribution",
            "license", "source-url",
        ])
        let input = try localURL(options.required("input"), label: "input")
        let destination = try localURL(options.required("output"), label: "output")
        let mediaDirectory = try options.first("media-directory").map {
            try localURL($0, label: "media directory")
        }
        let languages = options.values("language")
        guard !languages.isEmpty else { throw CLIError.usage("At least one --language is required.") }
        let rawCapabilities = options.values("capability")
        guard !rawCapabilities.isEmpty else { throw CLIError.usage("At least one --capability is required.") }
        let capabilities = try Set(rawCapabilities.map { raw in
            guard let capability = VocabularyCapability(rawValue: raw) else {
                throw CLIError.usage(
                    "Unknown capability \(raw). Expected: \(VocabularyCapability.allCases.map(\.rawValue).joined(separator: ", "))."
                )
            }
            return capability
        })
        let provenance = options.first("source-id").map { sourceID in
            Provenance(
                sourceID: sourceID,
                sourceName: options.first("source-name"),
                recordID: options.first("record-id"),
                attribution: options.first("attribution"),
                license: options.first("license"),
                sourceURL: options.first("source-url")
            )
        }
        let manifest = try VocabularyPackCompiler.compile(
            jsonlURL: input,
            to: destination,
            descriptor: VocabularyPackDescriptor(
                id: try options.required("id"),
                title: try options.required("title"),
                summary: options.first("summary"),
                languages: languages,
                capabilities: capabilities,
                provenance: provenance
            ),
            options: .init(mediaDirectoryURL: mediaDirectory)
        )
        output("Compiled \(manifest.entryCount) entries to \(destination.path)")
        output("SHA-256: \(manifest.databaseSHA256)")
    }

    private func validate(options: ParsedOptions, output: (String) -> Void) async throws {
        try options.rejectUnknown(["pack"])
        let packURL = try localURL(options.required("pack"), label: "pack")
        let pack = try await VocabularyPack.open(at: packURL)
        output("Valid offline vocabulary pack: \(pack.manifest.title)")
        output("ID: \(pack.manifest.id)")
        output("Entries: \(pack.manifest.entryCount)")
        output("Languages: \(pack.manifest.languages.joined(separator: ", "))")
        output("Capabilities: \(pack.manifest.capabilities.map(\.rawValue).sorted().joined(separator: ", "))")
    }

    private func search(options: ParsedOptions, output: (String) -> Void) async throws {
        try options.rejectUnknown(["pack", "query", "language", "limit", "exact", "json"])
        let packURL = try localURL(options.required("pack"), label: "pack")
        let query = try options.required("query")
        let limit: Int
        if let rawLimit = options.first("limit") {
            guard let parsed = Int(rawLimit), (1 ... 500).contains(parsed) else {
                throw CLIError.usage("--limit must be an integer from 1 through 500.")
            }
            limit = parsed
        } else {
            limit = 50
        }
        let pack = try await VocabularyPack.open(at: packURL)
        let entries = try await pack.search(
            query: query,
            mode: options.hasFlag("exact") ? .exact : .prefix,
            limit: limit,
            language: options.first("language")
        )
        if options.hasFlag("json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            for entry in entries {
                guard let line = String(data: try encoder.encode(entry), encoding: .utf8) else {
                    throw CLIError.invalidValue("Could not encode search result as UTF-8.")
                }
                output(line)
            }
        } else {
            output("Matches: \(entries.count)")
            for entry in entries {
                output(
                    [
                        entry.id,
                        entry.language,
                        entry.canonicalForm.text.value,
                        "\(entry.senses.count) senses",
                        "\(entry.pronunciations.count) pronunciations",
                    ].joined(separator: "\t")
                )
            }
        }
    }

    private func localURL(_ path: String, label: String) throws -> URL {
        guard !path.contains("://") else {
            throw CLIError.invalidValue("The \(label) must be a local filesystem path, not a URL.")
        }
        return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL
    }
}

private enum CLIError: Error, LocalizedError {
    case usage(String)
    case invalidValue(String)

    var errorDescription: String? {
        switch self {
        case let .usage(message), let .invalidValue(message): message
        }
    }
}

private struct ParsedOptions {
    private var valuesByName: [String: [String]] = [:]
    private var flags: Set<String> = []

    init(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--"), argument.count > 2 else {
                throw CLIError.usage("Unexpected positional argument \(argument).")
            }
            let name = String(argument.dropFirst(2))
            if ["exact", "json"].contains(name) {
                flags.insert(name)
                index += 1
                continue
            }
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                throw CLIError.usage("Option --\(name) requires a value.")
            }
            valuesByName[name, default: []].append(arguments[index + 1])
            index += 2
        }
    }

    func values(_ name: String) -> [String] { valuesByName[name] ?? [] }
    func first(_ name: String) -> String? { valuesByName[name]?.last }
    func hasFlag(_ name: String) -> Bool { flags.contains(name) }

    func required(_ name: String) throws -> String {
        guard let value = first(name), !value.isEmpty else {
            throw CLIError.usage("Missing required option --\(name).")
        }
        return value
    }

    func rejectUnknown(_ allowed: Set<String>) throws {
        let unknown = Set(valuesByName.keys).union(flags).subtracting(allowed)
        guard unknown.isEmpty else {
            throw CLIError.usage("Unknown option(s): \(unknown.sorted().map { "--\($0)" }.joined(separator: ", ")).")
        }
    }
}
