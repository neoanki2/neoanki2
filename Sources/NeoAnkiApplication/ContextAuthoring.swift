import Foundation
import NeoAnkiCore

/// A learning target is an expression in a meaning, independent of card layout.
public struct ContextTarget: Codable, Equatable, Sendable {
    public var expression: String
    public var language: String
    public var meaning: String
    public var forms: [String]
    public var packID: String?
    public var entryID: String?
    public var senseID: String?

    public init(expression: String, language: String, meaning: String = "", forms: [String] = [],
                packID: String? = nil, entryID: String? = nil, senseID: String? = nil) {
        self.expression = expression; self.language = language; self.meaning = meaning
        self.forms = forms; self.packID = packID; self.entryID = entryID; self.senseID = senseID
    }
}

/// Character offsets, deliberately matching core ClozeSpan rather than pack scalar offsets.
public struct ContextSpan: Codable, Equatable, Sendable {
    public var start: Int
    public var length: Int
    public init(start: Int, length: Int) { self.start = start; self.length = length }
}

public struct ContextProvenance: Codable, Equatable, Sendable {
    public enum Origin: String, Codable, Sendable { case dictionary, corpus, localMedia, generated, manual }
    public var origin: Origin
    public var sourceName: String
    public var sourceID: String?
    public var recordID: String?
    public var attribution: String?
    public var license: String?
    public var sourceURL: String?
    public var createdAt: Date
    public var systemVersion: String?
    public var promptVersion: Int?
    public var originalText: String?
    public var inheritedSources: [ContextProvenance]?

    public init(origin: Origin, sourceName: String, sourceID: String? = nil, recordID: String? = nil, attribution: String? = nil,
                license: String? = nil, sourceURL: String? = nil) {
        self.origin = origin; self.sourceName = sourceName; self.sourceID = sourceID; self.recordID = recordID
        self.attribution = attribution; self.license = license; self.sourceURL = sourceURL
        createdAt = .now
    }
}

public struct ContextExample: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var sentence: String
    public var spans: [ContextSpan]
    public var usageNote: String
    /// The meaning and language of this particular sentence; older drafts inherit the target.
    public var meaning: String?
    public var language: String?
    public var provenance: ContextProvenance
    public var isSelected: Bool
    public var needsMeaningCheck: Bool
    public var isEdited: Bool
    /// Device-local input only. These paths are never copied into portable provenance.
    public var mediaURL: URL?
    public var mediaKind: MediaKind?
    public var clipStart: Double?
    public var clipEnd: Double?

    public init(id: UUID = UUID(), sentence: String, spans: [ContextSpan] = [], usageNote: String = "", meaning: String? = nil, language: String? = nil,
                provenance: ContextProvenance, needsMeaningCheck: Bool = false) {
        self.id = id; self.sentence = sentence; self.spans = spans; self.usageNote = usageNote
        self.meaning = meaning; self.language = language
        self.provenance = provenance; self.needsMeaningCheck = needsMeaningCheck
        isSelected = !needsMeaningCheck; isEdited = false
    }
}

public enum ContextCapability: Equatable, Sendable {
    case available
    case unavailable(String)
    public var reason: String? { if case let .unavailable(reason) = self { reason } else { nil } }
}

public protocol LocalContextRetrieving: Sendable {
    func examples(for target: ContextTarget, limit: Int) async throws -> [ContextExample]
}

public protocol ContextGenerating: Sendable {
    func availability(language: String) async -> ContextCapability
    func examples(for target: ContextTarget, count: Int, excluding: [String], simpler: Bool) async throws -> [ContextExample]
}

public struct ContextSpeechAsset: Sendable {
    public var data: Data
    public var voiceID: String
    public init(data: Data, voiceID: String) { self.data = data; self.voiceID = voiceID }
}

public protocol ContextSpeechSynthesizing: Sendable {
    func availability(language: String) async -> ContextCapability
    func audio(text: String, language: String) async throws -> ContextSpeechAsset
}

public enum ContextAuthoringError: LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case let .message(value): value } }
}
