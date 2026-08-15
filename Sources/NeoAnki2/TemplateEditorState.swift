import CoreTransferable
import Foundation
import NeoAnkiCore
import Observation
import UniformTypeIdentifiers

enum TemplateSide: String, Codable, CaseIterable, Hashable, Sendable {
    case prompt
    case answer

    var title: String {
        switch self {
        case .prompt: "Prompt"
        case .answer: "Answer"
        }
    }
}

enum TemplatePreviewPhase: String, CaseIterable, Sendable {
    case beforeAnswer
    case afterAnswer

    var label: String {
        switch self {
        case .beforeAnswer: "Before answer"
        case .afterAnswer: "After answer"
        }
    }
}

enum TemplateEditorSelection: Equatable, Sendable {
    case slot(side: TemplateSide, id: UUID)
    case generationAndSkill
}

enum TemplateValidationTarget: Hashable, Sendable {
    case name
    case side(TemplateSide)
    case slot(side: TemplateSide, id: UUID)
    case generation
}

struct TemplateValidationIssue: Identifiable, Equatable, Sendable {
    let target: TemplateValidationTarget
    let message: String

    var id: String { "\(target)-\(message)" }
}

struct TemplateBuilderDragPayload: Codable, Transferable, Sendable {
    enum Source: Codable, Sendable {
        case field(UUID)
        case literal
        case slot(side: TemplateSide, id: UUID)
    }

    let source: Source

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .neoAnkiTemplateBuilderBlock)
            .visibility(.ownProcess)
    }
}

extension UTType {
    static let neoAnkiTemplateBuilderBlock = UTType(
        exportedAs: "com.neoanki2.template-builder-block"
    )
}

@MainActor
@Observable
final class TemplateEditorState {
    let itemType: ItemType
    let editingTemplate: Template?
    let initialDraft: TemplateDraft

    var draft: TemplateDraft
    var selection: TemplateEditorSelection?
    var previewPhase: TemplatePreviewPhase = .beforeAnswer
    var validationIssues: [TemplateValidationIssue] = []
    var isSaving = false
    var pendingInteraction: Interaction?

    private(set) var stashedAnswerSlots: [SlotDraft]?
    private var stashedAutomaticSkill: Bool?
    private var stashedSkill: Skill?

    init(itemType: ItemType, editingTemplate: Template? = nil) {
        self.itemType = itemType
        self.editingTemplate = editingTemplate
        let draft = editingTemplate.map { TemplateDraft(template: $0, in: itemType) }
            ?? TemplateDraft(promptSlots: [], answerSlots: [])
        self.initialDraft = draft
        self.draft = draft
    }

    var isDirty: Bool { draft != initialDraft }

    func slots(on side: TemplateSide) -> [SlotDraft] {
        switch side {
        case .prompt: draft.promptSlots
        case .answer: draft.answerSlots
        }
    }

    func slot(on side: TemplateSide, id: UUID) -> SlotDraft? {
        slots(on: side).first { $0.id == id }
    }

    func issue(for target: TemplateValidationTarget) -> TemplateValidationIssue? {
        validationIssues.first { $0.target == target }
    }

    func requestInteraction(_ interaction: Interaction) {
        guard interaction != draft.interaction else { return }
        if interaction == .audioSubmission, !draft.answerSlots.isEmpty {
            pendingInteraction = interaction
            return
        }
        applyInteraction(interaction)
    }

    func confirmPendingInteraction() {
        guard pendingInteraction == .audioSubmission else { return }
        pendingInteraction = nil
        applyInteraction(.audioSubmission)
    }

    func cancelPendingInteraction() {
        pendingInteraction = nil
    }

    func addField(_ fieldID: UUID, to side: TemplateSide, at index: Int? = nil) {
        guard side != .answer || draft.interaction != .audioSubmission else { return }
        var slot = SlotDraft(fieldID: fieldID)
        if side == .prompt,
           draft.interaction == .cloze,
           itemType.field(fieldID)?.type == .cloze {
            slot.reveal = .hiddenUntilAnswer
        }
        insert(slot, on: side, at: index)
    }

    func addLiteral(to side: TemplateSide, at index: Int? = nil) {
        guard side != .answer || draft.interaction != .audioSubmission else { return }
        insert(SlotDraft(sourceKind: .literal), on: side, at: index)
    }

    @discardableResult
    func accept(
        _ payload: TemplateBuilderDragPayload,
        on side: TemplateSide,
        at index: Int? = nil
    ) -> Bool {
        guard side != .answer || draft.interaction != .audioSubmission else { return false }
        switch payload.source {
        case let .field(fieldID):
            guard itemType.field(fieldID) != nil else { return false }
            addField(fieldID, to: side, at: index)
        case .literal:
            addLiteral(to: side, at: index)
        case let .slot(sourceSide, id):
            guard moveSlot(id: id, from: sourceSide, to: side, at: index) else { return false }
        }
        return true
    }

