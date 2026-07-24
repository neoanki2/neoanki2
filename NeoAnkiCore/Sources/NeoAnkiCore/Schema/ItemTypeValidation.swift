import Foundation

public enum ItemTypeValidation {
    public static func validate(_ itemType: ItemType) throws {
        _ = try validateName(itemType.name)
        try validateFields(itemType.fields)

        guard !itemType.templates.isEmpty else {
            throw DatabaseError.invalidItemType("An item type must have at least one template.")
        }

        let fieldIDs = Set(itemType.fields.map(\.id))

        for template in itemType.templates {
            let trimmedName = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                throw DatabaseError.invalidItemType("Every template needs a name.")
            }

            for fieldID in fieldIDsReferenced(by: template) where !fieldIDs.contains(fieldID) {
                throw DatabaseError.invalidItemType(
                    "Template \"\(template.name)\" references an unknown field."
                )
            }
        }
    }

    public static func validateName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DatabaseError.invalidItemType("Item type name is required.")
        }
        return trimmed
    }

    public static func validateFields(_ fields: [FieldDef]) throws {
        guard !fields.isEmpty else {
            throw DatabaseError.invalidItemType("An item type needs at least one field.")
        }

        var seenNames: Set<String> = []
        for field in fields {
            let trimmed = field.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw DatabaseError.invalidItemType("Every field needs a name.")
            }
            let key = trimmed.lowercased()
            guard seenNames.insert(key).inserted else {
                throw DatabaseError.invalidItemType("Field names must be unique.")
            }
        }
    }

    public static func validateFieldRemoval(removedIDs: Set<UUID>, in itemType: ItemType) throws {
        for fieldID in removedIDs {
            for template in itemType.templates {
                guard fieldIDsReferenced(by: template).contains(fieldID) else { continue }
                let fieldName = itemType.field(fieldID)?.name ?? "Field"
                throw DatabaseError.invalidItemType(
                    "Can't remove \"\(fieldName)\" because a template uses it."
                )
            }
        }
    }

    public static func fieldIDsReferenced(by template: Template) -> [UUID] {
        fieldIDs(in: template.prompt) + fieldIDs(in: template.answer) + generateWhenFieldIDs(template.generateWhen)
    }

    public static func fieldIDs(in side: Side) -> [UUID] {
        side.slots.compactMap { slot in
            if case let .field(id) = slot.source { return id }
            return nil
        }
    }

    private static func generateWhenFieldIDs(_ condition: SlotCondition?) -> [UUID] {
        guard let condition else { return [] }
        switch condition {
        case let .fieldNotEmpty(id), let .fieldEmpty(id):
            return [id]
        case let .all(conditions):
            return conditions.flatMap(generateWhenFieldIDs)
        case let .any(conditions):
            return conditions.flatMap(generateWhenFieldIDs)
        }
    }
}

public enum TemplateBuilder {
    /// Builds a single-field reveal template with an auto-derived skill.
    public static func makeRevealTemplate(
        id: UUID = UUID(),
        name: String,
        promptFieldID: UUID,
        answerFieldID: UUID,
        in itemType: ItemType
    ) throws -> Template {
        guard let promptField = itemType.field(promptFieldID) else {
            throw DatabaseError.invalidItemType("Prompt field is not part of this item type.")
        }
        guard let answerField = itemType.field(answerFieldID) else {
            throw DatabaseError.invalidItemType("Answer field is not part of this item type.")
        }

        return Template(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            prompt: Side(slots: [Slot(source: .field(promptFieldID))]),
            answer: Side(slots: [Slot(source: .field(answerFieldID))]),
            interaction: .reveal,
            skill: deriveSkill(promptField: promptField, answerField: answerField, in: itemType)
        )
    }

    public static func deriveSkill(
        promptField: FieldDef,
        answerField: FieldDef,
        in itemType: ItemType
    ) -> Skill {
        let promptIndex = itemType.fields.firstIndex(where: { $0.id == promptField.id }) ?? 0
        let answerIndex = itemType.fields.firstIndex(where: { $0.id == answerField.id }) ?? 0
        let operation: Operation = promptIndex > answerIndex ? .recall : .recognize
        return Skill(
            input: modality(for: promptField.type),
            output: modality(for: answerField.type),
            operation: operation
        )
    }

    private static func modality(for fieldType: FieldType) -> Modality {
        switch fieldType {
        case .text, .richText, .number:
            return .text
        case .audio:
            return .audio
        case .image, .gif:
            return .image
        case .video:
            return .video
        }
    }
}

public enum ItemTypeBuilder {
    /// Creates a new item type with a default reveal template from the first two text fields.
    public static func makeItemType(name: String, fields: [FieldDef]) throws -> ItemType {
        let trimmedName = try ItemTypeValidation.validateName(name)
        let normalizedFields = try normalizeFields(fields)
        var itemType = ItemType(name: trimmedName, fields: normalizedFields, templates: [])

        let textFields = normalizedFields.filter(\.supportsTextInput)
        guard textFields.count >= 2 else {
            throw DatabaseError.invalidItemType("Add at least two text fields.")
        }

        let template = try TemplateBuilder.makeRevealTemplate(
            name: "Card",
            promptFieldID: textFields[0].id,
            answerFieldID: textFields[1].id,
            in: itemType
        )
        itemType.templates = [template]
        try ItemTypeValidation.validate(itemType)
        return itemType
    }

    /// Updates an item type's name and fields while preserving templates and field IDs.
    public static func updatedItemType(
        from existing: ItemType,
        name: String,
        fields: [FieldDef]
    ) throws -> ItemType {
        let trimmedName = try ItemTypeValidation.validateName(name)
        let normalizedFields = try normalizeFields(fields)
        let removedIDs = Set(existing.fields.map(\.id)).subtracting(normalizedFields.map(\.id))

        var updated = existing
        updated.name = trimmedName
        updated.fields = normalizedFields
        try ItemTypeValidation.validateFieldRemoval(removedIDs: removedIDs, in: updated)
        try ItemTypeValidation.validate(updated)
        return updated
    }

    private static func normalizeFields(_ fields: [FieldDef]) throws -> [FieldDef] {
        try ItemTypeValidation.validateFields(fields)
        return fields.map { field in
            FieldDef(
                id: field.id,
                name: field.name.trimmingCharacters(in: .whitespacesAndNewlines),
                type: .text,
                isRequired: field.isRequired
            )
        }
    }
}
