import Foundation

/// A language-neutral vocabulary feature advertised by an offline pack.
public enum VocabularyCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case lexicon
    case pronunciation
    case morphology
    case corpus
    case frequency
}

public struct LocalizedText: Codable, Hashable, Sendable {
    public var value: String
    /// BCP-47 when known. Nil is useful for IPA and other language-independent representations.
    public var language: String?

    public init(_ value: String, language: String? = nil) {
        self.value = value
        self.language = language
    }
}

public struct LexicalTrait: Codable, Hashable, Sendable {
    /// An open identifier, for example `partOfSpeech` or a namespaced data-source key.
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct LexicalForm: Codable, Hashable, Sendable {
    public var id: String?
    public var text: LocalizedText
    /// An open value such as `lemma`, `inflected`, `variant`, or a namespaced scheme.
    public var kind: String?
    public var grammaticalFeatures: [LexicalTrait]
    public var provenance: Provenance?

    public init(
        id: String? = nil,
        text: LocalizedText,
        kind: String? = nil,
        grammaticalFeatures: [LexicalTrait] = [],
        provenance: Provenance? = nil
    ) {
        self.id = id
        self.text = text
        self.kind = kind
        self.grammaticalFeatures = grammaticalFeatures
        self.provenance = provenance
    }
}

public struct AudioReference: Codable, Hashable, Sendable {
    /// A relative path below the pack's `media` directory. Remote URLs are never accepted.
    public var path: String
    public var mimeType: String?

    public init(path: String, mimeType: String? = nil) {
        self.path = path
        self.mimeType = mimeType
    }
}

public enum PronunciationRepresentation: Codable, Hashable, Sendable {
    case text(LocalizedText)
    case audio(AudioReference)
}

public struct Pronunciation: Codable, Hashable, Sendable {
    public var id: String?
    /// An arbitrary scheme identifier: `ipa`, `orthographic-respelling`, `pinyin`, etc.
    public var scheme: String
    public var label: String?
    public var representations: [PronunciationRepresentation]
    /// Empty means the pronunciation applies to every form in the entry.
    public var formIDs: [String]
    /// Empty means the pronunciation applies to every sense in the entry.
    public var senseIDs: [String]
    public var provenance: Provenance?

    public init(
        id: String? = nil,
        scheme: String,
        label: String? = nil,
        representations: [PronunciationRepresentation],
        formIDs: [String] = [],
        senseIDs: [String] = [],
        provenance: Provenance? = nil
    ) {
        self.id = id
        self.scheme = scheme
        self.label = label
        self.representations = representations
        self.formIDs = formIDs
        self.senseIDs = senseIDs
        self.provenance = provenance
    }

    private enum CodingKeys: String, CodingKey {
        case id, scheme, label, representations, formIDs, senseIDs, provenance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id),
            scheme: try container.decode(String.self, forKey: .scheme),
            label: try container.decodeIfPresent(String.self, forKey: .label),
            representations: try container.decode([PronunciationRepresentation].self, forKey: .representations),
            formIDs: try container.decodeIfPresent([String].self, forKey: .formIDs) ?? [],
            senseIDs: try container.decodeIfPresent([String].self, forKey: .senseIDs) ?? [],
            provenance: try container.decodeIfPresent(Provenance.self, forKey: .provenance)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(scheme, forKey: .scheme)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encode(representations, forKey: .representations)
        if !formIDs.isEmpty { try container.encode(formIDs, forKey: .formIDs) }
        if !senseIDs.isEmpty { try container.encode(senseIDs, forKey: .senseIDs) }
        try container.encodeIfPresent(provenance, forKey: .provenance)
    }
}

public struct Provenance: Codable, Hashable, Sendable {
    public var sourceID: String
    public var sourceName: String?
    public var recordID: String?
    public var attribution: String?
    public var license: String?
    /// Metadata only. NeoAnkiVocabularyKit never resolves this value.
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

/// A stable span measured in Unicode scalar values, never UTF-8/UTF-16 code units.
public struct UnicodeScalarRange: Codable, Hashable, Sendable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

public struct ExampleTarget: Codable, Hashable, Sendable {
    /// The precise surface form to hide, which may differ from the entry lemma.
    public var exactText: String
    /// Optional unambiguous location. When present, the compiler validates it against `exactText`.
    public var scalarRange: UnicodeScalarRange?

    public init(exactText: String, scalarRange: UnicodeScalarRange? = nil) {
        self.exactText = exactText
        self.scalarRange = scalarRange
    }
}

public struct UsageExample: Codable, Hashable, Sendable {
    public var id: String?
    public var text: LocalizedText
    public var target: ExampleTarget?
    public var provenance: Provenance?

    public init(
        id: String? = nil,
        text: LocalizedText,
        target: ExampleTarget? = nil,
        provenance: Provenance? = nil
    ) {
        self.id = id
        self.text = text
        self.target = target
        self.provenance = provenance
    }
}

public struct Definition: Codable, Hashable, Sendable {
    public var id: String?
    public var text: LocalizedText
    public var provenance: Provenance?

    public init(id: String? = nil, text: LocalizedText, provenance: Provenance? = nil) {
        self.id = id
        self.text = text
        self.provenance = provenance
    }
}

public struct LexicalSense: Codable, Hashable, Sendable {
    public var id: String
    public var definitions: [Definition]
    public var examples: [UsageExample]
    public var labels: [String]
    public var provenance: Provenance?

    public init(
        id: String,
        definitions: [Definition] = [],
        examples: [UsageExample] = [],
        labels: [String] = [],
        provenance: Provenance? = nil
    ) {
        self.id = id
        self.definitions = definitions
        self.examples = examples
        self.labels = labels
        self.provenance = provenance
    }
}

public struct LexicalEntry: Codable, Hashable, Sendable {
    public var id: String
    public var language: String
    public var canonicalForm: LexicalForm
    public var forms: [LexicalForm]
    public var pronunciations: [Pronunciation]
    public var senses: [LexicalSense]
    public var frequency: Double?
    public var provenance: Provenance?

    public init(
        id: String,
        language: String,
        canonicalForm: LexicalForm,
        forms: [LexicalForm] = [],
        pronunciations: [Pronunciation] = [],
        senses: [LexicalSense] = [],
        frequency: Double? = nil,
        provenance: Provenance? = nil
    ) {
        self.id = id
        self.language = language
        self.canonicalForm = canonicalForm
        self.forms = forms
        self.pronunciations = pronunciations
        self.senses = senses
        self.frequency = frequency
        self.provenance = provenance
    }
}
