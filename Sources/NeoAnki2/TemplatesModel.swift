import Foundation
import NeoAnkiCore

struct FieldDraft: Identifiable, Equatable {
    var id: UUID
    var name: String
    var isRequired: Bool

    init(id: UUID = UUID(), name: String = "", isRequired: Bool = true) {
        self.id = id
        self.name = name
        self.isRequired = isRequired
    }

    init(field: FieldDef) {
        id = field.id
        name = field.name
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
                type: .text,
                isRequired: draft.isRequired
            )
        }
    }
}

struct TemplateDraft: Equatable {
    var name: String
    var promptFieldID: UUID?
    var answerFieldID: UUID?

    init(name: String = "", promptFieldID: UUID? = nil, answerFieldID: UUID? = nil) {
        self.name = name
        self.promptFieldID = promptFieldID
        self.answerFieldID = answerFieldID
    }

    init(template: Template, in itemType: ItemType) {
        name = template.name
        promptFieldID = ItemTypeValidation.fieldIDs(in: template.prompt).first
        answerFieldID = ItemTypeValidation.fieldIDs(in: template.answer).first
    }

    var isValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let promptFieldID, let answerFieldID else { return false }
        return promptFieldID != answerFieldID
    }
}

@MainActor
@Observable
final class TemplatesModel {
    private(set) var itemTypes: [ItemType] = []
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
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            itemTypes = try await store.listItemTypes()
            if selectedItemTypeID == nil {
                selectedItemTypeID = itemTypes.first?.id
            } else if !itemTypes.contains(where: { $0.id == selectedItemTypeID }) {
                selectedItemTypeID = itemTypes.first?.id
            }
        } catch {
            errorMessage = UserFacingError.message(from: error)
        }
        isLoading = false
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
        guard let itemType = selectedItemType else { return false }
        if BuiltInItemTypes.isBuiltIn(itemType.id) { return false }
        return await itemCount(for: itemType.id) == 0
    }

    func saveTemplate(_ draft: TemplateDraft, editingID: UUID?) async -> Bool {
        errorMessage = nil
        guard var itemType = selectedItemType else {
            errorMessage = "No item type is selected."
            return false
        }

        guard draft.isValid, let promptFieldID = draft.promptFieldID, let answerFieldID = draft.answerFieldID else {
            errorMessage = "Enter a name and choose different prompt and answer fields."
            return false
        }

        do {
            let template = try TemplateBuilder.makeRevealTemplate(
                id: editingID ?? UUID(),
                name: draft.name,
                promptFieldID: promptFieldID,
                answerFieldID: answerFieldID,
                in: itemType
            )

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
