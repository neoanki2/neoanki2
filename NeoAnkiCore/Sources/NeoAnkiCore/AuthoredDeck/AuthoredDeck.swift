import CryptoKit
import Darwin
import Foundation

public struct AuthoredDeckLimits: Sendable, Equatable {
    public var maximumSourceBytes: Int
    public var maximumTotalSourceBytes: Int
    public var maximumLineBytes: Int
    public var maximumParts: Int
    public var portable: PortableDeckLimits

    public init(
        maximumSourceBytes: Int = 64_000_000,
        maximumTotalSourceBytes: Int = 64_000_000,
        maximumLineBytes: Int = 1_048_576,
        maximumParts: Int = 1_000,
        portable: PortableDeckLimits = .default
    ) {
        self.maximumSourceBytes = max(0, maximumSourceBytes)
        self.maximumTotalSourceBytes = max(0, maximumTotalSourceBytes)
        self.maximumLineBytes = max(0, maximumLineBytes)
        self.maximumParts = max(0, maximumParts)
        self.portable = portable
    }

    public static let `default` = AuthoredDeckLimits()
}

public struct AuthoredDeckDiagnostic: Error, Sendable, Equatable, LocalizedError {
    public let file: String
    public let line: Int
    public let code: String
    public let message: String

    public init(file: String, line: Int, code: String, message: String) {
        self.file = file
        self.line = line
        self.code = code
        self.message = message
    }

    public var errorDescription: String? {
        "\(file):\(line): \(code): \(message)"
    }
}

public enum AuthoredDeckError: Error, Sendable, Equatable, LocalizedError {
    case invalid([AuthoredDeckDiagnostic])

    public var errorDescription: String? {
        switch self {
        case let .invalid(diagnostics):
            diagnostics.first?.localizedDescription ?? "The authored deck is invalid."
        }
    }
}

public enum AuthoredDeck {
    public static let fileExtension = "neoanki"
    public static let manifestName = "deck.jsonl"

    public static func validate(
        at bundleURL: URL,
        limits: AuthoredDeckLimits = .default
    ) -> [AuthoredDeckDiagnostic] {
        do {
            return try AuthoredDeckLoader(bundleURL: bundleURL, limits: limits).load().diagnostics
        } catch let diagnostic as AuthoredDeckDiagnostic {
            return [diagnostic]
        } catch {
            return [
                AuthoredDeckDiagnostic(
                    file: manifestName,
                    line: 1,
                    code: "AD000",
                    message: "Could not read the authored deck: \(error.localizedDescription)"
                ),
            ]
        }
    }

