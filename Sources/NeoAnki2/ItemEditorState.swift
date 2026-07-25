import Foundation
import NeoAnkiCore

struct ItemEditorSnapshot: Equatable {
    var fieldSpans: [UUID: [Span]]
    var fieldText: [UUID: String]
    var fieldMedia: [UUID: MediaRef]
    var fieldMediaAltText: [UUID: String]
    var fieldClozeBlanks: [UUID: [ClozeSpan]]
}

enum ItemEditorState {
    static func empty(for itemType: ItemType?) -> ItemEditorSnapshot {
        guard let itemType else {
            return ItemEditorSnapshot(
                fieldSpans: [:],
                fieldText: [:],
                fieldMedia: [:],
                fieldMediaAltText: [:],
                fieldClozeBlanks: [:]
            )
        }
        return ItemEditorSnapshot(
            fieldSpans: Dictionary(
                uniqueKeysWithValues: itemType.fields
                    .filter { $0.type == .text || $0.type == .richText }
                    .map { ($0.id, []) }
            ),
            fieldText: Dictionary(
                uniqueKeysWithValues: itemType.fields
                    .filter { $0.type == .number || $0.type == .cloze }
                    .map { ($0.id, "") }
            ),
            fieldMedia: [:],
            fieldMediaAltText: [:],
            fieldClozeBlanks: Dictionary(
                uniqueKeysWithValues: itemType.fields
                    .filter { $0.type == .cloze }
                    .map { ($0.id, []) }
            )
        )
    }

    static func hydrated(from item: Item, itemType: ItemType) -> ItemEditorSnapshot {
        var snapshot = empty(for: itemType)
        for field in itemType.fields {
            guard let value = item.value(for: field.id) else { continue }
            switch value {
            case let .text(text, _):
                snapshot.fieldSpans[field.id] = text.isEmpty ? [] : [Span(text)]
            case let .rich(spans):
                snapshot.fieldSpans[field.id] = spans
            case let .number(number):
                snapshot.fieldText[field.id] = String(number)
            case let .media(ref):
                snapshot.fieldMedia[field.id] = ref
                snapshot.fieldMediaAltText[field.id] = ref.altText ?? ""
            case let .cloze(text, blanks):
                snapshot.fieldText[field.id] = text
                snapshot.fieldClozeBlanks[field.id] = blanks
            case .empty:
                break
            }
        }
        return snapshot
    }

    static func canSave(_ snapshot: ItemEditorSnapshot, itemType: ItemType?) -> Bool {
        guard let itemType else { return false }
        return itemType.fields.allSatisfy { field in
            if [.image, .gif].contains(field.type), snapshot.fieldMedia[field.id] != nil {
                let description = snapshot.fieldMediaAltText[field.id, default: ""]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !description.isEmpty else { return false }
            }
            guard field.isRequired else { return true }
            return !plainContent(for: field, in: snapshot).isEmpty
        }
    }

    private static func plainContent(for field: FieldDef, in snapshot: ItemEditorSnapshot) -> String {
        switch field.type {
        case .text, .richText:
            return SpanFormatting.plainText(from: snapshot.fieldSpans[field.id, default: []])
        case .number, .cloze:
            return snapshot.fieldText[field.id, default: ""]
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case .audio, .image, .gif, .video:
            return snapshot.fieldMedia[field.id] == nil ? "" : "media"
        }
    }
}
