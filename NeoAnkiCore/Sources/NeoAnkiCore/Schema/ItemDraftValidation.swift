import Foundation

/// Platform-neutral draft content used by every editor and persistence adapter.
public struct ItemDraftContent: Sendable, Equatable {
    public var text: [UUID: String]
    public var media: [UUID: MediaRef]
    public var mediaDescriptions: [UUID: String]
    public var occlusions: [UUID: ImageOcclusionContent]
    public var clozeBlanks: [UUID: [ClozeSpan]]

    public init(
        text: [UUID: String] = [:],
        media: [UUID: MediaRef] = [:],
        mediaDescriptions: [UUID: String] = [:],
        clozeBlanks: [UUID: [ClozeSpan]] = [:],
        occlusions: [UUID: ImageOcclusionContent] = [:]
    ) {
        self.text = text
        self.media = media
        self.mediaDescriptions = mediaDescriptions
        self.occlusions = occlusions
        self.clozeBlanks = clozeBlanks
    }
}

public enum ItemDraftValidationIssue: Sendable, Equatable {
    case missingRequiredField(UUID)
    case missingMediaDescription(UUID)
    case invalidCloze(UUID)
    case invalidOcclusion(UUID)
    case invalidValue(UUID)
}

public enum ItemDraftValidation {
    public static func issues(
        in draft: ItemDraftContent,
        itemType: ItemType
    ) -> [ItemDraftValidationIssue] {
        itemType.fields.compactMap { field in
            if field.type == .studyExercise, let value = draft.text[field.id], !value.isEmpty,
               (try? StudyExercise(editorText: value)) == nil { return .invalidValue(field.id) }
            if field.type == .number {
                let input = draft.text[field.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
                if !input.isEmpty, Double(input)?.isFinite != true { return .invalidValue(field.id) }
            }
            if let reference = draft.media[field.id],
               reference.kind != field.type.mediaKind || !reference.isValidStoredReference {
                return .invalidValue(field.id)
            }
            if field.type == .imageOcclusion, let content = draft.occlusions[field.id] {
                do { try ImageOcclusionValidation.validate(content) }
                catch { return .invalidOcclusion(field.id) }
            }
            if field.type == .cloze {
                let text = draft.text[field.id, default: ""]
                let blanks = draft.clozeBlanks[field.id, default: []]
                // An absent optional cloze is allowed; every populated cloze
                // uses the same overlap/Unicode/overflow-safe contract as writes.
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !blanks.isEmpty {
                    do { try ClozeValidation.validate(text: text, blanks: blanks) }
                    catch { return .invalidCloze(field.id) }
                }
            }
            guard field.isRequired else { return nil }
            let hasValue: Bool
            switch field.type {
            case .text, .richText, .number, .cloze, .studyExercise:
                hasValue = !draft.text[field.id, default: ""]
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .checkbox:
                hasValue = true
            case .imageOcclusion:
                hasValue = draft.occlusions[field.id] != nil
            case .audio, .image, .gif, .video:
                hasValue = draft.media[field.id] != nil
            }
            return hasValue ? nil : .missingRequiredField(field.id)
        }
    }

    public static func canSave(_ draft: ItemDraftContent, itemType: ItemType) -> Bool {
        issues(in: draft, itemType: itemType).isEmpty
    }
}