    public static func importDeck(
        from bundleURL: URL,
        into store: ItemStore,
        limits: AuthoredDeckLimits = .default,
        now: Date = .now
    ) async throws -> PortableDeckImportResult {
        let loaded = try await Task.detached(priority: .userInitiated) {
            try AuthoredDeckLoader(bundleURL: bundleURL, limits: limits).load()
        }.value
        guard loaded.diagnostics.isEmpty, let package = loaded.package else {
            throw AuthoredDeckError.invalid(loaded.diagnostics)
        }
        let staged: (package: AuthoredDeckPackage, directory: URL?)
        do {
            staged = try await Task.detached(priority: .userInitiated) {
                try stageMedia(package, from: bundleURL)
            }.value
        } catch let failure as DecodeFailure {
            throw AuthoredDeckError.invalid([
                failure.diagnostic(at: .init(file: "media", line: 1)),
            ])
        }
        defer {
            if let directory = staged.directory {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        return try await store.importAuthoredDeck(
            staged.package,
            limits: limits.portable,
            now: now,
            destinationDeckID: nil
        )
    }

    /// Imports the authored items atomically into an existing deck without
    /// creating the deck hierarchy declared by the source bundle.
    ///
    /// This is the app-extension boundary for generators that add material to
    /// a user's deck. The authored bundle is still fully validated and its
    /// item types and media are resolved through the normal import pipeline.
    public static func importItems(
        from bundleURL: URL,
        into store: ItemStore,
        deckID: UUID,
        limits: AuthoredDeckLimits = .default,
        now: Date = .now
    ) async throws -> PortableDeckImportResult {
        let loaded = try await Task.detached(priority: .userInitiated) {
            try AuthoredDeckLoader(bundleURL: bundleURL, limits: limits).load()
        }.value
        guard loaded.diagnostics.isEmpty, let package = loaded.package else {
            throw AuthoredDeckError.invalid(loaded.diagnostics)
        }
        let staged: (package: AuthoredDeckPackage, directory: URL?)
        do {
            staged = try await Task.detached(priority: .userInitiated) {
                try stageMedia(package, from: bundleURL)
            }.value
        } catch let failure as DecodeFailure {
            throw AuthoredDeckError.invalid([
                failure.diagnostic(at: .init(file: "media", line: 1)),
            ])
        }
        defer {
            if let directory = staged.directory {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        return try await store.importAuthoredDeck(
            staged.package,
            limits: limits.portable,
            now: now,
            destinationDeckID: deckID
        )
    }

    private static func stageMedia(
        _ package: AuthoredDeckPackage,
        from bundleURL: URL
    ) throws -> (package: AuthoredDeckPackage, directory: URL?) {
        guard !package.media.isEmpty else { return (package, nil) }
        let root = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoanki-authored-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            var stagedMedia: [PortableDeckMediaRecord] = []
            for record in package.media {
                guard record.fileURL.path.hasPrefix(rootPath) else {
                    throw DecodeFailure("AD270", "Media source is outside the authored bundle.")
                }
                let relativePath = String(record.fileURL.path.dropFirst(rootPath.count))
                let destination = directory.appendingPathComponent(
                    "\(record.descriptor.hash).\(record.descriptor.fileExtension)"
                )
                let descriptor = try copyConfinedFile(
                    root: root,
                    relativePath: relativePath,
                    destination: destination,
                    kind: record.descriptor.kind
                )
                guard descriptor == record.descriptor else {
                    throw DecodeFailure("AD271", "Media changed after validation.")
                }
                stagedMedia.append(.init(descriptor: descriptor, fileURL: destination))
            }
            return (
                .init(
                    rootDeckID: package.rootDeckID,
                    decks: package.decks,
                    itemTypes: package.itemTypes,
                    items: package.items,
                    media: stagedMedia,
                    usesIncludedItemTypes: package.usesIncludedItemTypes,
                    itemTypePolicies: package.itemTypePolicies
                ),
                directory
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

struct AuthoredDeckPackage: Sendable {
    let rootDeckID: UUID
    let decks: [Deck]
    let itemTypes: [ItemType]
    let items: [PortableDeckPersistedItem]
    let media: [PortableDeckMediaRecord]
    let usesIncludedItemTypes: Bool
    let itemTypePolicies: [DeckItemTypePolicyEntry]
}

private struct LoadedAuthoredDeck: Sendable {
    let package: AuthoredDeckPackage?
    let diagnostics: [AuthoredDeckDiagnostic]
}

private struct SourceLocation {
    let file: String
    let line: Int
}

private struct ManifestRecord {
    let version: Int
    let root: String
    let parts: [String]
    let location: SourceLocation
}

private struct DeckRecord {
    let key: String
    let name: String
    let parent: String?
    let itemTypes: [String]?
    let defaultType: String?
    let location: SourceLocation
}

private struct TypeRecord {
    let key: String
    let name: String
    let fields: [FieldRecord]
    let templates: [TemplateRecord]
    let location: SourceLocation
}

private struct FieldRecord {
    let key: String
    let name: String
    let kind: FieldType
    let required: Bool
}

private struct TemplateRecord {
    let name: String
    let prompt: [SlotRecord]
    let answer: [SlotRecord]
    let interaction: Interaction
    let skill: Skill
    let condition: ConditionRecord?
}

private struct SlotRecord {
    enum Source {
        case field(String)
        case literal(String)
    }

    let source: Source
    let reveal: RevealMode
    let media: MediaBehavior
}

private indirect enum ConditionRecord {
    case fieldNotEmpty(String)
    case fieldEmpty(String)
    case all([ConditionRecord])
    case any([ConditionRecord])
}

private struct ItemRecord {
    let type: String
    let deck: String
    let fields: [String: Any]
    let tags: [String]
    let location: SourceLocation
}

private struct AuthoredDeckLoader {
    private let bundleURL: URL
    private let limits: AuthoredDeckLimits
    private let fileManager = FileManager.default

    init(bundleURL: URL, limits: AuthoredDeckLimits) {
        self.bundleURL = bundleURL
        self.limits = limits
    }

    func load() throws -> LoadedAuthoredDeck {
        var diagnostics: [AuthoredDeckDiagnostic] = []
        var totalSourceBytes = 0
        let root = try validatedBundleRoot()
        let manifestURL = root.appendingPathComponent(AuthoredDeck.manifestName, isDirectory: false)
        let manifestRecords = readRecords(
            at: manifestURL,
            relativePath: AuthoredDeck.manifestName,
            allowedKinds: ["neoanki", "type", "deck"],
            maximumRecords: limits.portable.maximumDecks
                + limits.portable.maximumItemTypes + 1,
            totalSourceBytes: &totalSourceBytes,
            diagnostics: &diagnostics
        )

        var manifest: ManifestRecord?
        var types: [TypeRecord] = []
        var rawDecks: [RawRecord] = []
        for record in manifestRecords {
            do {
                switch try requiredString(record.object, "kind") {
                case "neoanki":
                    guard manifest == nil else {
                        throw DecodeFailure("AD101", "Only one neoanki manifest record is allowed.")
                    }
                    manifest = try decodeManifest(record.object, location: record.location)
                case "type":
                    types.append(try decodeType(record.object, location: record.location))
                case "deck":
                    rawDecks.append(record)
                default:
                    break
                }
            } catch let failure as DecodeFailure {
                diagnostics.append(failure.diagnostic(at: record.location))
            } catch {
                diagnostics.append(decodeDiagnostic(error, at: record.location))
            }
        }

        guard let manifest else {
            diagnostics.append(.init(
                file: AuthoredDeck.manifestName,
                line: 1,
                code: "AD102",
                message: "Add one manifest record with kind \"neoanki\"."
            ))
            return .init(package: nil, diagnostics: diagnostics)
        }
        var decks: [DeckRecord] = []
        for record in rawDecks {
            do {
                decks.append(try decodeDeck(
                    record.object,
                    version: manifest.version,
                    location: record.location
                ))
            } catch let failure as DecodeFailure {
                diagnostics.append(failure.diagnostic(at: record.location))
            } catch {
                diagnostics.append(decodeDiagnostic(error, at: record.location))
            }
        }

        var items: [ItemRecord] = []
        if manifest.parts.count > limits.maximumParts {
            diagnostics.append(.init(
                file: manifest.location.file,
                line: manifest.location.line,
                code: "AD103",
                message: "The manifest lists more than \(limits.maximumParts) item parts."
            ))
        } else {
            var seenParts: Set<String> = []
            for part in manifest.parts {
                do {
                    guard seenParts.insert(part).inserted else {
                        throw DecodeFailure("AD104", "Item part \"\(part)\" is listed more than once.")
                    }
                    let partURL = try resolveSourcePath(part, beneath: root)
                    let remainingItems = max(0, limits.portable.maximumItems - items.count)
                    let records = readRecords(
                        at: partURL,
                        relativePath: part,
                        allowedKinds: ["item"],
                        maximumRecords: remainingItems,
                        totalSourceBytes: &totalSourceBytes,
                        diagnostics: &diagnostics
                    )
                    for record in records {
                        do {
                            items.append(try decodeItem(record.object, location: record.location))
                        } catch let failure as DecodeFailure {
                            diagnostics.append(failure.diagnostic(at: record.location))
                        } catch {
                            diagnostics.append(decodeDiagnostic(error, at: record.location))
                        }
                    }
                } catch let failure as DecodeFailure {
                    diagnostics.append(failure.diagnostic(at: manifest.location))
                } catch {
                    diagnostics.append(.init(
                        file: manifest.location.file,
                        line: manifest.location.line,
                        code: "AD105",
                        message: "Could not read item part \"\(part)\": \(error.localizedDescription)"
                    ))
                }
            }
            do {
                let undeclared = try discoveredItemParts(beneath: root)
                    .subtracting(seenParts)
                    .sorted()
                for part in undeclared {
                    diagnostics.append(.init(
                        file: part,
                        line: 1,
                        code: "AD109",
                        message: "Item part is not declared in the manifest."
                    ))
                }
            } catch let failure as DecodeFailure {
                diagnostics.append(failure.diagnostic(at: manifest.location))
            }
        }

        guard diagnostics.isEmpty else {
            return .init(package: nil, diagnostics: diagnostics)
        }
        let compiler = AuthoredDeckCompiler(
            root: root,
            manifest: manifest,
            types: types,
            decks: decks,
            items: items,
            limits: limits
        )
        let result = compiler.compile()
        return .init(package: result.package, diagnostics: result.diagnostics)
    }

    private func validatedBundleRoot() throws -> URL {
        guard bundleURL.isFileURL,
              bundleURL.pathExtension.lowercased() == AuthoredDeck.fileExtension else {
            throw AuthoredDeckDiagnostic(
                file: AuthoredDeck.manifestName,
                line: 1,
                code: "AD001",
                message: "Choose a .neoanki source bundle."
            )
        }
        let values = try bundleURL.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey,
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw AuthoredDeckDiagnostic(
                file: AuthoredDeck.manifestName,
                line: 1,
                code: "AD002",
                message: "An authored deck must be a regular .neoanki directory."
            )
        }
        return bundleURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func resolveSourcePath(_ path: String, beneath root: URL) throws -> URL {
        guard !path.isEmpty,
              path.hasPrefix("items/"),
              path.hasSuffix(".jsonl"),
              !path.hasPrefix("/"),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0 != ".." && $0 != "."
              }),
              path.unicodeScalars.allSatisfy({ $0.value >= 0x20 })
        else {
            throw DecodeFailure("AD106", "Item parts must be relative .jsonl paths without \"..\".")
        }
        try rejectSymlinkComponents(path, beneath: root)
        let candidate = root.appendingPathComponent(path, isDirectory: false).standardizedFileURL
        let values = try candidate.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw DecodeFailure("AD107", "Item part \"\(path)\" must be a regular, non-symlink file.")
        }
        let resolved = candidate.resolvingSymlinksInPath()
        guard isContained(resolved, in: root) else {
            throw DecodeFailure("AD108", "Item part \"\(path)\" escapes the source bundle.")
        }
        return resolved
    }

    private func discoveredItemParts(beneath root: URL) throws -> Set<String> {
        try discoverConfinedItemParts(root: root, maximumParts: limits.maximumParts)
    }

    private func rejectSymlinkComponents(_ path: String, beneath root: URL) throws {
        var cursor = root
        for component in path.split(separator: "/") {
            cursor.appendPathComponent(String(component))
            let values = try cursor.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw DecodeFailure("AD108", "Source path \"\(path)\" contains a symlink.")
            }
        }
    }

    private struct RawRecord {
        let object: [String: Any]
        let location: SourceLocation
    }

    private func readRecords(
        at _: URL,
        relativePath: String,
        allowedKinds: Set<String>,
        maximumRecords: Int,
        totalSourceBytes: inout Int,
        diagnostics: inout [AuthoredDeckDiagnostic]
    ) -> [RawRecord] {
        do {
            let data = try readConfinedRegularFile(
                root: bundleURL.standardizedFileURL.resolvingSymlinksInPath(),
                relativePath: relativePath,
                maximumBytes: limits.maximumSourceBytes,
                remainingTotalBytes: max(
                    0,
                    limits.maximumTotalSourceBytes - totalSourceBytes
                )
            )
            let size = data.count
            let (newTotal, overflow) = totalSourceBytes.addingReportingOverflow(size)
            guard !overflow, newTotal <= limits.maximumTotalSourceBytes else {
                throw DecodeFailure(
                    "AD018",
                    "Authored deck source exceeds the \(limits.maximumTotalSourceBytes)-byte total limit."
                )
            }
            totalSourceBytes = newTotal
            guard let source = String(data: data, encoding: .utf8) else {
                throw DecodeFailure("AD012", "Source must be valid UTF-8 without a byte-order mark.")
            }
            guard !source.hasPrefix("\u{FEFF}") else {
                throw DecodeFailure("AD012", "Source must be UTF-8 without a byte-order mark.")
            }
            var result: [RawRecord] = []
            for (offset, rawLine) in source.split(
                separator: "\n",
                omittingEmptySubsequences: false
            ).enumerated() {
                let lineNumber = offset + 1
                let line = rawLine.last == "\r" ? rawLine.dropLast() : rawLine[...]
                if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                guard line.utf8.count <= limits.maximumLineBytes else {
                    diagnostics.append(.init(
                        file: relativePath,
                        line: lineNumber,
                        code: "AD013",
                        message: "Record exceeds the \(limits.maximumLineBytes)-byte line limit."
                    ))
                    continue
                }
                do {
                    guard result.count < maximumRecords else {
                        diagnostics.append(.init(
                            file: relativePath,
                            line: lineNumber,
                            code: "AD019",
                            message: "Source contains more records than the configured limit."
                        ))
                        break
                    }
                    let lineData = Data(line.utf8)
                    if let duplicate = JSONDuplicateKeyDetector.firstDuplicate(in: lineData) {
                        throw DecodeFailure(
                            "AD032",
                            "JSON object member \"\(duplicate)\" appears more than once."
                        )
                    }
                    let value = try JSONSerialization.jsonObject(with: lineData)
                    guard let object = value as? [String: Any] else {
                        throw DecodeFailure("AD014", "Each line must contain one JSON object.")
                    }
                    let kind = try requiredString(object, "kind")
                    guard allowedKinds.contains(kind) else {
                        throw DecodeFailure(
                            "AD015",
                            "Record kind \"\(kind)\" is not allowed in \(relativePath)."
                        )
                    }
                    result.append(.init(
                        object: object,
                        location: .init(file: relativePath, line: lineNumber)
                    ))
                } catch let failure as DecodeFailure {
                    diagnostics.append(failure.diagnostic(
                        at: .init(file: relativePath, line: lineNumber)
                    ))
                } catch {
                    diagnostics.append(.init(
                        file: relativePath,
                        line: lineNumber,
                        code: "AD016",
                        message: "Malformed JSON record: \(error.localizedDescription)"
                    ))
                }
            }
            return result
        } catch let failure as DecodeFailure {
            diagnostics.append(failure.diagnostic(at: .init(file: relativePath, line: 1)))
        } catch {
            diagnostics.append(.init(
                file: relativePath,
                line: 1,
                code: "AD017",
                message: "Could not read source: \(error.localizedDescription)"
            ))
        }
        return []
    }

    private func decodeManifest(
        _ object: [String: Any],
        location: SourceLocation
    ) throws -> ManifestRecord {
        try exactKeys(object, required: ["kind", "version", "root", "parts"])
        guard try requiredString(object, "kind") == "neoanki" else {
            throw DecodeFailure("AD110", "Manifest kind must be \"neoanki\".")
        }
        let version = try requiredInteger(object, "version")
        guard (1...3).contains(version) else {
            throw DecodeFailure("AD111", "Only authored deck versions 1 through 3 are supported.")
        }
        return .init(
            version: version,
            root: try identifier(object, "root"),
            parts: try stringArray(object, "parts"),
            location: location
        )
    }

    private func decodeDeck(
        _ object: [String: Any],
        version: Int,
        location: SourceLocation
    ) throws -> DeckRecord {
        let optional = version >= 3
            ? ["parent", "itemTypes", "defaultType"]
            : ["parent"]
        try exactKeys(object, required: ["kind", "id", "name"], optional: Set(optional))
        return .init(
            key: try identifier(object, "id"),
            name: try nonemptyString(object, "name"),
            parent: try optionalIdentifier(object, "parent"),
            itemTypes: version >= 3 ? try optionalIdentifierArray(object, "itemTypes") : nil,
            defaultType: version >= 3 ? try optionalIdentifier(object, "defaultType") : nil,
            location: location
        )
    }

    private func decodeType(
        _ object: [String: Any],
        location: SourceLocation
    ) throws -> TypeRecord {
        try exactKeys(object, required: ["kind", "id", "name", "fields", "templates"])
        let fields = try objectArray(object, "fields").map { field -> FieldRecord in
            try exactKeys(field, required: ["id", "name", "type"], optional: ["required"])
            guard let kind = FieldType(rawValue: try requiredString(field, "type")) else {
                throw DecodeFailure("AD120", "Field type is not supported.")
            }
            return .init(
                key: try identifier(field, "id"),
                name: try nonemptyString(field, "name"),
                kind: kind,
                required: try optionalBool(field, "required") ?? false
            )
        }
        let templates = try objectArray(object, "templates").map(decodeTemplate)
        return .init(
            key: try identifier(object, "id"),
            name: try nonemptyString(object, "name"),
            fields: fields,
            templates: templates,
            location: location
        )
    }

    private func decodeTemplate(_ object: [String: Any]) throws -> TemplateRecord {
        try exactKeys(
            object,
            required: ["name", "prompt", "answer", "interaction", "skill"],
            optional: ["generateWhen"]
        )
        guard let interaction = Interaction(rawValue: try requiredString(object, "interaction")) else {
            throw DecodeFailure("AD121", "Template interaction is not supported.")
        }
        let skillObject = try requiredObject(object, "skill")
        try exactKeys(skillObject, required: ["input", "output", "operation"])
        guard let input = Modality(rawValue: try requiredString(skillObject, "input")),
              let output = Modality(rawValue: try requiredString(skillObject, "output")),
              let operation = Operation(rawValue: try requiredString(skillObject, "operation")) else {
            throw DecodeFailure("AD122", "Template skill contains an unsupported value.")
        }
        return .init(
            name: try nonemptyString(object, "name"),
            prompt: try objectArray(object, "prompt").map(decodeSlot),
            answer: try objectArray(object, "answer").map(decodeSlot),
            interaction: interaction,
            skill: Skill(input: input, output: output, operation: operation),
            condition: try object["generateWhen"].map { try decodeCondition($0, depth: 0) }
        )
    }

    private func decodeSlot(_ object: [String: Any]) throws -> SlotRecord {
        try exactKeys(
            object,
            required: [],
            optional: ["field", "literal", "reveal", "media"]
        )
        let hasField = object["field"] != nil
        let hasLiteral = object["literal"] != nil
        guard hasField != hasLiteral else {
            throw DecodeFailure("AD123", "A slot needs exactly one of \"field\" or \"literal\".")
        }
        let source: SlotRecord.Source = if hasField {
            .field(try identifier(object, "field"))
        } else {
            .literal(try requiredString(object, "literal"))
        }
        let revealText = try optionalString(object, "reveal") ?? RevealMode.always.rawValue
        let mediaText = try optionalString(object, "media") ?? MediaBehavior.default.rawValue
        guard let reveal = RevealMode(rawValue: revealText),
              let media = MediaBehavior(rawValue: mediaText) else {
            throw DecodeFailure("AD124", "A slot contains an unsupported presentation value.")
        }
        return .init(source: source, reveal: reveal, media: media)
    }

    private func decodeCondition(_ raw: Any, depth: Int) throws -> ConditionRecord {
        guard depth <= 64, let object = raw as? [String: Any], object.count == 1,
              let key = object.keys.first else {
            throw DecodeFailure("AD125", "Generation condition is malformed or too deeply nested.")
        }
        switch key {
        case "fieldNotEmpty":
            return .fieldNotEmpty(try identifier(object, key))
        case "fieldEmpty":
            return .fieldEmpty(try identifier(object, key))
        case "all", "any":
            guard let rawChildren = object[key] as? [Any], !rawChildren.isEmpty else {
                throw DecodeFailure("AD126", "Condition \(key) needs at least one child.")
            }
            let children = try rawChildren.map { try decodeCondition($0, depth: depth + 1) }
            return key == "all" ? .all(children) : .any(children)
        default:
            throw DecodeFailure("AD127", "Unknown generation condition \"\(key)\".")
        }
    }

    private func decodeItem(
        _ object: [String: Any],
        location: SourceLocation
    ) throws -> ItemRecord {
        try exactKeys(object, required: ["kind", "deck", "type", "fields"], optional: ["tags"])
        guard let fields = object["fields"] as? [String: Any] else {
            throw DecodeFailure("AD130", "Item fields must be a JSON object.")
        }
        return .init(
            type: try identifier(object, "type"),
            deck: try identifier(object, "deck"),
            fields: fields,
            tags: try optionalStringArray(object, "tags") ?? [],
            location: location
        )
    }
}

private struct AuthoredDeckCompiler {
    let root: URL
    let manifest: ManifestRecord
    let types: [TypeRecord]
    let decks: [DeckRecord]
    let items: [ItemRecord]
    let limits: AuthoredDeckLimits

    func compile() -> LoadedAuthoredDeck {
        var diagnostics: [AuthoredDeckDiagnostic] = []
        guard decks.count <= limits.portable.maximumDecks else {
            return failure("AD200", "The authored deck contains too many decks.", at: manifest.location)
        }
        guard types.count <= limits.portable.maximumItemTypes else {
            return failure("AD201", "The authored deck contains too many item types.", at: manifest.location)
        }
        guard items.count <= limits.portable.maximumItems else {
            return failure("AD202", "The authored deck contains too many items.", at: manifest.location)
        }

        let deckGroups = Dictionary(grouping: decks, by: \.key)
        for (key, records) in deckGroups where records.count > 1 {
            diagnostics.append(diag("AD203", "Deck identifier \"\(key)\" is duplicated.", at: records[1].location))
        }
        let typeGroups = Dictionary(grouping: types, by: \.key)
        for (key, records) in typeGroups where records.count > 1 {
            diagnostics.append(diag("AD204", "Item type identifier \"\(key)\" is duplicated.", at: records[1].location))
        }
        guard diagnostics.isEmpty else { return .init(package: nil, diagnostics: diagnostics) }

        let deckByKey = Dictionary(uniqueKeysWithValues: decks.map { ($0.key, $0) })
        guard deckByKey[manifest.root] != nil else {
            return failure(
                "AD205",
                "Root deck \"\(manifest.root)\" is not declared.",
                at: manifest.location
            )
        }
        for record in decks {
            if record.key == manifest.root, record.parent != nil {
                diagnostics.append(diag("AD206", "The root deck cannot have a parent.", at: record.location))
            } else if record.key != manifest.root {
                guard let parent = record.parent, deckByKey[parent] != nil else {
                    diagnostics.append(diag(
                        "AD207",
                        "Deck \"\(record.key)\" needs a declared parent.",
                        at: record.location
                    ))
                    continue
                }
            }
            var seen: Set<String> = []
            var cursor: String? = record.key
            while let current = cursor {
                guard seen.insert(current).inserted else {
                    diagnostics.append(diag("AD208", "Deck hierarchy contains a cycle.", at: record.location))
                    break
                }
                cursor = deckByKey[current]?.parent
            }
        }

        var compiledTypes: [String: ItemType] = [:]
        var fieldKeysByType: [String: [String: FieldDef]] = [:]
        for record in types {
            if record.fields.count > limits.portable.maximumFieldsPerType
                || record.templates.count > limits.portable.maximumTemplatesPerType {
                diagnostics.append(diag("AD209", "Item type exceeds field or template limits.", at: record.location))
                continue
            }
            let duplicateFields = Dictionary(grouping: record.fields, by: \.key)
                .first(where: { $0.value.count > 1 })?.key
            if let duplicateFields {
                diagnostics.append(diag(
                    "AD210",
                    "Field identifier \"\(duplicateFields)\" is duplicated.",
                    at: record.location
                ))
                continue
            }
            let fields = record.fields.map {
                FieldDef(name: $0.name, type: $0.kind, isRequired: $0.required)
            }
            let fieldsByKey = Dictionary(uniqueKeysWithValues: zip(record.fields.map(\.key), fields))
            do {
                guard record.templates.allSatisfy({
                    $0.prompt.count <= 512
                        && $0.answer.count <= 512
                        && ($0.condition.map(conditionNodeCount) ?? 0) <= 1_024
                }) else {
                    throw DecodeFailure("AD212", "A template exceeds slot or condition limits.")
                }
                let templates = try record.templates.map {
                    try compileTemplate($0, fields: fieldsByKey)
                }
                let itemType = ItemType(name: record.name, fields: fields, templates: templates)
                try ItemTypeValidation.validate(itemType)
                compiledTypes[record.key] = itemType
                fieldKeysByType[record.key] = fieldsByKey
            } catch {
                diagnostics.append(diag(
                    "AD211",
                    "Invalid item type \"\(record.key)\": \(error.localizedDescription)",
                    at: record.location
                ))
            }
        }
        guard diagnostics.isEmpty else { return .init(package: nil, diagnostics: diagnostics) }

        if manifest.version >= 3 {
            for record in decks {
                if record.key == manifest.root, record.itemTypes?.isEmpty != false {
                    diagnostics.append(diag(
                        "AD213",
                        "The version 3 root deck needs a non-empty itemTypes policy.",
                        at: record.location
                    ))
                }
                if let itemTypes = record.itemTypes {
                    if itemTypes.isEmpty {
                        diagnostics.append(diag(
                            "AD214",
                            "A declared itemTypes policy cannot be empty.",
                            at: record.location
                        ))
                    }
                    if Set(itemTypes).count != itemTypes.count {
                        diagnostics.append(diag(
                            "AD215",
                            "A deck itemTypes policy cannot contain duplicates.",
                            at: record.location
                        ))
                    }
                    for key in itemTypes where compiledTypes[key] == nil {
                        diagnostics.append(diag(
                            "AD216",
                            "Deck policy references unknown item type \"\(key)\".",
                            at: record.location
                        ))
                    }
                }
                if let defaultType = record.defaultType {
                    guard let local = record.itemTypes, local.contains(defaultType) else {
                        diagnostics.append(diag(
                            "AD217",
                            "defaultType must appear in the same deck's itemTypes policy.",
                            at: record.location
                        ))
                        continue
                    }
                }
            }
        }
        guard diagnostics.isEmpty else { return .init(package: nil, diagnostics: diagnostics) }

        let deckIDs = Dictionary(uniqueKeysWithValues: decks.map { ($0.key, UUID()) })
        let compiledDecks = decks.compactMap { record -> Deck? in
            guard let id = deckIDs[record.key] else { return nil }
            return Deck(
                id: id,
                name: record.name,
                parentID: record.parent.flatMap { deckIDs[$0] }
            )
        }
        let compiledPolicies: [DeckItemTypePolicyEntry] = manifest.version >= 3
            ? decks.flatMap { record -> [DeckItemTypePolicyEntry] in
                guard let deckID = deckIDs[record.key],
                      let keys = record.itemTypes else { return [] }
                return keys.enumerated().compactMap { ordinal, key in
                    guard let itemType = compiledTypes[key] else { return nil }
                    return DeckItemTypePolicyEntry(
                        deckID: deckID,
                        itemTypeID: itemType.id,
                        ordinal: ordinal,
                        isDefault: record.defaultType == key
                    )
                }
            }
            : []
        var compiledItems: [PortableDeckPersistedItem] = []
        var mediaByHash: [String: PortableDeckMediaRecord] = [:]
        var totalMediaBytes: Int64 = 0
        for record in items {
            guard let type = compiledTypes[record.type],
                  let fieldsByKey = fieldKeysByType[record.type] else {
                diagnostics.append(diag(
                    "AD220",
                    "Item references unknown type \"\(record.type)\".",
                    at: record.location
                ))
                continue
            }
            guard let deckID = deckIDs[record.deck] else {
                diagnostics.append(diag(
                    "AD221",
                    "Item references unknown deck \"\(record.deck)\".",
                    at: record.location
                ))
                continue
            }
            let unknownFields = Set(record.fields.keys).subtracting(fieldsByKey.keys)
            guard unknownFields.isEmpty else {
                diagnostics.append(diag(
                    "AD222",
                    "Item contains unknown field \"\(unknownFields.sorted()[0])\".",
                    at: record.location
                ))
                continue
            }
            do {
                let values = try fieldsByKey.map { key, definition -> FieldValue in
                    let value: ContentValue
                    if let raw = record.fields[key] {
                        value = try compileValue(
                            raw,
                            definition: definition,
                            mediaByHash: &mediaByHash,
                            totalMediaBytes: &totalMediaBytes
                        )
                    } else {
                        value = .empty
                    }
                    if definition.isRequired, value.isEmpty {
                        throw DecodeFailure(
                            "AD223",
                            "Required field \"\(key)\" is empty."
                        )
                    }
                    return FieldValue(fieldID: definition.id, value: value)
                }
                guard record.tags.count <= limits.portable.maximumTagsPerItem,
                      record.tags.allSatisfy({
                          !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              && $0.utf8.count <= 1_024
                      }) else {
                    throw DecodeFailure("AD224", "Item tags are empty, too long, or too numerous.")
                }
                let item = Item(
                    itemTypeID: type.id,
                    fields: type.fields.map { definition in
                        values.first(where: { $0.fieldID == definition.id })!
                    },
                    tags: record.tags,
                    deckID: deckID
                )
                compiledItems.append(.init(item: item, createdAt: .now, updatedAt: .now))
            } catch let failure as DecodeFailure {
                diagnostics.append(failure.diagnostic(at: record.location))
            } catch {
                diagnostics.append(diag("AD225", error.localizedDescription, at: record.location))
            }
        }
        guard diagnostics.isEmpty else { return .init(package: nil, diagnostics: diagnostics) }
        guard mediaByHash.count <= limits.portable.maximumMediaAssets else {
            return failure("AD226", "The authored deck references too many media assets.", at: manifest.location)
        }
        let package = AuthoredDeckPackage(
            rootDeckID: deckIDs[manifest.root]!,
            decks: compiledDecks,
            itemTypes: types.compactMap { compiledTypes[$0.key] },
            items: compiledItems,
            media: mediaByHash.values.sorted { $0.descriptor.hash < $1.descriptor.hash },
            usesIncludedItemTypes: manifest.version >= 3,
            itemTypePolicies: compiledPolicies
        )
        return .init(package: package, diagnostics: [])
    }

    private func compileTemplate(
        _ record: TemplateRecord,
        fields: [String: FieldDef]
    ) throws -> Template {
        Template(
            name: record.name,
            prompt: Side(slots: try record.prompt.map { try compileSlot($0, fields: fields) }),
            answer: Side(slots: try record.answer.map { try compileSlot($0, fields: fields) }),
            interaction: record.interaction,
            skill: record.skill,
            generateWhen: try record.condition.map { try compileCondition($0, fields: fields) }
        )
    }

    private func compileSlot(_ record: SlotRecord, fields: [String: FieldDef]) throws -> Slot {
        let source: SlotSource
        switch record.source {
        case let .field(key):
            guard let field = fields[key] else {
                throw DecodeFailure("AD230", "Template references unknown field \"\(key)\".")
            }
            source = .field(field.id)
        case let .literal(value):
            try validateAuthoredText(value)
            source = .literal(value)
        }
        return Slot(
            source: source,
            presentation: Presentation(reveal: record.reveal, media: record.media)
        )
    }

    private func compileCondition(
        _ record: ConditionRecord,
        fields: [String: FieldDef]
    ) throws -> SlotCondition {
        switch record {
        case let .fieldNotEmpty(key):
            guard let field = fields[key] else {
                throw DecodeFailure("AD231", "Condition references unknown field \"\(key)\".")
            }
            return .fieldNotEmpty(field.id)
        case let .fieldEmpty(key):
            guard let field = fields[key] else {
                throw DecodeFailure("AD231", "Condition references unknown field \"\(key)\".")
            }
            return .fieldEmpty(field.id)
        case let .all(children):
            return .all(try children.map { try compileCondition($0, fields: fields) })
        case let .any(children):
            return .any(try children.map { try compileCondition($0, fields: fields) })
        }
    }

    private func compileValue(
        _ raw: Any,
        definition: FieldDef,
        mediaByHash: inout [String: PortableDeckMediaRecord],
        totalMediaBytes: inout Int64
    ) throws -> ContentValue {
        if raw is NSNull { return .empty }
        guard let object = raw as? [String: Any], object.count == 1 || (
            object["text"] != nil && Set(object.keys).isSubset(of: ["text", "lang"])
        ) else {
            throw DecodeFailure("AD240", "Field \"\(definition.name)\" has a malformed value.")
        }
        switch definition.type {
        case .text:
            try exactKeys(object, required: ["text"], optional: ["lang"])
            let text = try requiredString(object, "text")
            try validateAuthoredText(text)
            return .text(
                text,
                lang: try optionalString(object, "lang")
            )
        case .richText:
            try exactKeys(object, required: ["rich"])
            guard let rawSpans = object["rich"] as? [Any], rawSpans.count <= 4_096 else {
                throw DecodeFailure("AD241", "Rich text must be an array of at most 4096 spans.")
            }
            return .rich(try rawSpans.map { rawSpan in
                guard let span = rawSpan as? [String: Any] else {
                    throw DecodeFailure("AD241", "A rich-text span is malformed.")
                }
                let nativeFormattingKeys = manifest.version >= 2
                    ? ["color", "size", "link"]
                    : []
                try exactKeys(
                    span,
                    required: ["text"],
                    optional: Set(["styles"] + nativeFormattingKeys)
                )
                let styles = try optionalStringArray(span, "styles") ?? []
                let decoded = try styles.map { value -> Span.Style in
                    guard let style = Span.Style(rawValue: value) else {
                        throw DecodeFailure("AD242", "Unknown rich-text style \"\(value)\".")
                    }
                    return style
                }
                guard Set(decoded).count == decoded.count else {
                    throw DecodeFailure("AD243", "Rich-text styles cannot repeat.")
                }
                if manifest.version < 2,
                   decoded.contains(.superscript) || decoded.contains(.subscriptText) {
                    throw DecodeFailure("AD242", "This rich-text style requires authored deck version 2.")
                }
                let text = try requiredString(span, "text")
                try validateAuthoredText(text)
                let textColor = try optionalString(span, "color").map { value -> Span.TextColor in
                    guard let color = Span.TextColor(rawValue: value) else {
                        throw DecodeFailure("AD242", "Unknown rich-text color \"\(value)\".")
                    }
                    return color
                }
                let textSize = try optionalString(span, "size").map { value -> Span.TextSize in
                    guard let size = Span.TextSize(rawValue: value) else {
                        throw DecodeFailure("AD242", "Unknown rich-text size \"\(value)\".")
                    }
                    return size
                }
                let link = try optionalString(span, "link")
                if let link, !RichTextValidation.isValidLink(link) {
                    throw DecodeFailure("AD242", "Rich-text link is invalid or uses an unsupported scheme.")
                }
                return Span(
                    text,
                    styles: Set(decoded),
                    textColor: textColor,
                    textSize: textSize,
                    link: link
                )
            })
        case .number:
            try exactKeys(object, required: ["number"])
            guard let number = object["number"] as? NSNumber,
                  String(cString: number.objCType) != "c",
                  number.doubleValue.isFinite else {
                throw DecodeFailure("AD244", "Number field must contain a finite JSON number.")
            }
            return .number(number.doubleValue)
        case .cloze:
            try exactKeys(object, required: ["cloze"])
            let parsed = try parseCloze(try requiredString(object, "cloze"))
            try validateAuthoredText(parsed.text)
            try ClozeValidation.validate(text: parsed.text, blanks: parsed.blanks)
            return .cloze(parsed.text, blanks: parsed.blanks)
        case .audio, .image, .gif, .video:
            try exactKeys(object, required: ["media"])
            guard let media = object["media"] as? [String: Any] else {
                throw DecodeFailure("AD245", "Media field needs a media object.")
            }
            try exactKeys(media, required: ["path"], optional: ["alt", "durationMs"])
            guard let kind = definition.type.mediaKind else {
                throw DecodeFailure("AD245", "Media field kind is invalid.")
            }
            let path = try requiredString(media, "path")
            let fileURL = try resolveMediaPath(path)
            let descriptor = try describeMedia(fileURL, relativePath: path, kind: kind)
            if mediaByHash[descriptor.hash] == nil {
                let (sum, overflow) = totalMediaBytes.addingReportingOverflow(Int64(descriptor.byteSize))
                guard !overflow, sum <= limits.portable.maximumTotalMediaBytes else {
                    throw DecodeFailure("AD246", "Authored deck media exceeds the total byte limit.")
                }
                totalMediaBytes = sum
                mediaByHash[descriptor.hash] = .init(descriptor: descriptor, fileURL: fileURL)
            }
            let duration = try media["durationMs"].map { try integerValue($0) }
            guard duration == nil || duration! >= 0 else {
                throw DecodeFailure("AD247", "Media durationMs cannot be negative.")
            }
            let alt = try optionalString(media, "alt")
            if let alt { try validateAuthoredText(alt) }
            return .media(MediaRef(
                kind: kind,
                assetHash: descriptor.hash,
                fileExtension: descriptor.fileExtension,
                durationMs: duration,
                altText: alt
            ))
        }
    }

    private func resolveMediaPath(_ path: String) throws -> URL {
        guard path.hasPrefix("media/"),
              !path.hasPrefix("/"),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0 != ".." && $0 != "."
              }) else {
            throw DecodeFailure("AD250", "Media paths must stay beneath media/.")
        }
        try rejectMediaSymlinkComponents(path)
        let candidate = root.appendingPathComponent(path).standardizedFileURL
        let mediaDirectory = root.appendingPathComponent("media", isDirectory: true)
        let mediaValues = try mediaDirectory.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey,
        ])
        guard mediaValues.isDirectory == true, mediaValues.isSymbolicLink != true else {
            throw DecodeFailure("AD251", "The media directory must be a regular directory.")
        }
        let values = try candidate.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw DecodeFailure("AD251", "Media path \"\(path)\" is not a regular file.")
        }
        let resolved = candidate.resolvingSymlinksInPath()
        let mediaRoot = mediaDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard isContained(mediaRoot, in: root), isContained(resolved, in: mediaRoot) else {
            throw DecodeFailure("AD252", "Media path \"\(path)\" escapes media/.")
        }
        return resolved
    }

    private func rejectMediaSymlinkComponents(_ path: String) throws {
        var cursor = root
        for component in path.split(separator: "/") {
            cursor.appendPathComponent(String(component))
            let values = try cursor.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw DecodeFailure("AD251", "Media path \"\(path)\" contains a symlink.")
            }
        }
    }

    private func describeMedia(
        _ url: URL,
        relativePath: String,
        kind: MediaKind
    ) throws -> MediaAssetDescriptor {
        let descriptor = try descriptorForConfinedFile(
            root: root,
            relativePath: relativePath,
            kind: kind
        )
        let fileExtension = url.pathExtension.lowercased()
        let ext = try MediaValidation.validatedExtension(
            data: descriptor.prefix,
            kind: kind,
            fileExtension: fileExtension
        )
        return .init(
            hash: descriptor.hash,
            kind: kind,
            byteSize: descriptor.byteSize,
            fileExtension: ext
        )
    }

    private func failure(
        _ code: String,
        _ message: String,
        at location: SourceLocation
    ) -> LoadedAuthoredDeck {
        .init(package: nil, diagnostics: [diag(code, message, at: location)])
    }
}

