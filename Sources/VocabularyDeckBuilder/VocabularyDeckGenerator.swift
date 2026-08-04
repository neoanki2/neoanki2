import Foundation
import NeoAnkiCore
import NeoAnkiDeckBuilderKit

public enum VocabularyCardParadigm: String, CaseIterable, Sendable, Hashable, Identifiable {
    case formToPronunciation
    case formToMeaning
    case meaningToForm
    case exampleClozeToForm

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .formToPronunciation: "Form → Pronunciation"
        case .formToMeaning: "Form → Meaning"
        case .meaningToForm: "Meaning → Form"
        case .exampleClozeToForm: "Example Cloze → Form"
        }
    }
}

public enum VocabularyPronunciationContent: Sendable, Equatable {
    case text(String)
    case audio(URL)
}

public struct VocabularyProvenanceSelection: Codable, Sendable, Equatable {
    public var sourceID: String
    public var sourceName: String?
    public var recordID: String?
    public var attribution: String?
    public var license: String?
    public var sourceURL: String?

    public init(
        sourceID: String,
        sourceName: String? = nil,
        recordID: String? = nil,
        attribution: String? = nil,
        license: String? = nil,
        sourceURL: String? = nil
    ) {
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.recordID = recordID
        self.attribution = attribution
        self.license = license
        self.sourceURL = sourceURL
    }
}

public struct VocabularySourceContext: Codable, Sendable, Equatable {
    public var packID: String
    public var entryID: String
    public var pack: VocabularyProvenanceSelection?
    public var entry: VocabularyProvenanceSelection?

    public init(
        packID: String = "",
        entryID: String = "",
        pack: VocabularyProvenanceSelection? = nil,
        entry: VocabularyProvenanceSelection? = nil
    ) {
        self.packID = packID
        self.entryID = entryID
        self.pack = pack
        self.entry = entry
    }
}

public struct VocabularyPronunciationSelection: Identifiable, Sendable, Equatable {
    public var id: String
    public var scheme: String
    public var displayLabel: String
    public var content: VocabularyPronunciationContent
    public var language: String?
    public var formIDs: Set<String>
    public var senseIDs: Set<String>
    public var provenance: VocabularyProvenanceSelection?
    public var availabilityError: String?
    public var isSelected: Bool

    public init(
        id: String,
        scheme: String,
        displayLabel: String,
        content: VocabularyPronunciationContent,
        language: String? = nil,
        formIDs: Set<String> = [],
        senseIDs: Set<String> = [],
        provenance: VocabularyProvenanceSelection? = nil,
        availabilityError: String? = nil,
        isSelected: Bool = true
    ) {
        self.id = id
        self.scheme = scheme
        self.displayLabel = displayLabel
        self.content = content
        self.language = language
        self.formIDs = formIDs
        self.senseIDs = senseIDs
        self.provenance = provenance
        self.availabilityError = availabilityError
        self.isSelected = isSelected
    }
}

public struct VocabularyExampleSelection: Identifiable, Sendable, Equatable {
    public var id: String
    public var sourceID: String?
    public var text: String
    /// Extended-grapheme-cluster offset of the actual surface form in `text`.
    public var targetStart: Int
    /// Extended-grapheme-cluster length of the actual surface form in `text`.
    public var targetLength: Int
    /// The selected surface form. When nonempty, generation verifies it against the range.
    public var targetText: String
    public var provenance: VocabularyProvenanceSelection?
    public var isSelected: Bool

    public init(
        id: String,
        sourceID: String? = nil,
        text: String,
        targetStart: Int,
        targetLength: Int,
        targetText: String = "",
        provenance: VocabularyProvenanceSelection? = nil,
        isSelected: Bool = true
    ) {
        self.id = id
        self.sourceID = sourceID
        self.text = text
        self.targetStart = targetStart
        self.targetLength = targetLength
        self.targetText = targetText
        self.provenance = provenance
        self.isSelected = isSelected
    }
}

public struct VocabularySenseSelection: Identifiable, Sendable, Equatable {
    public var id: String
    public var definition: String
    public var definitionLanguage: String?
    public var definitionIDs: [String]
    public var definitionProvenances: [VocabularyProvenanceSelection]
    public var provenance: VocabularyProvenanceSelection?
    public var examples: [VocabularyExampleSelection]
    public var isSelected: Bool