    func updateSlot(on side: TemplateSide, id: UUID, _ update: (inout SlotDraft) -> Void) {
        var values = slots(on: side)
        guard let index = values.firstIndex(where: { $0.id == id }) else { return }
        update(&values[index])
        setSlots(values, on: side)
        refreshValidationIfNeeded()
    }

    func setSourceKind(_ sourceKind: SlotDraft.SourceKind, on side: TemplateSide, id: UUID) {
        updateSlot(on: side, id: id) { slot in
            slot.sourceKind = sourceKind
            slot.media = .default
        }
    }

    func setField(_ fieldID: UUID?, on side: TemplateSide, id: UUID) {
        updateSlot(on: side, id: id) { slot in
            slot.fieldID = fieldID
            let kind = fieldID.flatMap(itemType.field)?.type.mediaKind
            if !slot.media.isSupported(for: kind) {
                slot.media = .default
            }
            if side == .prompt,
               draft.interaction == .cloze,
               fieldID.flatMap(itemType.field)?.type == .cloze,
               slot.reveal == .always {
                slot.reveal = .hiddenUntilAnswer
            }
        }
    }

    func duplicateSlot(on side: TemplateSide, id: UUID) {
        var values = slots(on: side)
        guard let index = values.firstIndex(where: { $0.id == id }) else { return }
        let source = values[index]
        let duplicate = SlotDraft(
            sourceKind: source.sourceKind,
            fieldID: source.fieldID,
            literal: source.literal,
            reveal: source.reveal,
            media: source.media
        )
        values.insert(duplicate, at: index + 1)
        setSlots(values, on: side)
        selection = .slot(side: side, id: duplicate.id)
        refreshValidationIfNeeded()
    }

    func removeSlot(on side: TemplateSide, id: UUID) {
        var values = slots(on: side)
        guard let index = values.firstIndex(where: { $0.id == id }) else { return }
        values.remove(at: index)
        setSlots(values, on: side)
        if case .slot(side, id) = selection {
            if values.isEmpty {
                selection = nil
            } else {
                selection = .slot(side: side, id: values[min(index, values.count - 1)].id)
            }
        }
        refreshValidationIfNeeded()
    }

    func moveSlot(on side: TemplateSide, id: UUID, by offset: Int) {
        var values = slots(on: side)
        guard let source = values.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard values.indices.contains(destination) else { return }
        values.swapAt(source, destination)
        setSlots(values, on: side)
        selection = .slot(side: side, id: id)
    }

    @discardableResult
    func validate() -> Bool {
        validationIssues = computedValidationIssues()
        if let first = validationIssues.first {
            switch first.target {
            case let .slot(side, id):
                selection = .slot(side: side, id: id)
            case .generation:
                selection = .generationAndSkill
            case .name, .side:
                break
            }
        }
        return validationIssues.isEmpty
    }

    func refreshValidationIfNeeded() {
        guard !validationIssues.isEmpty else { return }
        validationIssues = computedValidationIssues()
    }

    private func applyInteraction(_ interaction: Interaction) {
        let wasAudioSubmission = draft.interaction == .audioSubmission
        draft.interaction = interaction

        if interaction == .audioSubmission {
            if stashedAnswerSlots == nil {
                stashedAnswerSlots = draft.answerSlots
                stashedAutomaticSkill = draft.usesAutomaticSkill
                stashedSkill = draft.skill
            }
            draft.answerSlots = []
            draft.usesAutomaticSkill = false
            draft.skill.output = .audio
            previewPhase = .beforeAnswer
            if case .slot(.answer, _) = selection { selection = nil }
        } else if wasAudioSubmission {
            if let stashedAnswerSlots {
                draft.answerSlots = stashedAnswerSlots
                self.stashedAnswerSlots = nil
            }
            if let stashedAutomaticSkill {
                draft.usesAutomaticSkill = stashedAutomaticSkill
                self.stashedAutomaticSkill = nil
            }
            if let stashedSkill {
                draft.skill = stashedSkill
                self.stashedSkill = nil
            }
        }

        if interaction == .cloze {
            for index in draft.promptSlots.indices
                where draft.promptSlots[index].reveal == .always
                    && draft.promptSlots[index].fieldID.flatMap(itemType.field)?.type == .cloze {
                draft.promptSlots[index].reveal = .hiddenUntilAnswer
            }
        }
        refreshValidationIfNeeded()
    }

    private func insert(_ slot: SlotDraft, on side: TemplateSide, at requestedIndex: Int?) {
        var values = slots(on: side)
        let index = min(max(requestedIndex ?? values.count, 0), values.count)
        values.insert(slot, at: index)
        setSlots(values, on: side)
        selection = .slot(side: side, id: slot.id)
        refreshValidationIfNeeded()
    }