private struct DecodeFailure: Error {
    let code: String
    let message: String

    init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    func diagnostic(at location: SourceLocation) -> AuthoredDeckDiagnostic {
        .init(file: location.file, line: location.line, code: code, message: message)
    }
}

private func diag(
    _ code: String,
    _ message: String,
    at location: SourceLocation
) -> AuthoredDeckDiagnostic {
    .init(file: location.file, line: location.line, code: code, message: message)
}

private func decodeDiagnostic(_ error: Error, at location: SourceLocation) -> AuthoredDeckDiagnostic {
    .init(file: location.file, line: location.line, code: "AD099", message: error.localizedDescription)
}

private func exactKeys(
    _ object: [String: Any],
    required: Set<String>,
    optional: Set<String> = []
) throws {
    let keys = Set(object.keys)
    guard keys.isSuperset(of: required), keys.isSubset(of: required.union(optional)) else {
        let unknown = keys.subtracting(required).subtracting(optional).sorted()
        let missing = required.subtracting(keys).sorted()
        if let first = unknown.first {
            throw DecodeFailure("AD020", "Unknown member \"\(first)\".")
        }
        throw DecodeFailure("AD021", "Missing required member \"\(missing.first ?? "?")\".")
    }
}

private func requiredString(_ object: [String: Any], _ key: String) throws -> String {
    guard let value = object[key] as? String else {
        throw DecodeFailure("AD022", "Member \"\(key)\" must be a string.")
    }
    return value
}