    public init(
        id: String,
        definition: String,
        definitionLanguage: String? = nil,
        definitionIDs: [String] = [],
        definitionProvenances: [VocabularyProvenanceSelection] = [],
        provenance: VocabularyProvenanceSelection? = nil,
        examples: [VocabularyExampleSelection] = [],
        isSelected: Bool = true
    ) {
        self.id = id
        self.definition = definition
        self.definitionLanguage = definitionLanguage
        self.definitionIDs = definitionIDs
        self.definitionProvenances = definitionProvenances
        self.provenance = provenance
        self.examples = examples
        self.isSelected = isSelected
    }
}

public struct VocabularyDeckInput: Sendable, Equatable {
    public var destinationDeckID: UUID?
    public var deckName: String
    public var language: String?
    public var formID: String?
    public var form: String
    public var pronunciations: [VocabularyPronunciationSelection]
    public var senses: [VocabularySenseSelection]
    public var paradigms: Set<VocabularyCardParadigm>
    public var sourceLabel: String
    public var sourceContext: VocabularySourceContext

    public init(
        destinationDeckID: UUID? = nil,
        deckName: String = "Vocabulary",
        language: String? = nil,
        formID: String? = nil,
        form: String = "",
        pronunciations: [VocabularyPronunciationSelection] = [],
        senses: [VocabularySenseSelection] = [],
        paradigms: Set<VocabularyCardParadigm> = Set(VocabularyCardParadigm.allCases),
        sourceLabel: String = "",
        sourceContext: VocabularySourceContext = .init()
    ) {
        self.destinationDeckID = destinationDeckID
        self.deckName = deckName
        self.language = language
        self.formID = formID
        self.form = form
        self.pronunciations = pronunciations
        self.senses = senses
        self.paradigms = paradigms
        self.sourceLabel = sourceLabel
        self.sourceContext = sourceContext
    }
}

public struct VocabularyDeckBuilderLimits: Sendable, Equatable {
    public var maximumCards: Int
    public var maximumTextFieldBytes: Int
    public var maximumSourceMetadataBytes: Int
    public var maximumAudioBytes: Int64

    public init(
        maximumCards: Int = 500,
        maximumTextFieldBytes: Int = 256_000,
        maximumSourceMetadataBytes: Int = 256_000,
        maximumAudioBytes: Int64 = 20_000_000
    ) {
        self.maximumCards = maximumCards
        self.maximumTextFieldBytes = maximumTextFieldBytes
        self.maximumSourceMetadataBytes = maximumSourceMetadataBytes
        self.maximumAudioBytes = maximumAudioBytes
    }

    public static let `default` = VocabularyDeckBuilderLimits()
}

public struct VocabularyCardPreview: Identifiable, Sendable, Equatable {
    public let id: String
    public let paradigm: VocabularyCardParadigm
    public let prompt: String
    public let answer: String

    public init(id: String, paradigm: VocabularyCardParadigm, prompt: String, answer: String) {
        self.id = id
        self.paradigm = paradigm
        self.prompt = prompt
        self.answer = answer
    }
}

public enum VocabularyDeckBuilderError: Error, Sendable, Equatable, LocalizedError {
    case missingDestinationDeck
    case missingDeckName
    case missingForm
    case noParadigms
    case noCards
    case emptyDefinition(String)
    case invalidExample(String)
    case nonLocalAudio(String)
    case unsupportedAudio(String)
    case incompatiblePronunciation(String)
    case tooManyCards(actual: Int, maximum: Int)
    case fieldTooLarge(String, maximumBytes: Int)
    case sourceMetadataTooLarge(maximumBytes: Int)
    case invalidAudio(String)
    case invalidGeneratedDeck([AuthoredDeckDiagnostic])

    public var errorDescription: String? {
        switch self {
        case .missingDestinationDeck: "Choose a root deck."
        case .missingDeckName: "Enter a deck name."
        case .missingForm: "Choose an entry with a nonempty form."
        case .noParadigms: "Enable at least one card paradigm."
        case .noCards: "The selected entry and paradigms do not produce any cards."
        case let .emptyDefinition(id): "The selected sense \(id) needs a definition."
        case let .invalidExample(id): "Example \(id) does not contain a valid selected target."
        case let .nonLocalAudio(id): "Pronunciation \(id) must reference a local audio file."
        case let .unsupportedAudio(message): message
        case let .incompatiblePronunciation(id):
            "Pronunciation \(id) does not apply to every selected meaning and the selected form."
        case let .tooManyCards(actual, maximum):
            "The selection would create \(actual) cards; reduce it to \(maximum) or fewer."
        case let .fieldTooLarge(name, maximumBytes):
            "\(name) is too large. Keep it below \(maximumBytes) UTF-8 bytes."
        case let .sourceMetadataTooLarge(maximumBytes):
            "Source metadata is too large. Keep it below \(maximumBytes) UTF-8 bytes."
        case let .invalidAudio(message): message
        case let .invalidGeneratedDeck(diagnostics):
            diagnostics.first?.localizedDescription ?? "The generated deck is invalid."
        }
    }
}

