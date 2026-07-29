import Foundation
import NeoAnkiCore

struct FieldDraft: Identifiable, Equatable {
    var id: UUID
    var name: String
    var type: FieldType
    var isRequired: Bool

    init(id: UUID = UUID(), name: String = "", type: FieldType = .text, isRequired: Bool = true) {
        self.id = id
        self.name = name
        self.type = type
        self.isRequired = isRequired
    }

    init(field: FieldDef) {
        id = field.id
        name = field.name
        type = field.type
        isRequired = field.isRequired
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct ItemTypeDraft: Equatable {
    var name: String
    var fields: [FieldDraft]

    init(name: String = "", fields: [FieldDraft] = []) {
        self.name = name
        self.fields = fields
    }

    init(itemType: ItemType) {
        name = itemType.name
        fields = itemType.fields.map(FieldDraft.init)
    }

    static var new: ItemTypeDraft {
        ItemTypeDraft(
            name: "",
            fields: [
                FieldDraft(name: "Front", isRequired: true),
                FieldDraft(name: "Back", isRequired: true),
            ]
        )
    }

    var isValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, fields.count >= 2 else { return false }
        guard fields.allSatisfy(\.isValid) else { return false }
        let names = fields.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return Set(names).count == names.count
    }

    func fieldDefs() -> [FieldDef] {
        fields.map { draft in
            FieldDef(
                id: draft.id,
                name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                type: draft.type,
                isRequired: draft.isRequired
            )
        }
    }
}

struct SlotDraft: Identifiable, Equatable {
    enum SourceKind: String, CaseIterable {
        case field
        case literal
    }

    var id = UUID()
    var sourceKind: SourceKind = .field
    var fieldID: UUID?
    var literal = ""
    var reveal: RevealMode = .always
    var media: MediaBehavior = .default

    init(
        id: UUID = UUID(),
        sourceKind: SourceKind = .field,
        fieldID: UUID? = nil,
        literal: String = "",
        reveal: RevealMode = .always,
        media: MediaBehavior = .default
    ) {
        self.id = id
        self.sourceKind = sourceKind
        self.fieldID = fieldID
        self.literal = literal
        self.reveal = reveal
        self.media = media
    }

    init(slot: Slot) {
        switch slot.source {
        case let .field(fieldID):
            sourceKind = .field
            self.fieldID = fieldID
        case let .literal(literal):
            sourceKind = .literal
            self.literal = literal
        }
        reveal = slot.presentation.reveal
        media = slot.presentation.media
    }

    var isValid: Bool {
        switch sourceKind {
        case .field:
            return fieldID != nil
        case .literal:
            return !literal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func slot() throws -> Slot {
        let source: SlotSource
        switch sourceKind {
        case .field:
            guard let fieldID else {
                throw DatabaseError.invalidItemType("Choose a field for every field slot.")
            }
            source = .field(fieldID)
        case .literal:
            let value = literal.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                throw DatabaseError.invalidItemType("Literal slots can't be empty.")
            }
            source = .literal(value)
        }
        return Slot(source: source, presentation: Presentation(reveal: reveal, media: media))
    }
}

indirect enum ConditionDraft: Equatable {
    case fieldNotEmpty(UUID?)
    case fieldEmpty(UUID?)
    case all([ConditionDraft])
    case any([ConditionDraft])

    init(condition: SlotCondition) {
        switch condition {
        case let .fieldNotEmpty(id):
            self = .fieldNotEmpty(id)
        case let .fieldEmpty(id):
            self = .fieldEmpty(id)
        case let .all(conditions):
            self = .all(conditions.map(ConditionDraft.init))
        case let .any(conditions):
            self = .any(conditions.map(ConditionDraft.init))
        }
    }

    var isValid: Bool {
        switch self {
        case let .fieldNotEmpty(id), let .fieldEmpty(id):
            return id != nil
        case let .all(children), let .any(children):
            return !children.isEmpty && children.allSatisfy(\.isValid)
        }
    }

    func condition() throws -> SlotCondition {
        switch self {
        case let .fieldNotEmpty(id):
            guard let id else { throw DatabaseError.invalidItemType("Choose a field for the generation rule.") }
            return .fieldNotEmpty(id)
        case let .fieldEmpty(id):
            guard let id else { throw DatabaseError.invalidItemType("Choose a field for the generation rule.") }
            return .fieldEmpty(id)
        case let .all(children):
            guard !children.isEmpty else {
                throw DatabaseError.invalidItemType("An “all” rule needs at least one condition.")
            }
            return .all(try children.map { try $0.condition() })
        case let .any(children):
            guard !children.isEmpty else {
                throw DatabaseError.invalidItemType("An “any” rule needs at least one condition.")
            }
            return .any(try children.map { try $0.condition() })
        }
    }
}

struct TemplateDraft: Equatable {
    var name: String
    var interaction: Interaction
    var skill: Skill
    var usesAutomaticSkill: Bool
    var generateWhen: ConditionDraft?
    var promptSlots: [SlotDraft]
    var answerSlots: [SlotDraft]