private func nonemptyString(_ object: [String: Any], _ key: String) throws -> String {
    let value = try requiredString(object, key)
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          value.utf8.count <= 1_024 else {
        throw DecodeFailure("AD023", "Member \"\(key)\" must be non-empty and at most 1024 bytes.")
    }
    return value
}

private func optionalString(_ object: [String: Any], _ key: String) throws -> String? {
    guard let raw = object[key] else { return nil }
    guard let value = raw as? String else {
        throw DecodeFailure("AD022", "Member \"\(key)\" must be a string.")
    }
    return value
}

private func identifier(_ object: [String: Any], _ key: String) throws -> String {
    let value = try requiredString(object, key)
    guard isIdentifier(value) else {
        throw DecodeFailure(
            "AD024",
            "Member \"\(key)\" must match [A-Za-z][A-Za-z0-9_-]{0,63}."
        )
    }
    return value
}

private func optionalIdentifier(_ object: [String: Any], _ key: String) throws -> String? {
    guard let raw = object[key], !(raw is NSNull) else { return nil }
    guard let value = raw as? String, isIdentifier(value) else {
        throw DecodeFailure(
            "AD024",
            "Member \"\(key)\" must be null or match [A-Za-z][A-Za-z0-9_-]{0,63}."
        )
    }
    return value
}

