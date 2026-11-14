import Foundation
import NeoAnkiApplication
import NeoAnkiCore

public enum ContextExamplePreset {
    // Stable identities let all sets share ordinary, editable user-owned schema data.
    public static let typeID = UUID(uuidString: "4B127AF3-2D55-459F-A534-6849E12C8100")!
    private static func id(_ suffix: String) -> UUID { UUID(uuidString: "4B127AF3-2D55-459F-A534-6849E12C\(suffix)")! }
    public static let target = FieldDef(id: id("8101"), name: "Target", type: .text, isRequired: true)
    public static let context = FieldDef(id: id("8102"), name: "Context", type: .richText, isRequired: true)
    public static let meaning = FieldDef(id: id("8103"), name: "Meaning", type: .text, isRequired: true)
    public static let note = FieldDef(id: id("8104"), name: "Usage note", type: .text)
    public static let audio = FieldDef(id: id("8105"), name: "Audio", type: .audio)
    public static let video = FieldDef(id: id("8106"), name: "Video", type: .video)
    public static let cloze = FieldDef(id: id("8107"), name: "Cloze practice", type: .cloze)
    public static let listening = FieldDef(id: id("8108"), name: "Listening practice", type: .text)
    public static let metadata = FieldDef(id: id("8109"), name: "Context provenance", type: .text)
    public static let group = FieldDef(id: id("8110"), name: "Context set", type: .text)
    public static func authoringFields(in type: ItemType) -> [FieldDef] {
        guard type.id == typeID || (type.fields.contains { $0.name == metadata.name } && type.fields.contains { $0.name == group.name }) else { return type.fields }
        let internalNames = Set([metadata.name, group.name, listening.name])
        return type.fields.filter { !internalNames.contains($0.name) && ![metadata.id, group.id, listening.id].contains($0.id) }
    }
    public static var itemType: ItemType {
        let answer: [TemplateComponent] = [
            .init(id: id("8130"), region: .secondary, purpose: .expectedAnswer, source: .field(meaning.id), presentation: .init(reveal: .hiddenUntilAnswer)),
            .init(id: id("8131"), region: .supporting, purpose: .expectedAnswer, source: .field(note.id), presentation: .init(reveal: .hiddenUntilAnswer))
        ]
        return ItemType(id: typeID, name: "Context Example", fields: [target, context, meaning, note, audio, video, cloze, listening, metadata, group], templates: [
            Template(id: id("8120"), name: "Understand in context", layout: .focus, components: [
                .init(id: id("8140"), region: .primary, purpose: .question, source: .field(context.id)),
                .init(id: id("8141"), region: .media, purpose: .supporting, source: .field(video.id), presentation: .init(media: .playOnTap)),
                .init(id: id("8142"), region: .supporting, purpose: .supporting, source: .field(audio.id), presentation: .init(media: .playOnTap))
            ] + answer, interaction: .reveal, skill: .init(input: .text, output: .text, operation: .recognize)),
            Template(id: id("8121"), name: "Recall expression", layout: .focus, components: [
                .init(id: id("8150"), region: .primary, purpose: .question, source: .field(cloze.id)),
                .init(id: id("8151"), region: .supporting, purpose: .expectedAnswer, source: .field(audio.id), presentation: .init(reveal: .hiddenUntilAnswer, media: .playOnTap)),
                .init(id: id("8152"), region: .media, purpose: .expectedAnswer, source: .field(video.id), presentation: .init(reveal: .hiddenUntilAnswer, media: .playOnTap))
            ] + answer, interaction: .cloze, skill: .init(input: .text, output: .text, operation: .recall), generateWhen: .fieldNotEmpty(cloze.id)),
            Template(id: id("8122"), name: "Understand by listening", layout: .focus, components: [
                .init(id: id("8160"), region: .primary, purpose: .question, source: .field(audio.id), presentation: .init(media: .playOnTap)),
                .init(id: id("8161"), region: .secondary, purpose: .expectedAnswer, source: .field(context.id), presentation: .init(reveal: .hiddenUntilAnswer))
            ] + answer, interaction: .reveal, skill: .init(input: .audio, output: .text, operation: .recognize),
                     generateWhen: .all([.fieldNotEmpty(audio.id), .fieldNotEmpty(listening.id)]))
        ])
    }
}

public struct SavedContextMetadata: Codable, Equatable, Sendable {
    public var format = "neoanki-context-example"
    public var version = 1
    public var groupID: UUID?
    public var target: ContextTarget
    public var spans: [ContextSpan]
    public var provenance: ContextProvenance
    public var clipStart: Double?
    public var clipEnd: Double?
    public var voiceID: String?
    public var speechText: String?

    public static func groupID(in item: Item) -> UUID? {
        for field in item.fields {
            if case let .text(json, _) = field.value, json.first == "{", json.contains("neoanki-context-example"),
               let decoded = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)), decoded.format == "neoanki-context-example" {
                return decoded.groupID
            }
        }
        return nil
    }
}

public enum ContextDerivedContent {
    /// A rewritten sentence must not keep reading or showing its old recording.
    /// Retain newly supplied media and edits that change formatting alone.
    public static func invalidatingSpeech(in candidate: Item, original: Item, type: ItemType) -> Item {
        guard let metadataField = type.fields.first(where: { $0.id == ContextExamplePreset.metadata.id || $0.name == ContextExamplePreset.metadata.name }),
              case let .text(json, _)? = original.value(for: metadataField.id),
              var metadata = try? JSONDecoder().decode(SavedContextMetadata.self, from: Data(json.utf8)),
              metadata.format == "neoanki-context-example",
              let contextField = type.fields.first(where: { $0.id == ContextExamplePreset.context.id || $0.name == ContextExamplePreset.context.name }) else { return candidate }
        let previousSentence = text(in: original.value(for: contextField.id))
        let sentence = text(in: candidate.value(for: contextField.id))
        guard sentence != previousSentence else { return candidate }
        let mediaFields = type.fields.filter {
            $0.id == ContextExamplePreset.audio.id || $0.name == ContextExamplePreset.audio.name
                || $0.id == ContextExamplePreset.video.id || $0.name == ContextExamplePreset.video.name
        }
        let staleFields = Set(mediaFields.compactMap { field -> UUID? in
            guard let before = original.value(for: field.id)?.mediaReference,
                  let after = candidate.value(for: field.id)?.mediaReference,
                  before.kind == after.kind, before.assetHash == after.assetHash else { return nil }
            return field.id
        })
        metadata.voiceID = nil; metadata.speechText = nil
        metadata.clipStart = nil; metadata.clipEnd = nil
        metadata.provenance.originalText = metadata.provenance.originalText ?? previousSentence
        metadata.spans = ContextOccurrences.find(target: metadata.target, in: sentence).spans
        var updated = candidate
        updated.fields = candidate.fields.map { field in
            if staleFields.contains(field.fieldID) { return .init(fieldID: field.fieldID, value: .empty) }
            if field.fieldID == metadataField.id, let data = try? JSONEncoder().encode(metadata) {
                return .init(fieldID: field.fieldID, value: .text(String(decoding: data, as: UTF8.self)))
            }
            return field
        }
        return updated
    }
    private static func text(in value: ContentValue?) -> String {
        switch value {
        case let .text(value, _), let .cloze(value, _): value
        case let .rich(spans): spans.map(\.text).joined()
        default: ""
        }
    }
}
