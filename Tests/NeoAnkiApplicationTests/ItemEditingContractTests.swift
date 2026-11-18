import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import Testing

/// Contracts at the platform-neutral editor boundary. These exercise real draft
/// validation and hydration, rather than duplicating either native view's bindings.
@Suite struct ItemEditingContractTests {
    private func reference(_ kind: MediaKind = .image) -> MediaRef {
        .init(kind: kind, assetHash: String(repeating: "a", count: 64),
              fileExtension: kind == .image ? "png" : kind == .audio ? "caf" : kind == .gif ? "gif" : "mp4",
              altText: "Description")
    }

    private func populated(_ kind: FieldType, field: UUID) -> ItemEditorSnapshot {
        var snapshot = ItemEditorState.empty(for: nil)
        switch kind {
        case .text, .richText: snapshot.fieldSpans[field] = [Span("A 🧠 e\u{301}", styles: [.bold])]
        case .number: snapshot.fieldText[field] = "-42.5"
        case .cloze:
            snapshot.fieldText[field] = "A 🧠 e\u{301}"
            snapshot.fieldClozeBlanks[field] = [.init(group: 1, start: 2, length: 1, hint: "brain")]
        case .image, .audio, .gif, .video:
            let media: MediaKind = kind == .image ? .image : kind == .audio ? .audio : kind == .gif ? .gif : .video
            snapshot.fieldMedia[field] = reference(media)
        case .imageOcclusion:
            snapshot.fieldOcclusions[field] = .init(image: reference(), masks: [
                .init(group: 1, rect: .init(x: 0.1, y: 0.2, width: 0.3, height: 0.4)),
            ], nextGroup: 2)
        }
        return snapshot
    }

    @Test(arguments: FieldType.allCases, [false, true])
    func requiredAndOptionalValues(kind: FieldType, required: Bool) {
        let field = FieldDef(name: "Value", type: kind, isRequired: required)
        let type = ItemType(name: "Editor", fields: [field], templates: [])
        #expect(ItemEditorState.canSave(ItemEditorState.empty(for: type), itemType: type) == !required)
        #expect(ItemEditorState.canSave(populated(kind, field: field.id), itemType: type))
    }

    @Test(arguments: [FieldType.text, .richText, .number, .cloze], ["", " ", "\t\n", "\u{00a0}"])
    func whitespaceCannotSatisfyRequiredText(kind: FieldType, whitespace: String) {
        let field = FieldDef(name: "Value", type: kind, isRequired: true)
        let type = ItemType(name: "Editor", fields: [field], templates: [])
        var draft = ItemEditorState.empty(for: type)
        if kind == .text || kind == .richText { draft.fieldSpans[field.id] = [Span(whitespace)] }
        else { draft.fieldText[field.id] = whitespace }
        #expect(!ItemEditorState.canSave(draft, itemType: type))
    }

    @Test func absentTypeCannotBeSavedAndUnknownValuesDoNotSatisfyRequiredFields() {
        #expect(!ItemEditorState.canSave(ItemEditorState.empty(for: nil), itemType: nil))
        let field = FieldDef(name: "Required", type: .text, isRequired: true)
        let type = ItemType(name: "Editor", fields: [field], templates: [])
        var draft = ItemEditorState.empty(for: type)
        draft.fieldSpans[UUID()] = [Span("An unrelated field")]
        #expect(!ItemEditorState.canSave(draft, itemType: type))
        let item = Item(itemTypeID: type.id, fields: [.init(fieldID: UUID(), value: .text("Unknown"))])
        #expect(ItemEditorState.hydrated(from: item, itemType: type) == ItemEditorState.empty(for: type))
    }