private func isIdentifier(_ value: String) -> Bool {
    guard let first = value.utf8.first,
          (first >= 65 && first <= 90) || (first >= 97 && first <= 122),
          value.utf8.count <= 64 else { return false }
    return value.utf8.dropFirst().allSatisfy {
        ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
            || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95
    }
}

private func requiredInteger(_ object: [String: Any], _ key: String) throws -> Int {
    guard let raw = object[key] else {
        throw DecodeFailure("AD025", "Missing integer member \"\(key)\".")
    }
    return try integerValue(raw)
}

private func integerValue(_ raw: Any) throws -> Int {
    guard let number = raw as? NSNumber,
          String(cString: number.objCType) != "c",
          number.doubleValue.rounded() == number.doubleValue,
          number.doubleValue >= Double(Int.min),
          number.doubleValue <= Double(Int.max) else {
        throw DecodeFailure("AD026", "Expected an integer.")
    }
    return number.intValue
}

private func optionalBool(_ object: [String: Any], _ key: String) throws -> Bool? {
    guard let raw = object[key] else { return nil }
    guard let number = raw as? NSNumber, String(cString: number.objCType) == "c" else {
        throw DecodeFailure("AD027", "Member \"\(key)\" must be a boolean.")
    }
    return number.boolValue
}