public enum VocabularyDeckGenerator {
    public static func preview(
        input: VocabularyDeckInput,
        builderLimits: VocabularyDeckBuilderLimits = .default
    ) throws -> [VocabularyCardPreview] {
        let normalized = try normalizedInput(input, requireDestination: false, limits: builderLimits)
        var cards: [VocabularyCardPreview] = []

        if normalized.paradigms.contains(.formToPronunciation) {
            for pronunciation in normalized.pronunciations where pronunciation.isSelected {
                let answer: String
                switch pronunciation.content {
                case let .text(text): answer = text
                case let .audio(url): answer = "Audio: \(url.lastPathComponent)"
                }
                cards.append(.init(
                    id: "pronunciation-\(pronunciation.id)",
                    paradigm: .formToPronunciation,
                    prompt: normalized.form,
                    answer: answer
                ))
            }
        }

        for sense in normalized.senses where sense.isSelected {
            if normalized.paradigms.contains(.formToMeaning) {
                cards.append(.init(
                    id: "form-meaning-\(sense.id)",
                    paradigm: .formToMeaning,
                    prompt: normalized.form,
                    answer: sense.definition
                ))
            }
            if normalized.paradigms.contains(.meaningToForm) {
                cards.append(.init(
                    id: "meaning-form-\(sense.id)",
                    paradigm: .meaningToForm,
                    prompt: sense.definition,
                    answer: normalized.form
                ))
            }
            if normalized.paradigms.contains(.exampleClozeToForm) {
                for example in sense.examples where example.isSelected {
                    let target = try selectedTarget(in: example)
                    cards.append(.init(
                        id: "example-\(sense.id)-\(example.id)",
                        paradigm: .exampleClozeToForm,
                        prompt: maskingTarget(in: example.text, start: example.targetStart, length: example.targetLength),
                        answer: target
                    ))
                }
            }
        }

        guard !cards.isEmpty else { throw VocabularyDeckBuilderError.noCards }
        return cards
    }

    public static func generate(
        input: VocabularyDeckInput,
        workspaceProvider: any DeckBuildWorkspaceProviding = SystemDeckBuildWorkspaceProvider(),
        limits: AuthoredDeckLimits = .default,
        builderLimits: VocabularyDeckBuilderLimits = .default
    ) throws -> GeneratedDeckBundle {
        let input = try normalizedInput(input, requireDestination: true, limits: builderLimits)
        _ = try preview(input: input, builderLimits: builderLimits)
        guard let destinationDeckID = input.destinationDeckID else {
            throw VocabularyDeckBuilderError.missingDestinationDeck
        }

        let workspace = try workspaceProvider.makeWorkspace()
        do {
            try writeBundle(input: input, at: workspace.bundleURL)
            let diagnostics = AuthoredDeck.validate(at: workspace.bundleURL, limits: limits)
            guard diagnostics.isEmpty else {
                throw VocabularyDeckBuilderError.invalidGeneratedDeck(diagnostics)
            }
            return workspace.placed(under: destinationDeckID)
        } catch {
            workspace.cleanup()
            throw error
        }
    }

    public static func clozeMarkup(for example: VocabularyExampleSelection) throws -> String {
        let target = try selectedTarget(in: example)
        guard !target.contains("::"), !target.contains("}}"), !example.text.contains("{{c") else {
            throw VocabularyDeckBuilderError.invalidExample(example.id)
        }
        let characters = Array(example.text)
        let prefix = String(characters[..<example.targetStart])
        let suffix = String(characters[(example.targetStart + example.targetLength)...])
        return "\(prefix){{c1::\(target)}}\(suffix)"
    }

