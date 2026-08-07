import Foundation

/// Platform-neutral draft content used by every editor and persistence adapter.
public struct ItemDraftContent: Sendable, Equatable {
    public var text: [UUID: String]
    public var media: [UUID: MediaRef]
    public var mediaDescriptions: [UUID: String]
    public var clozeBlanks: [UUID: [ClozeSpan]]

    public init(
        text: [UUID: String] = [:],
        media: [UUID: MediaRef] = [:],
        mediaDescriptions: [UUID: String] = [:],
        clozeBlanks: [UUID: [ClozeSpan]] = [:]
    ) {
        self.text = text
        self.media = media
        self.mediaDescriptions = mediaDescriptions
        self.clozeBlanks = clozeBlanks
    }
}

public enum ItemDraftValidationIssue: Sendable, Equatable {
    case missingRequiredField(UUID)
    case missingMediaDescription(UUID)
    case invalidCloze(UUID)
}

public enum ItemDraftValidation {
    public static func issues(
        in draft: ItemDraftContent,
        itemType: ItemType
    ) -> [ItemDraftValidationIssue] {
        itemType.fields.compactMap { field in
            if [.image, .gif].contains(field.type), draft.media[field.id] != nil {
                let description = draft.mediaDescriptions[field.id, default: ""]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if description.isEmpty { return .missingMediaDescription(field.id) }
            }
            if field.type == .cloze {
                let characterCount = draft.text[field.id, default: ""].count
                let valid = draft.clozeBlanks[field.id, default: []].allSatisfy {
                    $0.start >= 0 && $0.length > 0 && $0.start + $0.length <= characterCount
                }
                if !valid { return .invalidCloze(field.id) }
            }
            guard field.isRequired else { return nil }
            let hasValue: Bool
            switch field.type {
            case .text, .richText, .number, .cloze:
                hasValue = !draft.text[field.id, default: ""]
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