    init(
        name: String = "",
        interaction: Interaction = .reveal,
        skill: Skill = Skill(input: .text, output: .text, operation: .recognize),
        usesAutomaticSkill: Bool = true,
        generateWhen: ConditionDraft? = nil,
        promptSlots: [SlotDraft] = [SlotDraft()],
        answerSlots: [SlotDraft] = [SlotDraft()]
    ) {
        self.name = name
        self.interaction = interaction
        self.skill = skill
        self.usesAutomaticSkill = usesAutomaticSkill
        self.generateWhen = generateWhen
        self.promptSlots = promptSlots
        self.answerSlots = answerSlots
    }

    init(
        name: String,
        promptFieldID: UUID?,
        answerFieldID: UUID?,
        promptMediaBehavior: MediaBehavior = .default
    ) {
        self.init(
            name: name,
            promptSlots: [SlotDraft(fieldID: promptFieldID, media: promptMediaBehavior)],
            answerSlots: [SlotDraft(fieldID: answerFieldID)]
        )
    }

    init(template: Template, in itemType: ItemType) {
        name = template.name
        interaction = template.interaction
        skill = template.skill
        usesAutomaticSkill = false
        generateWhen = template.generateWhen.map(ConditionDraft.init)
        promptSlots = template.prompt.slots.map(SlotDraft.init)
        answerSlots = template.answer.slots.map(SlotDraft.init)
        for index in promptSlots.indices
            where !promptSlots[index].media.isSupported(
                for: promptSlots[index].fieldID.flatMap(itemType.field)?.type.mediaKind
            ) {
            promptSlots[index].media = .default
        }
        for index in answerSlots.indices
            where !answerSlots[index].media.isSupported(
                for: answerSlots[index].fieldID.flatMap(itemType.field)?.type.mediaKind
            ) {
            answerSlots[index].media = .default
        }
    }

    var hasAdvancedSettings: Bool {
        !usesAutomaticSkill
            || generateWhen != nil
            || (promptSlots + answerSlots).contains { slot in
                slot.sourceKind != .field
                    || slot.reveal != .always
                    || slot.media != .default
            }
    }

    var isValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && !promptSlots.isEmpty
            && !answerSlots.isEmpty
            && promptSlots.allSatisfy(\.isValid)
            && answerSlots.allSatisfy(\.isValid)
            && (generateWhen?.isValid ?? true)
    }

    func template(id: UUID, in itemType: ItemType) throws -> Template {
        let prompt = Side(slots: try promptSlots.map { try $0.slot() })
        let answer = Side(slots: try answerSlots.map { try $0.slot() })
        let resolvedSkill: Skill
        if usesAutomaticSkill,
           let promptID = ItemTypeValidation.fieldIDs(in: prompt).first,
           let answerID = ItemTypeValidation.fieldIDs(in: answer).first,
           let promptField = itemType.field(promptID),
           let answerField = itemType.field(answerID) {
            resolvedSkill = TemplateBuilder.deriveSkill(
                promptField: promptField,
                answerField: answerField,
                in: itemType
            )
        } else {
            resolvedSkill = skill
        }
        let template = Template(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            prompt: prompt,
            answer: answer,
            interaction: interaction,
            skill: resolvedSkill,
            generateWhen: try generateWhen?.condition()
        )
        var candidate = itemType
        candidate.templates = [template]
        try ItemTypeValidation.validate(candidate)
        return template
    }
}

@MainActor
@Observable
final class TemplatesModel {
    private(set) var itemTypes: [ItemType] = []
    private(set) var includedItemTypeGroups: [IncludedItemTypeGroup] = []
    private(set) var corruptedDefinitions: [QuarantinedItemTypeDefinition] = []
    private(set) var isLoading = true
    private(set) var errorMessage: String?

