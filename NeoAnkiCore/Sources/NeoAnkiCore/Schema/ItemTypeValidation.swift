import Foundation

public enum ItemTypeValidation {
    public static func validate(_ itemType: ItemType) throws {
        _ = try validateName(itemType.name)
        try validateFields(itemType.fields)

        guard !itemType.templates.isEmpty else {
            throw DatabaseError.invalidItemType("An item type must have at least one template.")
        }

        var ids = Set(itemType.fields.map(\.id))
        var listNames: Set<String> = []
        for list in itemType.lists {
            let name = list.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, listNames.insert(name.lowercased()).inserted, ids.insert(list.id).inserted else {
                throw DatabaseError.invalidItemType("Lists need unique names and IDs.")
            }
            try validateFields(list.columns)
            for column in list.columns {
                guard ids.insert(column.id).inserted,
                      [.text, .richText, .number, .checkbox, .cloze].contains(column.type) else {
                    throw DatabaseError.invalidItemType("List columns need unique IDs and a supported field type.")
                }
            }
            if let rows = list.sharedRows { try ItemStore.validateRows(rows, in: list) }
        }

        for template in itemType.templates {
            let trimmedName = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                throw DatabaseError.invalidItemType("Every template needs a name.")
            }

            let listIDs = template.cardCreation?.listIDs ?? []
            let selected = itemType.lists.filter { listIDs.contains($0.id) }
            guard selected.count == listIDs.count, Set(listIDs).count == listIDs.count else {
                throw DatabaseError.invalidItemType("Card creation needs distinct lists from this item type.")
            }
            let fieldIDs = Set(itemType.fields.map(\.id) + selected.flatMap { $0.columns.map(\.id) })
            for id in template.cardCreation?.checkedFieldIDs ?? []
                where !fieldIDs.contains(id) || itemType.sourceField(id)?.type != .checkbox {
                throw DatabaseError.invalidItemType("Checked filters need a checkbox from the item or a selected list.")
            }
            for fieldID in fieldIDsReferenced(by: template) where !fieldIDs.contains(fieldID) {
                throw DatabaseError.invalidItemType(
                    "Template \"\(template.name)\" references an unknown field."
                )
            }
            if template.promptFormat != .standard, ![.onYourOwn, .type].contains(template.response) {
                throw DatabaseError.invalidItemType("A Cloze or Image Occlusion prompt can use On your own or Type an answer.")
            }
            try validateComposition(template, in: itemType)
            try validateMediaBehaviors(template, in: itemType)

            if template.response == .audioSubmission {
                try validateAudioSubmissionTemplate(template)
            }

            if template.interaction == .imageOcclusion {
                let fields = Set(template.components.filter { $0.purpose == .question }.compactMap { component -> UUID? in
                    guard case let .field(id) = component.source, itemType.sourceField(id)?.type == .imageOcclusion else { return nil }
                    return id
                })
                guard fields.count == 1 else { throw DatabaseError.invalidItemType("Image Occlusion needs exactly one occlusion question field.") }
            }
            if template.interaction == .cloze {
                try validateClozeTemplate(template, in: itemType)
            }
        }
    }

    private static func validateAudioSubmissionTemplate(_ template: Template) throws {
        guard template.components.contains(where: { $0.purpose == .question }) else {
            throw DatabaseError.invalidItemType(
                "Audio Submission templates need at least one question component."
            )
        }
        guard !template.components.contains(where: { $0.purpose == .expectedAnswer }) else {
            throw DatabaseError.invalidItemType(
                "Audio Submission templates cannot have an expected answer."
            )
        }
        guard template.skill.output == .audio else {
            throw DatabaseError.invalidItemType(
                "Audio Submission templates must use audio as their output modality."
            )
        }
    }

    private static func validateMediaBehaviors(_ template: Template, in itemType: ItemType) throws {
        for component in template.components {
            let kind: MediaKind?
            switch component.source {
            case let .field(id):
                kind = itemType.sourceField(id)?.type.mediaKind
            case .literal:
                kind = nil
            }
            guard component.presentation.media.isSupported(for: kind) else {
                throw DatabaseError.invalidItemType(
                    "Template \"\(template.name)\" uses \(component.presentation.media.rawValue) on content that cannot play media."
                )
            }
        }
    }

    private static func validateComposition(_ template: Template, in itemType: ItemType) throws {
        guard !template.components.isEmpty else {
            throw DatabaseError.invalidItemType("Every template needs at least one component.")
        }
        guard Set(template.components.map(\.id)).count == template.components.count else {
            throw DatabaseError.invalidItemType("Template component IDs must be unique.")
        }
        guard template.components.contains(where: { $0.purpose == .question }) else {
            throw DatabaseError.invalidItemType("Every template needs a question component.")
        }
        if template.response != .audioSubmission, template.interaction != .imageOcclusion,
           !(template.promptFormat == .cloze && template.response == .type),
           !template.components.contains(where: { $0.purpose == .expectedAnswer }) {
            throw DatabaseError.invalidItemType("Every graded template needs an expected answer component.")
        }

        for component in template.components {
            if component.purpose == .expectedAnswer, component.presentation.reveal == .always {
                throw DatabaseError.invalidItemType(
                    "Expected answers must stay concealed until answer reveal."
                )
            }
            if component.region == .media, !isVisual(component, in: itemType) {
                throw DatabaseError.invalidItemType(
                    "The media region accepts only image, GIF, or video fields."
                )
            }
        }

        if template.layout == .mediaAside || template.layout == .mediaHero,
           !template.components.contains(where: { $0.region == .media }) {
            throw DatabaseError.invalidItemType(
                "Media layouts require a visual component in the media region."
            )
        }
    }

    private static func isVisual(_ component: TemplateComponent, in itemType: ItemType) -> Bool {
        guard case let .field(id) = component.source,
              let kind = itemType.sourceField(id)?.type.mediaKind else { return false }
        return kind == .image || kind == .gif || kind == .video
    }

    private static func validateClozeTemplate(_ template: Template, in itemType: ItemType) throws {
        let clozeFields = Set(template.components.compactMap { component -> UUID? in
            guard component.purpose == .question,
                  case let .field(id) = component.source else { return nil }
            return id
        }).compactMap(itemType.sourceField).filter { $0.type == .cloze }
        guard clozeFields.count == 1 else {
            throw DatabaseError.invalidItemType(
                "Cloze templates must use exactly one cloze question component."
            )
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

        var seenIDs: Set<UUID> = []
        var seenNames: Set<String> = []
        for field in fields {
            guard seenIDs.insert(field.id).inserted else {
                throw DatabaseError.invalidItemType("Item type field IDs must be unique.")
            }
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
        template.components.compactMap { component in
            if case let .field(id) = component.source { return id }
            return nil
        } + generateWhenFieldIDs(template.generateWhen)
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
        case .text, .richText, .number, .cloze, .studyExercise, .checkbox:
            return .text
        case .audio:
            return .audio
        case .image, .imageOcclusion, .gif:
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

        let textFields = normalizedFields.filter(\.isTextLike)
        guard textFields.count >= 2 else {
            throw DatabaseError.invalidItemType("Add at least two text-like fields.")
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
                type: field.type,
                isRequired: field.isRequired
            )
        }
    }
}
