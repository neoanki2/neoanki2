import Foundation
import NeoAnkiCore

public enum EditorDismissalDecision: Sendable, Equatable {
    case dismiss
    case confirmDiscard
}

public enum EditorDecisionState {
    public static func dismissalDecision<Draft: Equatable>(
        initial: Draft,
        current: Draft
    ) -> EditorDismissalDecision {
        initial == current ? .dismiss : .confirmDiscard
    }

    public static func requiresTemplateDeletionConfirmation(templateExists: Bool) -> Bool {
        templateExists
    }
}

public struct ItemEditorSnapshot: Sendable, Equatable {
    public var fieldSpans: [UUID: [Span]]
    public var fieldText: [UUID: String]
    public var fieldMedia: [UUID: MediaRef]
    public var fieldMediaAltText: [UUID: String]
    public var fieldClozeBlanks: [UUID: [ClozeSpan]]

    public init(
        fieldSpans: [UUID: [Span]],
        fieldText: [UUID: String],
        fieldMedia: [UUID: MediaRef],
        fieldMediaAltText: [UUID: String],
        fieldClozeBlanks: [UUID: [ClozeSpan]]
    ) {
        self.fieldSpans = fieldSpans
        self.fieldText = fieldText
        self.fieldMedia = fieldMedia
        self.fieldMediaAltText = fieldMediaAltText
        self.fieldClozeBlanks = fieldClozeBlanks
    }
}

public enum ItemEditorState {
    public static func empty(for itemType: ItemType?) -> ItemEditorSnapshot {
        guard let itemType else {
            return ItemEditorSnapshot(
                fieldSpans: [:], fieldText: [:], fieldMedia: [:],
                fieldMediaAltText: [:], fieldClozeBlanks: [:]
            )
        }
        return ItemEditorSnapshot(
            fieldSpans: Dictionary(uniqueKeysWithValues: itemType.fields
                .filter { $0.type == .text || $0.type == .richText }.map { ($0.id, []) }),
            fieldText: Dictionary(uniqueKeysWithValues: itemType.fields
                .filter { $0.type == .number || $0.type == .cloze }.map { ($0.id, "") }),
            fieldMedia: [:],
            fieldMediaAltText: [:],
            fieldClozeBlanks: Dictionary(uniqueKeysWithValues: itemType.fields
                .filter { $0.type == .cloze }.map { ($0.id, []) })
        )
    }

    public static func hydrated(from item: Item, itemType: ItemType) -> ItemEditorSnapshot {
        var snapshot = empty(for: itemType)
        for field in itemType.fields {
            guard let value = item.value(for: field.id) else { continue }
            switch value {
            case let .text(text, _): snapshot.fieldSpans[field.id] = text.isEmpty ? [] : [Span(text)]
            case let .rich(spans): snapshot.fieldSpans[field.id] = spans
            case let .number(number): snapshot.fieldText[field.id] = String(number)
            case let .media(reference):
                snapshot.fieldMedia[field.id] = reference
                snapshot.fieldMediaAltText[field.id] = reference.altText ?? ""
            case let .cloze(text, blanks):
                snapshot.fieldText[field.id] = text
                snapshot.fieldClozeBlanks[field.id] = blanks
            case .empty: break
            }
        }
        return snapshot
    }

    public static func canSave(_ snapshot: ItemEditorSnapshot, itemType: ItemType?) -> Bool {
        guard let itemType else { return false }
        var text = snapshot.fieldText
        for (fieldID, spans) in snapshot.fieldSpans {
            text[fieldID] = spans.map(\.text).joined()
        }
        return ItemDraftValidation.canSave(
            ItemDraftContent(
                text: text,
                media: snapshot.fieldMedia,
                mediaDescriptions: snapshot.fieldMediaAltText,
                clozeBlanks: snapshot.fieldClozeBlanks
            ),
            itemType: itemType
        )
    }
}