    var selectedItemTypeID: ItemType.ID?

    let store: ItemStore

    init(store: ItemStore) {
        self.store = store
    }

    var selectedItemType: ItemType? {
        guard let selectedItemTypeID else { return nil }
        return itemTypes.first { $0.id == selectedItemTypeID }
            ?? includedItemTypeGroups.lazy
                .flatMap(\.itemTypes)
                .first { $0.id == selectedItemTypeID }
    }

    var selectedIncludedGroup: IncludedItemTypeGroup? {
        guard let selectedItemTypeID else { return nil }
        return includedItemTypeGroups.first {
            $0.itemTypes.contains { $0.id == selectedItemTypeID }
        }
    }

    var isSelectedItemTypeReadOnly: Bool {
        selectedIncludedGroup != nil
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let catalog = try await store.loadItemTypeCatalog()
            itemTypes = catalog.itemTypes
            includedItemTypeGroups = catalog.includedWithDecks
            corruptedDefinitions = catalog.corruptions
            if !catalog.corruptions.isEmpty {
                let count = catalog.corruptions.count
                errorMessage = count == 1
                    ? "One item type couldn’t be read. Other item types are available; repair the damaged definition when ready."
                    : "\(count) item types couldn’t be read. Other item types are available; repair damaged definitions when ready."
            }
            if selectedItemTypeID == nil {
                selectedItemTypeID = itemTypes.first?.id
            } else if selectedItemType == nil {
                selectedItemTypeID = itemTypes.first?.id
            }
        } catch {
            errorMessage = UserFacingError.message(from: error)
        }
        isLoading = false
    }

    func repairDefinition(_ corruption: QuarantinedItemTypeDefinition) async -> Bool {
        guard let id = corruption.repairableID else {
            errorMessage = "This damaged item type has an invalid identifier and needs manual recovery."
            return false
        }
        do {
            _ = try await store.repairItemTypeDefinition(id: id)
            await load()
            return !corruptedDefinitions.contains(where: { $0.persistedID == corruption.persistedID })
        } catch {
            errorMessage = "The damaged definition couldn’t be repaired. Its original data was left unchanged."
            return false
        }
    }

    func createItemType(_ draft: ItemTypeDraft) async -> Bool {
        errorMessage = nil
        guard draft.isValid else {
            errorMessage = "Enter a name and at least two unique field names."
            return false
        }

        do {
            let itemType = try ItemTypeBuilder.makeItemType(
                name: draft.name,
                fields: draft.fieldDefs()
            )
            let created = try await store.createItemType(itemType)
            itemTypes.append(created)
            itemTypes.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            selectedItemTypeID = created.id
            return true
        } catch let error as DatabaseError {
            errorMessage = itemTypeErrorMessage(from: error)
            return false
        } catch {
            errorMessage = UserFacingError.message(from: error)
            return false
        }
    }

    func updateItemType(_ draft: ItemTypeDraft, editingID: UUID) async -> Bool {
        errorMessage = nil
        guard !isSelectedItemTypeReadOnly else {
            errorMessage = "Item types included with decks are read-only. Duplicate this definition to edit it."
            return false
        }
        guard draft.isValid else {
            errorMessage = "Enter a name and at least two unique field names."
            return false
        }
        guard let existing = itemTypes.first(where: { $0.id == editingID }) else {
            errorMessage = "Item type not found."
            return false
        }

        do {
            let updated = try ItemTypeBuilder.updatedItemType(
                from: existing,
                name: draft.name,
                fields: draft.fieldDefs()
            )
            let saved = try await store.updateItemType(updated)
            if let index = itemTypes.firstIndex(where: { $0.id == saved.id }) {
                itemTypes[index] = saved
            }
            itemTypes.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return true
        } catch let error as DatabaseError {
            errorMessage = itemTypeErrorMessage(from: error)
            return false
        } catch {
            errorMessage = UserFacingError.message(from: error)
            return false
        }
    }