private func requiredObject(_ object: [String: Any], _ key: String) throws -> [String: Any] {
    guard let value = object[key] as? [String: Any] else {
        throw DecodeFailure("AD028", "Member \"\(key)\" must be an object.")
    }
    return value
}

private func objectArray(_ object: [String: Any], _ key: String) throws -> [[String: Any]] {
    guard let values = object[key] as? [Any] else {
        throw DecodeFailure("AD029", "Member \"\(key)\" must be an array.")
    }
    return try values.map {
        guard let value = $0 as? [String: Any] else {
            throw DecodeFailure("AD030", "Every value in \"\(key)\" must be an object.")
        }
        return value
    }
}

private func stringArray(_ object: [String: Any], _ key: String) throws -> [String] {
    guard let values = object[key] as? [Any] else {
        throw DecodeFailure("AD029", "Member \"\(key)\" must be an array.")
    }
    return try values.map {
        guard let value = $0 as? String else {
            throw DecodeFailure("AD031", "Every value in \"\(key)\" must be a string.")
        }
        return value
    }
}

private func optionalStringArray(_ object: [String: Any], _ key: String) throws -> [String]? {
    guard object[key] != nil else { return nil }
    return try stringArray(object, key)
}

private func optionalIdentifierArray(
    _ object: [String: Any],
    _ key: String
) throws -> [String]? {
    guard let values = try optionalStringArray(object, key) else { return nil }
    guard values.allSatisfy(isIdentifier) else {
        throw DecodeFailure(
            "AD024",
            "Every value in \"\(key)\" must match [A-Za-z][A-Za-z0-9_-]{0,63}."
        )
    }
    return values
}