    private static func normalizedInput(
        _ input: VocabularyDeckInput,
        requireDestination: Bool,
        limits: VocabularyDeckBuilderLimits
    ) throws -> VocabularyDeckInput {
        var input = input
        input.deckName = input.deckName.trimmingCharacters(in: .whitespacesAndNewlines)
        input.form = input.form.trimmingCharacters(in: .whitespacesAndNewlines)
        input.sourceLabel = input.sourceLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        input.language = input.language?.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.language?.isEmpty == true { input.language = nil }

        if requireDestination, input.destinationDeckID == nil {
            throw VocabularyDeckBuilderError.missingDestinationDeck
        }
        guard !input.deckName.isEmpty else { throw VocabularyDeckBuilderError.missingDeckName }
        guard !input.form.isEmpty else { throw VocabularyDeckBuilderError.missingForm }
        guard !input.paradigms.isEmpty else { throw VocabularyDeckBuilderError.noParadigms }
        try validateSizeAndCardLimits(input, limits: limits)

        if input.paradigms.contains(.formToPronunciation) {
            let selectedSenseIDs = Set(input.senses.filter(\.isSelected).map(\.id))
            for pronunciation in input.pronunciations where pronunciation.isSelected {
                if let availabilityError = pronunciation.availabilityError {
                    throw VocabularyDeckBuilderError.unsupportedAudio(availabilityError)
                }
                let formIsCompatible = pronunciation.formIDs.isEmpty
                    || input.formID.map(pronunciation.formIDs.contains) == true
                let sensesAreCompatible = pronunciation.senseIDs.isEmpty
                    || (!selectedSenseIDs.isEmpty && selectedSenseIDs.isSubset(of: pronunciation.senseIDs))
                guard formIsCompatible, sensesAreCompatible else {
                    throw VocabularyDeckBuilderError.incompatiblePronunciation(pronunciation.id)
                }
            }
        }

        for index in input.senses.indices where input.senses[index].isSelected {
            input.senses[index].definition = input.senses[index].definition
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if input.paradigms.contains(.formToMeaning) || input.paradigms.contains(.meaningToForm) {
                guard !input.senses[index].definition.isEmpty else {
                    throw VocabularyDeckBuilderError.emptyDefinition(input.senses[index].id)
                }
            }
            if input.paradigms.contains(.exampleClozeToForm) {
                for example in input.senses[index].examples where example.isSelected {
                    _ = try selectedTarget(in: example)
                }
            }
        }
        return input
    }

    private static func validateSizeAndCardLimits(
        _ input: VocabularyDeckInput,
        limits: VocabularyDeckBuilderLimits
    ) throws {
        func validateField(_ value: String, name: String) throws {
            guard value.utf8.count <= limits.maximumTextFieldBytes else {
                throw VocabularyDeckBuilderError.fieldTooLarge(name, maximumBytes: limits.maximumTextFieldBytes)
            }
        }
        try validateField(input.deckName, name: "Deck name")
        try validateField(input.form, name: "Canonical form")
        try validateField(input.sourceLabel, name: "Source label")

        var cardCount = 0
        var metadataBytes = 0
        func addMetadata(_ value: String?) throws {
            guard let value else { return }
            let (sum, overflow) = metadataBytes.addingReportingOverflow(value.utf8.count)
            guard !overflow, sum <= limits.maximumSourceMetadataBytes else {
                throw VocabularyDeckBuilderError.sourceMetadataTooLarge(
                    maximumBytes: limits.maximumSourceMetadataBytes
                )
            }
            metadataBytes = sum
        }
        func addCard() throws {
            let (sum, overflow) = cardCount.addingReportingOverflow(1)
            guard !overflow, sum <= limits.maximumCards else {
                throw VocabularyDeckBuilderError.tooManyCards(
                    actual: overflow ? Int.max : sum,
                    maximum: limits.maximumCards
                )
            }
            cardCount = sum
        }

        try addMetadata(input.sourceContext.packID)
        try addMetadata(input.sourceContext.entryID)
        try addProvenanceMetadata(input.sourceContext.pack, add: addMetadata)
        try addProvenanceMetadata(input.sourceContext.entry, add: addMetadata)

        if input.paradigms.contains(.formToPronunciation) {
            for pronunciation in input.pronunciations where pronunciation.isSelected {
                try validateField(pronunciation.scheme, name: "Pronunciation scheme")
                try validateField(pronunciation.displayLabel, name: "Pronunciation label")
                switch pronunciation.content {
                case let .text(value):
                    try validateField(value, name: "Pronunciation")
                case let .audio(url):
                    try validateAudio(url, id: pronunciation.id, limits: limits)
                }
                try addProvenanceMetadata(pronunciation.provenance, add: addMetadata)
                try addCard()
            }
        }

        for sense in input.senses where sense.isSelected {
            try addMetadata(sense.id)
            for id in sense.definitionIDs { try addMetadata(id) }
            for provenance in sense.definitionProvenances {
                try addProvenanceMetadata(provenance, add: addMetadata)
            }
            try addProvenanceMetadata(sense.provenance, add: addMetadata)
            if input.paradigms.contains(.formToMeaning) || input.paradigms.contains(.meaningToForm) {
                try validateField(sense.definition, name: "Definition")
            }
            if input.paradigms.contains(.formToMeaning) {
                try addCard()
            }
            if input.paradigms.contains(.meaningToForm) { try addCard() }
            if input.paradigms.contains(.exampleClozeToForm) {
                for example in sense.examples where example.isSelected {
                    try validateField(example.text, name: "Example")
                    try validateField(example.targetText, name: "Cloze target")
                    try addMetadata(example.sourceID)
                    try addProvenanceMetadata(example.provenance, add: addMetadata)
                    try addCard()
                }
            }
        }
    }