    @Test(arguments: FieldType.allCases)
    func hydrationIsIndependentForEveryFieldKind(kind: FieldType) throws {
        let field = FieldDef(name: "Value", type: kind, isRequired: true)
        let type = ItemType(name: "Editor", fields: [field], templates: [])
        let expected = populated(kind, field: field.id)
        let value: ContentValue
        switch kind {
        case .text: value = .text("A 🧠 e\u{301}", lang: "en")
        case .richText: value = .rich(try #require(expected.fieldSpans[field.id]))
        case .number: value = .number(-42.5)
        case .cloze: value = .cloze(try #require(expected.fieldText[field.id]), blanks: try #require(expected.fieldClozeBlanks[field.id]))
        case .image, .audio, .gif, .video: value = .media(try #require(expected.fieldMedia[field.id]))
        case .imageOcclusion: value = .imageOcclusion(try #require(expected.fieldOcclusions[field.id]))
        }
        let item = Item(itemTypeID: type.id, fields: [.init(fieldID: field.id, value: value)])
        let hydrated = ItemEditorState.hydrated(from: item, itemType: type)
        #expect(ItemEditorState.canSave(hydrated, itemType: type))
        switch kind {
        case .text: #expect(hydrated.fieldSpans[field.id] == [Span("A 🧠 e\u{301}")])
        case .richText: #expect(hydrated.fieldSpans == expected.fieldSpans)
        case .number: #expect(hydrated.fieldText == expected.fieldText)
        case .cloze:
            #expect(hydrated.fieldText == expected.fieldText)
            #expect(hydrated.fieldClozeBlanks == expected.fieldClozeBlanks)
        case .image, .audio, .gif, .video:
            #expect(hydrated.fieldMedia == expected.fieldMedia)
            #expect(hydrated.fieldMediaAltText[field.id] == "Description")
        case .imageOcclusion: #expect(hydrated.fieldOcclusions == expected.fieldOcclusions)
        }
        #expect(ItemEditorState.hydrated(from: .init(itemTypeID: type.id, fields: [.init(fieldID: field.id, value: .empty)]), itemType: type) == ItemEditorState.empty(for: type))
    }

    @Test(arguments: Array(0..<6))
    func everySnapshotDimensionParticipatesInDiscardDetection(dimension: Int) {
        let id = UUID()
        let initial = ItemEditorState.empty(for: nil)
        var changed = initial
        switch dimension {
        case 0: changed.fieldSpans[id] = [Span("Changed")]
        case 1: changed.fieldText[id] = "42"
        case 2: changed.fieldMedia[id] = reference()
        case 3: changed.fieldMediaAltText[id] = "Changed"
        case 4: changed.fieldClozeBlanks[id] = [.init(group: 1, start: 0, length: 1)]
        default: changed.fieldOcclusions[id] = populated(.imageOcclusion, field: id).fieldOcclusions[id]
        }
        #expect(EditorDecisionState.dismissalDecision(initial: initial, current: changed) == .confirmDiscard)
        changed = initial
        #expect(EditorDecisionState.dismissalDecision(initial: initial, current: changed) == .dismiss)
    }

    @Test(arguments: ["valid", "none", "overlap", "negative", "past-end", "zero-length", "unicode"])
    func draftClozeAcceptanceAgreesWithPersistenceValidation(scenario: String) {
        let field = FieldDef(name: "Cloze", type: .cloze, isRequired: true)
        let type = ItemType(name: "Editor", fields: [field], templates: [])
        let text = scenario == "unicode" ? "A 🧠 e\u{301}" : "Alpha Beta"
        let blanks: [ClozeSpan]
        switch scenario {
        case "none": blanks = []
        case "overlap": blanks = [.init(group: 1, start: 0, length: 5), .init(group: 2, start: 3, length: 3)]
        case "negative": blanks = [.init(group: 1, start: -1, length: 1)]
        case "past-end": blanks = [.init(group: 1, start: 9, length: 2)]
        case "zero-length": blanks = [.init(group: 1, start: 0, length: 0)]
        case "unicode": blanks = [.init(group: 1, start: 2, length: 1)]
        default: blanks = [.init(group: 1, start: 0, length: 5)]
        }
        var draft = ItemEditorState.empty(for: type)
        draft.fieldText[field.id] = text
        draft.fieldClozeBlanks[field.id] = blanks
        let coreAccepts: Bool
        do { try ClozeValidation.validate(text: text, blanks: blanks); coreAccepts = true }
        catch { coreAccepts = false }
        #expect(ItemEditorState.canSave(draft, itemType: type) == coreAccepts,
                "Editor must not offer Save for cloze content persistence rejects: \(scenario)")
    }

    @Test(arguments: ["no-masks", "bad-rect", "duplicate-id", "bad-allocator", "wrong-media"])
    func invalidOcclusionsCannotBeSaved(scenario: String) throws {
        let field = FieldDef(name: "Diagram", type: .imageOcclusion)
        let type = ItemType(name: "Editor", fields: [field], templates: [])
        var draft = populated(.imageOcclusion, field: field.id)
        var content = try #require(draft.fieldOcclusions[field.id])
        switch scenario {
        case "no-masks": content.masks = []
        case "bad-rect": content.masks[0].rect.width = 2
        case "duplicate-id": content.masks.append(content.masks[0])
        case "bad-allocator": content.nextGroup = 1
        default: content.image = reference(.audio)
        }
        draft.fieldOcclusions[field.id] = content
        #expect(!ItemEditorState.canSave(draft, itemType: type))
    }
}