private struct ParsedCloze {
    let text: String
    let blanks: [ClozeSpan]
}

private func parseCloze(_ source: String) throws -> ParsedCloze {
    var output = ""
    var blanks: [ClozeSpan] = []
    var cursor = source.startIndex
    while cursor < source.endIndex {
        guard let open = source[cursor...].range(of: "{{c") else {
            output += source[cursor...]
            break
        }
        output += source[cursor..<open.lowerBound]
        var marker = open.upperBound
        let digitsStart = marker
        while marker < source.endIndex, source[marker].isNumber {
            marker = source.index(after: marker)
        }
        guard marker > digitsStart,
              source[marker...].hasPrefix("::"),
              let group = Int(source[digitsStart..<marker]),
              group > 0 else {
            throw DecodeFailure("AD260", "Malformed cloze marker; expected {{c1::answer}}.")
        }
        marker = source.index(marker, offsetBy: 2)
        guard let close = source[marker...].range(of: "}}") else {
            throw DecodeFailure("AD260", "Unterminated cloze marker.")
        }
        let body = String(source[marker..<close.lowerBound])
        let components = body.components(separatedBy: "::")
        guard components.count == 1 || components.count == 2,
              let answer = components.first, !answer.isEmpty else {
            throw DecodeFailure("AD260", "Cloze marker needs a non-empty answer and optional hint.")
        }
        let start = output.count
        output += answer
        blanks.append(ClozeSpan(
            group: group,
            start: start,
            length: answer.count,
            hint: components.count == 2 ? components[1] : nil
        ))
        cursor = close.upperBound
    }
    return .init(text: output, blanks: blanks)
}

private func conditionNodeCount(_ condition: ConditionRecord) -> Int {
    switch condition {
    case .fieldNotEmpty, .fieldEmpty:
        return 1
    case let .all(children), let .any(children):
        return 1 + children.reduce(0) { $0 + conditionNodeCount($1) }
    }
}

private func validateAuthoredText(_ text: String) throws {
    guard text.utf8.count <= 256 * 1_024 else {
        throw DecodeFailure("AD261", "A text value exceeds the 256 KiB limit.")
    }
}

private struct ConfinedFileDescriptor {
    let hash: String
    let byteSize: Int
    let prefix: Data
}