    private func moveSlot(
        id: UUID,
        from sourceSide: TemplateSide,
        to destinationSide: TemplateSide,
        at requestedIndex: Int?
    ) -> Bool {
        var sourceValues = slots(on: sourceSide)
        guard let sourceIndex = sourceValues.firstIndex(where: { $0.id == id }) else { return false }
        let moved = sourceValues.remove(at: sourceIndex)

        if sourceSide == destinationSide {
            var destination = requestedIndex ?? sourceValues.count
            if let requestedIndex, requestedIndex > sourceIndex { destination -= 1 }
            destination = min(max(destination, 0), sourceValues.count)
            sourceValues.insert(moved, at: destination)
            setSlots(sourceValues, on: sourceSide)
        } else {
            var destinationValues = slots(on: destinationSide)
            let destination = min(max(requestedIndex ?? destinationValues.count, 0), destinationValues.count)
            destinationValues.insert(moved, at: destination)
            setSlots(sourceValues, on: sourceSide)
            setSlots(destinationValues, on: destinationSide)
        }
        selection = .slot(side: destinationSide, id: id)
        refreshValidationIfNeeded()
        return true
    }

    private func setSlots(_ slots: [SlotDraft], on side: TemplateSide) {
        switch side {
        case .prompt: draft.promptSlots = slots
        case .answer: draft.answerSlots = slots
        }
    }

    private func computedValidationIssues() -> [TemplateValidationIssue] {
        var issues: [TemplateValidationIssue] = []
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(target: .name, message: "Enter a template name."))
        }
        appendSideIssues(.prompt, to: &issues)
        if draft.interaction != .audioSubmission {
            appendSideIssues(.answer, to: &issues)
        }
        if let condition = draft.generateWhen, !condition.isValid {
            issues.append(.init(
                target: .generation,
                message: "Complete every card-generation rule."
            ))
        }
        if draft.interaction == .cloze {
            let clozeCount = draft.promptSlots.filter { slot in
                slot.sourceKind == .field
                    && slot.fieldID.flatMap(itemType.field)?.type == .cloze
            }.count
            if clozeCount != 1 {
                issues.append(.init(
                    target: .side(.prompt),
                    message: "A Cloze template needs exactly one Cloze field on the prompt."
                ))
            }
        }
        return issues
    }

    private func appendSideIssues(
        _ side: TemplateSide,
        to issues: inout [TemplateValidationIssue]
    ) {
        let values = slots(on: side)
        if values.isEmpty {
            issues.append(.init(
                target: .side(side),
                message: "Add at least one \(side.title.lowercased()) block."
            ))
        }
        for slot in values where !slot.isValid {
            issues.append(.init(
                target: .slot(side: side, id: slot.id),
                message: slot.sourceKind == .field
                    ? "Choose a field for this block."
                    : "Enter text for this block."
            ))
        }
    }
}

enum TemplatePreviewFixture {
    static func sides(
        for phase: TemplatePreviewPhase,
        interaction: Interaction
    ) -> [TemplateSide] {
        guard phase == .afterAnswer, interaction != .audioSubmission else { return [.prompt] }
        return [.prompt, .answer]
    }

    static func isAnswerRevealed(for phase: TemplatePreviewPhase) -> Bool {
        phase == .afterAnswer
    }

    static func value(for field: FieldDef) -> ContentValue {
        let example = "Example \(field.name.lowercased())"
        switch field.type {
        case .text:
            return .text(example)
        case .richText:
            return .rich([Span(example)])
        case .number:
            return .number(42)
        case .cloze:
            return .cloze("Example answer", blanks: [ClozeSpan(group: 1, start: 8, length: 6)])
        case .audio, .image, .gif, .video:
            let kind = field.type.mediaKind!
            return .media(MediaRef(
                id: field.id,
                kind: kind,
                assetHash: String(repeating: "a", count: 64),
                fileExtension: fileExtension(for: kind),
                durationMs: kind == .audio || kind == .video ? 12_000 : nil,
                altText: "Example \(field.name) \(FieldTypeLabels.name(for: field.type).lowercased())"
            ))
        }
    }

    static func value(for slot: SlotDraft, in itemType: ItemType) -> ContentValue? {
        switch slot.sourceKind {
        case .field:
            guard let fieldID = slot.fieldID, let field = itemType.field(fieldID) else { return nil }
            return value(for: field)
        case .literal:
            let text = slot.literal.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : .text(text)
        }
    }

    private static func fileExtension(for kind: MediaKind) -> String {
        switch kind {
        case .audio: "m4a"
        case .image: "png"
        case .gif: "gif"
        case .video: "mp4"
        }
    }
}
