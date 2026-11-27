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
}

public struct ItemEditorSnapshot: Sendable, Equatable {
    public var fieldSpans: [UUID: [Span]]
    public var fieldText: [UUID: String]
    public var fieldMedia: [UUID: MediaRef]
    public var fieldMediaAltText: [UUID: String]
    public var fieldOcclusions: [UUID: ImageOcclusionContent]
    public var fieldClozeBlanks: [UUID: [ClozeSpan]]

    public init(
        fieldSpans: [UUID: [Span]],
        fieldText: [UUID: String],
        fieldMedia: [UUID: MediaRef],
        fieldMediaAltText: [UUID: String],
        fieldClozeBlanks: [UUID: [ClozeSpan]],
        fieldOcclusions: [UUID: ImageOcclusionContent] = [:]
    ) {
        self.fieldSpans = fieldSpans
        self.fieldText = fieldText
        self.fieldMedia = fieldMedia
        self.fieldMediaAltText = fieldMediaAltText
        self.fieldOcclusions = fieldOcclusions
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
            case let .studyExercise(exercise): snapshot.fieldText[field.id] = exercise.editorText
            case let .media(reference):
                snapshot.fieldMedia[field.id] = reference
                snapshot.fieldMediaAltText[field.id] = reference.altText ?? ""
            case let .cloze(text, blanks):
                snapshot.fieldText[field.id] = text
                snapshot.fieldClozeBlanks[field.id] = blanks
            case let .imageOcclusion(content): snapshot.fieldOcclusions[field.id] = content
            case .empty: break
            }
        }
        return snapshot
    }

    public static func canSave(_ snapshot: ItemEditorSnapshot, itemType: ItemType?) -> Bool {
        guard let itemType else { return false }
        return issues(snapshot, itemType: itemType).isEmpty
    }

    public static func issues(_ snapshot: ItemEditorSnapshot, itemType: ItemType) -> [ItemDraftValidationIssue] {
        var text = snapshot.fieldText
        for (fieldID, spans) in snapshot.fieldSpans {
            text[fieldID] = spans.map(\.text).joined()
        }
        return ItemDraftValidation.issues(
            in: ItemDraftContent(
                text: text,
                media: snapshot.fieldMedia,
                mediaDescriptions: snapshot.fieldMediaAltText,
                clozeBlanks: snapshot.fieldClozeBlanks,
                occlusions: snapshot.fieldOcclusions
            ),
            itemType: itemType
        )
    }

    /// One codec for native editors. Identity and metadata are supplied by the
    /// original item rather than reconstructed independently by each platform.
    public static func fields(
        from snapshot: ItemEditorSnapshot,
        itemType: ItemType,
        preserving original: Item? = nil
    ) throws -> [FieldValue] {
        for issue in issues(snapshot, itemType: itemType) {
            if case let .invalidValue(id) = issue {
                let name = itemType.fields.first { $0.id == id }?.name ?? "this field"
                throw DatabaseError.invalidItem("Enter a valid value for \(name).")
            }
        }
        let initial = original.map { hydrated(from: $0, itemType: itemType) }
        return try itemType.fields.compactMap { field -> FieldValue? in
            var value: ContentValue
            switch field.type {
            case .text, .richText:
                value = field.contentValue(from: snapshot.fieldSpans[field.id, default: []])
                if case let .text(text, _) = value,
                   case let .text(_, language)? = original?.value(for: field.id) {
                    value = .text(text, lang: language)
                }
            case .studyExercise:
                let input = snapshot.fieldText[field.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
                value = input.isEmpty ? .empty : .studyExercise(try StudyExercise(editorText: input))
            case .number:
                let input = snapshot.fieldText[field.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
                if input.isEmpty { value = .empty }
                else {
                    guard let number = Double(input), number.isFinite else {
                        throw DatabaseError.invalidItem("Enter a finite number for \(field.name).")
                    }
                    value = .number(number)
                }
            case .audio, .image, .gif, .video:
                if var reference = snapshot.fieldMedia[field.id] {
                    let description = snapshot.fieldMediaAltText[field.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
                    reference.altText = description.isEmpty ? nil : description
                    value = field.contentValue(from: reference)
                } else { value = .empty }
            case .imageOcclusion:
                if let content = snapshot.fieldOcclusions[field.id] {
                    try ImageOcclusionValidation.validate(content)
                    value = .imageOcclusion(content)
                } else { value = .empty }
            case .cloze:
                let text = snapshot.fieldText[field.id, default: ""]
                let blanks = snapshot.fieldClozeBlanks[field.id, default: []]
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && blanks.isEmpty { value = .empty }
                else {
                    try ClozeValidation.validate(text: text, blanks: blanks)
                    value = .cloze(text, blanks: blanks)
                }
            }
            if value.isEmpty, field.isRequired { throw DatabaseError.requiredFieldEmpty(field.name) }
            if let originalValue = original?.value(for: field.id), let initial,
               fieldIsUnchanged(field, snapshot, initial) {
                return FieldValue(fieldID: field.id, value: originalValue)
            }
            if value.isEmpty { return nil }
            return FieldValue(fieldID: field.id, value: value)
        }
    }

    private static func fieldIsUnchanged(_ field: FieldDef, _ current: ItemEditorSnapshot, _ initial: ItemEditorSnapshot) -> Bool {
        switch field.type {
        case .text, .richText: current.fieldSpans[field.id] == initial.fieldSpans[field.id]
        case .number, .studyExercise: current.fieldText[field.id] == initial.fieldText[field.id]
        case .cloze:
            current.fieldText[field.id] == initial.fieldText[field.id]
                && current.fieldClozeBlanks[field.id] == initial.fieldClozeBlanks[field.id]
        case .audio, .image, .gif, .video:
            current.fieldMedia[field.id] == initial.fieldMedia[field.id]
                && current.fieldMediaAltText[field.id] == initial.fieldMediaAltText[field.id]
        case .imageOcclusion: current.fieldOcclusions[field.id] == initial.fieldOcclusions[field.id]
        }
    }
}

/// A native card-editing draft with no view, repository, or platform dependency.
public struct ItemEditorDraft: Sendable, Equatable {
    public let original: Item
    public let itemType: ItemType
    public var snapshot: ItemEditorSnapshot
    public var deckID: UUID?
    private let initialSnapshot: ItemEditorSnapshot
    private var spanEditingFields: Set<UUID>

    public init(item: Item, itemType: ItemType) {
        self.original = item
        self.itemType = itemType
        let snapshot = ItemEditorState.hydrated(from: item, itemType: itemType)
        self.snapshot = snapshot
        self.initialSnapshot = snapshot
        self.spanEditingFields = Set(itemType.fields.filter {
            $0.type == .richText || snapshot.fieldSpans[$0.id, default: []].contains(where: \.hasFormatting)
        }.map(\.id))
        self.deckID = item.deckID
    }

    public var hasChanges: Bool { snapshot != initialSnapshot || deckID != original.deckID }
    public var issues: [ItemDraftValidationIssue] { ItemEditorState.issues(snapshot, itemType: itemType) }
    public var canSave: Bool { issues.isEmpty }

    /// Formatting is valid in a text field as well as a rich-text field. Once
    /// span editing is needed, retain it even after clearing the field so the
    /// native editor does not change underneath an active editing session.
    public func requiresSpanEditing(for fieldID: UUID) -> Bool {
        spanEditingFields.contains(fieldID)
    }

    public func item() throws -> Item {
        var result = original
        result.deckID = deckID
        result.fields = try ItemEditorState.fields(from: snapshot, itemType: itemType, preserving: original)
        return result
    }

    public func text(for fieldID: UUID) -> String {
        if let spans = snapshot.fieldSpans[fieldID] { return spans.map(\.text).joined() }
        return snapshot.fieldText[fieldID, default: ""]
    }

    /// A projection of an editable value, including incomplete input. Validation
    /// and persistence conversion happen only in item(), never while rendering.
    public func value(for fieldID: UUID) -> ContentValue {
        guard let field = itemType.fields.first(where: { $0.id == fieldID }) else { return .empty }
        switch field.type {
        case .text, .richText:
            let spans = snapshot.fieldSpans[fieldID, default: []]
            if field.type == .text, spans.allSatisfy({ !$0.hasFormatting }) {
                let language: String? = if case let .text(_, language)? = original.value(for: fieldID) { language } else { nil }
                return .text(spans.map(\.text).joined(), lang: language)
            }
            return .rich(spans)
        case .studyExercise:
            return (try? StudyExercise(editorText: snapshot.fieldText[fieldID, default: ""])).map(ContentValue.studyExercise) ?? .empty
        case .number:
            return Double(snapshot.fieldText[fieldID, default: ""]).map(ContentValue.number) ?? .empty
        case .cloze:
            return .cloze(snapshot.fieldText[fieldID, default: ""], blanks: snapshot.fieldClozeBlanks[fieldID, default: []])
        case .imageOcclusion: return snapshot.fieldOcclusions[fieldID].map(ContentValue.imageOcclusion) ?? .empty
        case .audio, .image, .gif, .video:
            guard var reference = snapshot.fieldMedia[fieldID] else { return .empty }
            reference.altText = snapshot.fieldMediaAltText[fieldID]
            return .media(reference)
        }
    }

    public mutating func setText(_ text: String, for fieldID: UUID) {
        guard let field = itemType.fields.first(where: { $0.id == fieldID }) else { return }
        switch field.type {
        case .text, .richText: snapshot.fieldSpans[fieldID] = text.isEmpty ? [] : [Span(text)]
        case .cloze:
            let previous = snapshot.fieldText[fieldID, default: ""]
            snapshot.fieldClozeBlanks[fieldID] = ClozeSpanRebaser.rebase(
                spans: snapshot.fieldClozeBlanks[fieldID, default: []], from: previous, to: text).spans
            snapshot.fieldText[fieldID] = text
        case .number, .studyExercise: snapshot.fieldText[fieldID] = text
        default: break
        }
    }

    public mutating func setValue(_ value: ContentValue, for fieldID: UUID) {
        switch value {
        case let .text(text, _): setText(text, for: fieldID)
        case let .rich(spans):
            snapshot.fieldSpans[fieldID] = spans
            if spans.contains(where: \.hasFormatting) { spanEditingFields.insert(fieldID) }
        case let .number(number): snapshot.fieldText[fieldID] = String(number)
        case let .studyExercise(exercise): snapshot.fieldText[fieldID] = exercise.editorText
        case let .cloze(text, blanks):
            snapshot.fieldText[fieldID] = text
            snapshot.fieldClozeBlanks[fieldID] = blanks
        case let .media(reference):
            snapshot.fieldMedia[fieldID] = reference
            snapshot.fieldMediaAltText[fieldID] = reference.altText ?? ""
        case let .imageOcclusion(content): snapshot.fieldOcclusions[fieldID] = content
        case .empty:
            let type = itemType.fields.first(where: { $0.id == fieldID })?.type
            snapshot.fieldSpans[fieldID] = type == .text || type == .richText ? [] : nil
            snapshot.fieldText[fieldID] = type == .number || type == .cloze || type == .studyExercise ? "" : nil
            snapshot.fieldMedia[fieldID] = nil
            snapshot.fieldMediaAltText[fieldID] = nil
            snapshot.fieldClozeBlanks[fieldID] = type == .cloze ? [] : nil
            snapshot.fieldOcclusions[fieldID] = nil
        }
    }

    public func issue(for fieldID: UUID) -> String? {
        guard let issue = issues.first(where: {
            switch $0 {
            case .missingRequiredField(let id), .missingMediaDescription(let id), .invalidCloze(let id), .invalidOcclusion(let id), .invalidValue(let id): id == fieldID
            }
        }) else { return nil }
        switch issue {
        case .missingRequiredField: return "This field is required."
        case .missingMediaDescription: return "Add a description."
        case .invalidCloze: return "Mark valid, non-overlapping blanks in the cloze text."
        case .invalidOcclusion: return "Draw valid image masks before saving."
        case .invalidValue: return "Enter a valid value for this field."
        }
    }
}