private func discoverConfinedItemParts(
    root: URL,
    maximumParts: Int
) throws -> Set<String> {
    let rootFD = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard rootFD >= 0 else {
        throw DecodeFailure("AD033", "Could not securely enumerate item parts.")
    }
    let itemsFD = "items".withCString {
        Darwin.openat(rootFD, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    }
    Darwin.close(rootFD)
    if itemsFD < 0 {
        if errno == ENOENT { return [] }
        throw DecodeFailure("AD033", "Could not securely enumerate items/.")
    }

    let (entryLimit, overflow) = maximumParts.addingReportingOverflow(1_024)
    let maximumEntries = overflow ? Int.max : entryLimit
    var visitedEntries = 0
    var result: Set<String> = []

    func walk(_ directoryFD: Int32, prefix: String, depth: Int) throws {
        guard depth <= 64 else {
            Darwin.close(directoryFD)
            throw DecodeFailure("AD033", "Item-part directory nesting is too deep.")
        }
        guard let directory = fdopendir(directoryFD) else {
            Darwin.close(directoryFD)
            throw DecodeFailure("AD033", "Could not securely enumerate item parts.")
        }
        defer { closedir(directory) }
        errno = 0
        while let entry = readdir(directory) {
            if result.count > maximumParts { return }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != "..", !name.hasPrefix(".") else { continue }
            visitedEntries += 1
            guard visitedEntries <= maximumEntries else {
                throw DecodeFailure(
                    "AD033",
                    "items/ contains too many filesystem entries to validate safely."
                )
            }
            var status = stat()
            let statusResult = name.withCString {
                fstatat(dirfd(directory), $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            guard statusResult == 0 else {
                throw DecodeFailure("AD033", "An item-part path changed during validation.")
            }
            let mode = status.st_mode & S_IFMT
            let relative = prefix + name
            if mode == S_IFDIR {
                let childFD = name.withCString {
                    Darwin.openat(
                        dirfd(directory),
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                guard childFD >= 0 else {
                    throw DecodeFailure("AD033", "An item-part directory changed during validation.")
                }
                try walk(childFD, prefix: relative + "/", depth: depth + 1)
            } else if name.lowercased().hasSuffix(".jsonl") {
                result.insert("items/" + relative)
                if result.count > maximumParts { return }
            }
            errno = 0
        }
        guard errno == 0 else {
            throw DecodeFailure("AD033", "Could not finish enumerating item parts.")
        }
    }

    try walk(itemsFD, prefix: "", depth: 0)
    return result
}

private func readConfinedRegularFile(
    root: URL,
    relativePath: String,
    maximumBytes: Int,
    remainingTotalBytes: Int
) throws -> Data {
    let descriptor = try openConfinedRegularFile(root: root, relativePath: relativePath)
    guard descriptor.byteSize <= maximumBytes else {
        Darwin.close(descriptor.fd)
        throw DecodeFailure(
            "AD011",
            "Source exceeds the \(maximumBytes)-byte limit."
        )
    }
    guard descriptor.byteSize <= remainingTotalBytes else {
        Darwin.close(descriptor.fd)
        throw DecodeFailure(
            "AD018",
            "Authored deck source exceeds the configured total byte limit."
        )
    }
    let handle = FileHandle(fileDescriptor: descriptor.fd, closeOnDealloc: true)
    var data = Data()
    data.reserveCapacity(descriptor.byteSize)
    while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
        let (newCount, overflow) = data.count.addingReportingOverflow(chunk.count)
        guard !overflow, newCount <= maximumBytes, newCount <= descriptor.byteSize else {
            throw DecodeFailure("AD011", "Source changed or exceeds its configured byte limit.")
        }
        data.append(chunk)
    }
    guard data.count == descriptor.byteSize else {
        throw DecodeFailure("AD011", "Source changed while it was being read.")
    }
    return data
}

private func descriptorForConfinedFile(
    root: URL,
    relativePath: String,
    kind: MediaKind
) throws -> ConfinedFileDescriptor {
    let opened = try openConfinedRegularFile(root: root, relativePath: relativePath)
    guard opened.byteSize <= MediaValidation.maxBytes(for: kind) else {
        Darwin.close(opened.fd)
        throw DecodeFailure("AD253", "Media file exceeds the \(kind.rawValue) size limit.")
    }
    let handle = FileHandle(fileDescriptor: opened.fd, closeOnDealloc: true)
    var hasher = SHA256()
    var prefix = Data()
    var count = 0
    while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
        let (newCount, overflow) = count.addingReportingOverflow(chunk.count)
        guard !overflow, newCount <= opened.byteSize else {
            throw DecodeFailure("AD254", "Media changed while it was being validated.")
        }
        count = newCount
        if prefix.count < 64 { prefix.append(chunk.prefix(64 - prefix.count)) }
        hasher.update(data: chunk)
    }
    guard count == opened.byteSize else {
        throw DecodeFailure("AD254", "Media changed while it was being validated.")
    }
    return .init(
        hash: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
        byteSize: count,
        prefix: prefix
    )
}

private func copyConfinedFile(
    root: URL,
    relativePath: String,
    destination: URL,
    kind: MediaKind
) throws -> MediaAssetDescriptor {
    let opened = try openConfinedRegularFile(root: root, relativePath: relativePath)
    guard opened.byteSize <= MediaValidation.maxBytes(for: kind) else {
        Darwin.close(opened.fd)
        throw DecodeFailure("AD253", "Media file exceeds the \(kind.rawValue) size limit.")
    }
    let outputFD = Darwin.open(
        destination.path,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
        S_IRUSR | S_IWUSR
    )
    guard outputFD >= 0 else {
        Darwin.close(opened.fd)
        throw DecodeFailure("AD272", "Could not create a secure media staging file.")
    }
    let input = FileHandle(fileDescriptor: opened.fd, closeOnDealloc: true)
    let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
    var hasher = SHA256()
    var prefix = Data()
    var count = 0
    do {
        while let chunk = try input.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            let (newCount, overflow) = count.addingReportingOverflow(chunk.count)
            guard !overflow, newCount <= opened.byteSize else {
                throw DecodeFailure("AD271", "Media changed while it was being staged.")
            }
            count = newCount
            if prefix.count < 64 { prefix.append(chunk.prefix(64 - prefix.count)) }
            hasher.update(data: chunk)
            try output.write(contentsOf: chunk)
        }
        guard count == opened.byteSize else {
            throw DecodeFailure("AD271", "Media changed while it was being staged.")
        }
        try output.synchronize()
    } catch {
        try? FileManager.default.removeItem(at: destination)
        throw error
    }
    let fileExtension = URL(fileURLWithPath: relativePath).pathExtension.lowercased()
    let validatedExtension = try MediaValidation.validatedExtension(
        data: prefix,
        kind: kind,
        fileExtension: fileExtension
    )
    return .init(
        hash: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
        kind: kind,
        byteSize: count,
        fileExtension: validatedExtension
    )
}

private func openConfinedRegularFile(
    root: URL,
    relativePath: String
) throws -> (fd: Int32, byteSize: Int) {
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.isEmpty,
          components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
        throw DecodeFailure("AD010", "Path must be a canonical relative path.")
    }
    var currentFD = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard currentFD >= 0 else {
        throw DecodeFailure("AD010", "Could not securely open the authored bundle.")
    }
    for (index, component) in components.enumerated() {
        let isLast = index == components.count - 1
        let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | (isLast ? 0 : O_DIRECTORY)
        let nextFD = String(component).withCString {
            Darwin.openat(currentFD, $0, flags)
        }
        Darwin.close(currentFD)
        guard nextFD >= 0 else {
            throw DecodeFailure("AD010", "Path contains a symlink or unreadable component.")
        }
        currentFD = nextFD
    }
    var status = stat()
    guard fstat(currentFD, &status) == 0,
          (status.st_mode & S_IFMT) == S_IFREG,
          status.st_size >= 0,
          status.st_size <= off_t(Int.max) else {
        Darwin.close(currentFD)
        throw DecodeFailure("AD010", "Source must be a regular file.")
    }
    return (currentFD, Int(status.st_size))
}

private struct JSONDuplicateKeyDetector {
    private let bytes: [UInt8]
    private var index = 0
    private var duplicate: String?

    static func firstDuplicate(in data: Data) -> String? {
        var detector = JSONDuplicateKeyDetector(bytes: Array(data))
        try? detector.parseValue(depth: 0)
        return detector.duplicate
    }

    private init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    private mutating func parseValue(depth: Int) throws {
        guard depth <= 128 else { throw ScanError.malformed }
        skipWhitespace()
        guard index < bytes.count else { throw ScanError.malformed }
        switch bytes[index] {
        case 0x7B:
            try parseObject(depth: depth + 1)
        case 0x5B:
            try parseArray(depth: depth + 1)
        case 0x22:
            _ = try parseString()
        default:
            parsePrimitive()
        }
    }

    private mutating func parseObject(depth: Int) throws {
        index += 1
        skipWhitespace()
        if consume(0x7D) { return }
        var keys: Set<String> = []
        while true {
            skipWhitespace()
            let key = try parseString()
            if !keys.insert(key).inserted, duplicate == nil {
                duplicate = key
            }
            skipWhitespace()
            guard consume(0x3A) else { throw ScanError.malformed }
            try parseValue(depth: depth)
            skipWhitespace()
            if consume(0x7D) { return }
            guard consume(0x2C) else { throw ScanError.malformed }
        }
    }

    private mutating func parseArray(depth: Int) throws {
        index += 1
        skipWhitespace()
        if consume(0x5D) { return }
        while true {
            try parseValue(depth: depth)
            skipWhitespace()
            if consume(0x5D) { return }
            guard consume(0x2C) else { throw ScanError.malformed }
        }
    }

    private mutating func parseString() throws -> String {
        guard index < bytes.count, bytes[index] == 0x22 else {
            throw ScanError.malformed
        }
        let start = index
        index += 1
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                index += 1
                let encoded = Data(bytes[start..<index])
                let wrapped = Data([0x5B]) + encoded + Data([0x5D])
                guard let values = try JSONSerialization.jsonObject(with: wrapped) as? [String],
                      let value = values.first else {
                    throw ScanError.malformed
                }
                return value
            }
            if byte == 0x5C {
                index += 1
                guard index < bytes.count else { throw ScanError.malformed }
                if bytes[index] == 0x75 {
                    guard index + 4 < bytes.count else { throw ScanError.malformed }
                    index += 4
                }
            } else if byte < 0x20 {
                throw ScanError.malformed
            }
            index += 1
        }
        throw ScanError.malformed
    }

    private mutating func parsePrimitive() {
        while index < bytes.count,
              ![0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x5D, 0x7D].contains(bytes[index]) {
            index += 1
        }
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
            index += 1
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private enum ScanError: Error {
        case malformed
    }
}

private func isContained(_ child: URL, in root: URL) -> Bool {
    let childComponents = child.standardizedFileURL.pathComponents
    let rootComponents = root.standardizedFileURL.pathComponents
    return childComponents.count > rootComponents.count
        && childComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
}