    private static func addProvenanceMetadata(
        _ provenance: VocabularyProvenanceSelection?,
        add: (String?) throws -> Void
    ) throws {
        guard let provenance else { return }
        try add(provenance.sourceID)
        try add(provenance.sourceName)
        try add(provenance.recordID)
        try add(provenance.attribution)
        try add(provenance.license)
        try add(provenance.sourceURL)
    }

    private static func validateAudio(
        _ url: URL,
        id: String,
        limits: VocabularyDeckBuilderLimits
    ) throws {
        guard url.isFileURL else { throw VocabularyDeckBuilderError.nonLocalAudio(id) }
        let supportedExtensions: Set<String> = ["m4a", "mp3", "wav", "aac", "caf"]
        guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
            throw VocabularyDeckBuilderError.unsupportedAudio(
                "Pronunciation \(id) uses an unsupported local audio format."
            )
        }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        } catch {
            throw VocabularyDeckBuilderError.invalidAudio(
                "Pronunciation \(id) cannot be read as a local audio file."
            )
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw VocabularyDeckBuilderError.invalidAudio(
                "Pronunciation \(id) must be a non-symbolic-link regular file."
            )
        }
        guard let size = values.fileSize, Int64(size) <= limits.maximumAudioBytes else {
            throw VocabularyDeckBuilderError.invalidAudio(
                "Pronunciation \(id) exceeds the \(limits.maximumAudioBytes)-byte audio limit."
            )
        }
    }

    private static func selectedTarget(in example: VocabularyExampleSelection) throws -> String {
        guard example.targetStart >= 0, example.targetLength > 0 else {
            throw VocabularyDeckBuilderError.invalidExample(example.id)
        }
        let characters = Array(example.text)
        let end = example.targetStart + example.targetLength
        guard example.targetStart < characters.count, end <= characters.count else {
            throw VocabularyDeckBuilderError.invalidExample(example.id)
        }
        let selected = String(characters[example.targetStart ..< end])
        guard example.targetText.isEmpty || selected == example.targetText else {
            throw VocabularyDeckBuilderError.invalidExample(example.id)
        }
        return selected
    }

    private static func maskingTarget(in text: String, start: Int, length: Int) -> String {
        let characters = Array(text)
        guard start >= 0, length > 0, start + length <= characters.count else { return text }
        return String(characters[..<start]) + "…" + String(characters[(start + length)...])
    }

    private static func writeBundle(input: VocabularyDeckInput, at bundleURL: URL) throws {
        let itemsDirectory = bundleURL.appendingPathComponent("items", isDirectory: true)
        let mediaDirectory = bundleURL.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(
            at: itemsDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        let selectedTextPronunciations = input.pronunciations.filter { pronunciation in
            guard pronunciation.isSelected else { return false }
            if case .text = pronunciation.content { return true }
            return false
        }
        let selectedAudioPronunciations = input.pronunciations.filter { pronunciation in
            guard pronunciation.isSelected else { return false }
            if case .audio = pronunciation.content { return true }
            return false
        }
        let selectedSenses = input.senses.filter(\.isSelected)
        let selectedExamples = selectedSenses.flatMap { sense in
            sense.examples.filter(\.isSelected).map { (sense, $0) }
        }

        var types: [TypeRecord] = []
        var typeIDs: [String] = []
        if input.paradigms.contains(.formToPronunciation), !selectedTextPronunciations.isEmpty {
            types.append(textPronunciationType)
            typeIDs.append(textPronunciationType.id)
        }
        if input.paradigms.contains(.formToPronunciation), !selectedAudioPronunciations.isEmpty {
            types.append(audioPronunciationType)
            typeIDs.append(audioPronunciationType.id)
        }
        if !selectedSenses.isEmpty,
           input.paradigms.contains(.formToMeaning) || input.paradigms.contains(.meaningToForm) {
            let type = meaningType(paradigms: input.paradigms)
            types.append(type)
            typeIDs.append(type.id)
        }
        if input.paradigms.contains(.exampleClozeToForm), !selectedExamples.isEmpty {
            types.append(exampleType)
            typeIDs.append(exampleType.id)
        }

        var manifestData = Data()
        try append(
            ManifestRecord(kind: "neoanki", version: 3, root: "vocabulary", parts: ["items/vocabulary.jsonl"]),
            to: &manifestData
        )
        for type in types { try append(type, to: &manifestData) }
        try append(
            DeckRecord(
                kind: "deck",
                id: "vocabulary",
                name: input.deckName,
                parent: nil,
                itemTypes: typeIDs,
                defaultType: typeIDs.count == 1 ? typeIDs[0] : nil
            ),
            to: &manifestData
        )
        try manifestData.write(
            to: bundleURL.appendingPathComponent(AuthoredDeck.manifestName),
            options: .atomic
        )

        var itemData = Data()
        if input.paradigms.contains(.formToPronunciation) {
            for pronunciation in selectedTextPronunciations {
                guard case let .text(value) = pronunciation.content else { continue }
                try append(
                    ItemRecord(
                        kind: "item",
                        deck: "vocabulary",
                        type: textPronunciationType.id,
                        fields: [
                            "form": .text(input.form, lang: input.language),
                            "pronunciation": .text(value, lang: pronunciation.language),
                            "scheme": .text(pronunciation.scheme, lang: nil),
                            "label": .text(pronunciation.displayLabel, lang: nil),
                            "source": .text(input.sourceLabel, lang: nil),
                        ].merging(
                            try provenanceFields(input: input, pronunciation: pronunciation)
                        ) { current, _ in current },
                        tags: sourceTags(input: input)
                    ),
                    to: &itemData
                )
            }

            if !selectedAudioPronunciations.isEmpty {
                try FileManager.default.createDirectory(
                    at: mediaDirectory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            for (index, pronunciation) in selectedAudioPronunciations.enumerated() {
                guard case let .audio(sourceURL) = pronunciation.content else { continue }
                guard sourceURL.isFileURL else {
                    throw VocabularyDeckBuilderError.nonLocalAudio(pronunciation.id)
                }
                let extensionValue = sourceURL.pathExtension.lowercased()
                let filename = "pronunciation-\(index + 1).\(extensionValue)"
                let destinationURL = mediaDirectory.appendingPathComponent(filename)
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                try append(
                    ItemRecord(
                        kind: "item",
                        deck: "vocabulary",
                        type: audioPronunciationType.id,
                        fields: [
                            "form": .text(input.form, lang: input.language),
                            "pronunciation": .media(path: "media/\(filename)", alt: pronunciation.displayLabel),
                            "scheme": .text(pronunciation.scheme, lang: nil),
                            "label": .text(pronunciation.displayLabel, lang: nil),
                            "source": .text(input.sourceLabel, lang: nil),
                        ].merging(
                            try provenanceFields(input: input, pronunciation: pronunciation)
                        ) { current, _ in current },
                        tags: sourceTags(input: input)
                    ),
                    to: &itemData
                )
            }
        }

        if input.paradigms.contains(.formToMeaning) || input.paradigms.contains(.meaningToForm) {
            for sense in selectedSenses {
                try append(
                    ItemRecord(
                        kind: "item",
                        deck: "vocabulary",
                        type: meaningTypeID,
                        fields: [
                            "form": .text(input.form, lang: input.language),
                            "meaning": .text(sense.definition, lang: sense.definitionLanguage),
                            "source": .text(input.sourceLabel, lang: nil),
                        ].merging(try provenanceFields(input: input, sense: sense)) { current, _ in current },
                        tags: sourceTags(input: input, sense: sense)
                    ),
                    to: &itemData
                )
            }
        }

        if input.paradigms.contains(.exampleClozeToForm) {
            for (sense, example) in selectedExamples {
                try append(
                    ItemRecord(
                        kind: "item",
                        deck: "vocabulary",
                        type: exampleType.id,
                        fields: [
                            "sentence": .cloze(try clozeMarkup(for: example)),
                            "form": .text(input.form, lang: input.language),
                            "source": .text(input.sourceLabel, lang: nil),
                        ].merging(
                            try provenanceFields(input: input, sense: sense, example: example)
                        ) { current, _ in current },
                        tags: sourceTags(input: input, sense: sense, example: example)
                    ),
                    to: &itemData
                )
            }
        }
        try itemData.write(
            to: itemsDirectory.appendingPathComponent("vocabulary.jsonl"),
            options: .atomic
        )
    }

    private static func provenanceFields(
        input: VocabularyDeckInput,
        pronunciation: VocabularyPronunciationSelection? = nil,
        sense: VocabularySenseSelection? = nil,
        example: VocabularyExampleSelection? = nil
    ) throws -> [String: AuthoredValue] {
        let envelope = GeneratedProvenanceEnvelope(
            packID: input.sourceContext.packID,
            entryID: input.sourceContext.entryID,
            senseID: sense?.id,
            definitionIDs: sense?.definitionIDs ?? [],
            exampleID: example?.sourceID,
            pack: input.sourceContext.pack,
            entry: input.sourceContext.entry,
            pronunciation: pronunciation?.provenance,
            sense: sense?.provenance,
            definitions: sense?.definitionProvenances ?? [],
            example: example?.provenance
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(envelope)
        guard let json = String(data: data, encoding: .utf8) else {
            throw VocabularyDeckBuilderError.invalidGeneratedDeck([])
        }
        return [
            "pack_id": .text(input.sourceContext.packID, lang: nil),
            "entry_id": .text(input.sourceContext.entryID, lang: nil),
            "sense_id": .text(sense?.id ?? "", lang: nil),
            "example_id": .text(example?.sourceID ?? "", lang: nil),
            "provenance": .text(json, lang: nil),
        ]
    }

    private static func sourceTags(
        input: VocabularyDeckInput,
        sense: VocabularySenseSelection? = nil,
        example: VocabularyExampleSelection? = nil
    ) -> [String] {
        [
            input.sourceLabel.isEmpty ? nil : "source:\(input.sourceLabel)",
            input.sourceContext.packID.isEmpty ? nil : "pack-id:\(input.sourceContext.packID)",
            input.sourceContext.entryID.isEmpty ? nil : "entry-id:\(input.sourceContext.entryID)",
            sense.map { "sense-id:\($0.id)" },
            example.flatMap(\.sourceID).map { "example-id:\($0)" },
        ].compactMap { $0 }
    }

    private static func append<Value: Encodable>(_ value: Value, to data: inout Data) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        data.append(try encoder.encode(value))
        data.append(0x0A)
    }

    private static let meaningTypeID = "vocabulary-meaning"

    private static let textPronunciationType = TypeRecord(
        kind: "type",
        id: "vocabulary-pronunciation-text",
        name: "Vocabulary Pronunciation (Text)",
        fields: commonPronunciationFields(responseType: "text"),
        templates: [textPronunciationTemplate]
    )

    private static let audioPronunciationType = TypeRecord(
        kind: "type",
        id: "vocabulary-pronunciation-audio",
        name: "Vocabulary Pronunciation (Audio)",
        fields: commonPronunciationFields(responseType: "audio"),
        templates: [audioPronunciationTemplate]
    )

    private static func commonPronunciationFields(responseType: String) -> [FieldRecord] {
        [
            .init(id: "form", name: "Form", type: "text", required: true),
            .init(id: "pronunciation", name: "Pronunciation", type: responseType, required: true),
            .init(id: "scheme", name: "Representation", type: "text", required: false),
            .init(id: "label", name: "Pronunciation Label", type: "text", required: false),
            .init(id: "source", name: "Source", type: "text", required: false),
            .init(id: "pack_id", name: "Pack ID", type: "text", required: false),
            .init(id: "entry_id", name: "Entry ID", type: "text", required: false),
            .init(id: "sense_id", name: "Sense ID", type: "text", required: false),
            .init(id: "example_id", name: "Example ID", type: "text", required: false),
            .init(id: "provenance", name: "Provenance", type: "text", required: false),
        ]
    }

    private static let textPronunciationTemplate = TemplateRecord(
        name: "Form to Pronunciation",
        prompt: [.init(field: "form")],
        answer: [.init(field: "pronunciation"), .init(field: "label")],
        interaction: "reveal",
        skill: .init(input: "text", output: "text", operation: "recall")
    )

    private static let audioPronunciationTemplate = TemplateRecord(
        name: "Form to Pronunciation",
        prompt: [.init(field: "form")],
        answer: [.init(field: "pronunciation"), .init(field: "label")],
        interaction: "reveal",
        skill: .init(input: "text", output: "audio", operation: "recall")
    )

    private static func meaningType(paradigms: Set<VocabularyCardParadigm>) -> TypeRecord {
        var templates: [TemplateRecord] = []
        if paradigms.contains(.formToMeaning) {
            templates.append(.init(
                name: "Form to Meaning",
                prompt: [.init(field: "form")],
                answer: [.init(field: "meaning")],
                interaction: "reveal",
                skill: .init(input: "text", output: "text", operation: "recognize")
            ))
        }
        if paradigms.contains(.meaningToForm) {
            templates.append(.init(
                name: "Meaning to Form",
                prompt: [.init(field: "meaning")],
                answer: [.init(field: "form")],
                interaction: "type",
                skill: .init(input: "text", output: "text", operation: "recall")
            ))
        }
        return TypeRecord(
            kind: "type",
            id: meaningTypeID,
            name: "Vocabulary Meaning",
            fields: [
                .init(id: "form", name: "Form", type: "text", required: true),
                .init(id: "meaning", name: "Meaning", type: "text", required: true),
                .init(id: "source", name: "Source", type: "text", required: false),
                .init(id: "pack_id", name: "Pack ID", type: "text", required: false),
                .init(id: "entry_id", name: "Entry ID", type: "text", required: false),
                .init(id: "sense_id", name: "Sense ID", type: "text", required: false),
                .init(id: "example_id", name: "Example ID", type: "text", required: false),
                .init(id: "provenance", name: "Provenance", type: "text", required: false),
            ],
            templates: templates
        )
    }

    private static let exampleType = TypeRecord(
        kind: "type",
        id: "vocabulary-example",
        name: "Vocabulary Example",
        fields: [
            .init(id: "sentence", name: "Sentence", type: "cloze", required: true),
            .init(id: "form", name: "Canonical Form", type: "text", required: true),
            .init(id: "source", name: "Source", type: "text", required: false),
            .init(id: "pack_id", name: "Pack ID", type: "text", required: false),
            .init(id: "entry_id", name: "Entry ID", type: "text", required: false),
            .init(id: "sense_id", name: "Sense ID", type: "text", required: false),
            .init(id: "example_id", name: "Example ID", type: "text", required: false),
            .init(id: "provenance", name: "Provenance", type: "text", required: false),
        ],
        templates: [
            .init(
                name: "Example Cloze",
                prompt: [.init(field: "sentence")],
                answer: [.init(field: "sentence"), .init(field: "form")],
                interaction: "cloze",
                skill: .init(input: "text", output: "text", operation: "recall")
            ),
        ]
    )
}

private struct GeneratedProvenanceEnvelope: Encodable {
    let packID: String
    let entryID: String
    let senseID: String?
    let definitionIDs: [String]
    let exampleID: String?
    let pack: VocabularyProvenanceSelection?
    let entry: VocabularyProvenanceSelection?
    let pronunciation: VocabularyProvenanceSelection?
    let sense: VocabularyProvenanceSelection?
    let definitions: [VocabularyProvenanceSelection]
    let example: VocabularyProvenanceSelection?
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
    let itemTypes: [String]
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
    let fields: [String: AuthoredValue]
    let tags: [String]
}

private enum AuthoredValue: Encodable {
    case text(String, lang: String?)
    case cloze(String)
    case media(path: String, alt: String?)

    private enum CodingKeys: String, CodingKey {
        case text, lang, cloze, media
    }

    private struct MediaValue: Encodable {
        let path: String
        let alt: String?
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text, lang):
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(lang, forKey: .lang)
        case let .cloze(value):
            try container.encode(value, forKey: .cloze)
        case let .media(path, alt):
            try container.encode(MediaValue(path: path, alt: alt), forKey: .media)
        }
    }
}