    func deleteSelectedItemType() async -> Bool {
        errorMessage = nil
        guard !isSelectedItemTypeReadOnly else {
            errorMessage = "Item types included with decks can’t be deleted here."
            return false
        }
        guard let itemType = selectedItemType else {
            errorMessage = "No item type is selected."
            return false
        }

        do {
            guard try await store.deleteItemType(id: itemType.id) else { return false }
            itemTypes.removeAll { $0.id == itemType.id }
            selectedItemTypeID = itemTypes.first?.id
            return true
        } catch let error as DatabaseError {
            errorMessage = itemTypeErrorMessage(from: error)
            return false
        } catch {
            errorMessage = UserFacingError.message(from: error)
            return false
        }
    }

    func itemCount(for itemTypeID: UUID) async -> Int {
        (try? await store.countItems(itemTypeID: itemTypeID)) ?? 0
    }

    func canDeleteSelectedItemType() async -> Bool {
        guard !isSelectedItemTypeReadOnly else { return false }
        guard let itemType = selectedItemType else { return false }
        return await itemCount(for: itemType.id) == 0
    }

    func duplicateSelectedItemType(name: String) async -> Bool {
        errorMessage = nil
        guard isSelectedItemTypeReadOnly, let selectedItemType else {
            errorMessage = "Select an item type included with a deck."
            return false
        }
        do {
            let created = try await store.duplicateItemType(id: selectedItemType.id, name: name)
            itemTypes.append(created)
            itemTypes.sort {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            selectedItemTypeID = created.id
            return true
        } catch let error as DatabaseError {
            errorMessage = itemTypeErrorMessage(from: error)
            return false
        } catch {
            errorMessage = UserFacingError.message(from: error)
            return false
        }
    }

    func saveTemplate(_ draft: TemplateDraft, editingID: UUID?) async -> Bool {
        errorMessage = nil
        guard !isSelectedItemTypeReadOnly else {
            errorMessage = "Item types included with decks are read-only."
            return false
        }
        guard var itemType = selectedItemType else {
            errorMessage = "No item type is selected."
            return false
        }

        guard draft.isValid else {
            errorMessage = "Enter a name and complete every prompt, answer, and generation rule."
            return false
        }

        do {
            let template = try draft.template(id: editingID ?? UUID(), in: itemType)

            if let editingID, let index = itemType.templates.firstIndex(where: { $0.id == editingID }) {
                itemType.templates[index] = template
            } else {
                itemType.templates.append(template)
            }

            let updated = try await store.updateItemType(itemType)
            if let index = itemTypes.firstIndex(where: { $0.id == updated.id }) {
                itemTypes[index] = updated
            }
            return true
        } catch let error as DatabaseError {
            errorMessage = itemTypeErrorMessage(from: error)
            return false
        } catch {
            errorMessage = UserFacingError.message(from: error)
            return false
        }
    }

    func deleteTemplate(id: UUID) async -> Bool {
        errorMessage = nil
        guard !isSelectedItemTypeReadOnly else {
            errorMessage = "Item types included with decks are read-only."
            return false
        }
        guard var itemType = selectedItemType else {
            errorMessage = "No item type is selected."
            return false
        }

        guard itemType.templates.count > 1 else {
            errorMessage = "An item type must have at least one template."
            return false
        }

        guard itemType.templates.contains(where: { $0.id == id }) else {
            return false
        }

        do {
            itemType.templates.removeAll { $0.id == id }
            let updated = try await store.updateItemType(itemType)
            if let index = itemTypes.firstIndex(where: { $0.id == updated.id }) {
                itemTypes[index] = updated
            }
            return true
        } catch let error as DatabaseError {
            errorMessage = itemTypeErrorMessage(from: error)
            return false
        } catch {
            errorMessage = UserFacingError.message(from: error)
            return false
        }
    }

    func fieldName(for fieldID: UUID, in itemType: ItemType) -> String {
        itemType.field(fieldID)?.name ?? "Unknown"
    }

    func templateSummary(_ template: Template, in itemType: ItemType) -> String {
        let promptIDs = ItemTypeValidation.fieldIDs(in: template.prompt)
        let answerIDs = ItemTypeValidation.fieldIDs(in: template.answer)
        let prompt = promptIDs.first.map { fieldName(for: $0, in: itemType) } ?? "?"
        let answer = answerIDs.first.map { fieldName(for: $0, in: itemType) } ?? "?"
        return "\(prompt) → \(answer)"
    }

    private func itemTypeErrorMessage(from error: DatabaseError) -> String {
        if case let .invalidItemType(message) = error {
            return message
        }
        return UserFacingError.message(from: error)
    }
}
