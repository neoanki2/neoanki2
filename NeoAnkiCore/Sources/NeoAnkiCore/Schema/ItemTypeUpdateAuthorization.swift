import Foundation

/// Workflow-only authorization for an atomic Item Type Studio update.
///
/// This value is deliberately not Codable and is never stored or exported. It
/// binds a confirmed candidate to the exact definition, generated-card
/// retirement, and private-response impact reviewed before persistence begins.
public struct ItemTypeUpdateAuthorization: Sendable, Equatable {
    public let expectedOriginal: ItemType
    public let expectedGeneratedCardRetirementIDs: Set<UUID>
    public let expectedStudyResponseDeletionIDs: Set<UUID>
    public let expectedSchemaImpactState: ItemTypeSchemaImpactState
    public let schemaChangeImpact: ItemTypeSchemaChangeImpact

    public var expectedStudyResponseDeletionCount: Int {
        expectedStudyResponseDeletionIDs.count
    }

    public var expectedGeneratedCardRetirementCount: Int {
        expectedGeneratedCardRetirementIDs.count
    }

    public init(
        expectedOriginal: ItemType,
        expectedGeneratedCardRetirementIDs: Set<UUID> = [],
        expectedStudyResponseDeletionIDs: Set<UUID>,
        expectedSchemaImpactState: ItemTypeSchemaImpactState = .none,
        schemaChangeImpact: ItemTypeSchemaChangeImpact = .none
    ) {
        self.expectedOriginal = expectedOriginal
        self.expectedGeneratedCardRetirementIDs = expectedGeneratedCardRetirementIDs
        self.expectedStudyResponseDeletionIDs = expectedStudyResponseDeletionIDs
        self.expectedSchemaImpactState = expectedSchemaImpactState
        self.schemaChangeImpact = schemaChangeImpact
    }
}

/// Exact, workflow-only state behind a destructive schema-impact confirmation.
/// Empty and missing values are retained so a concurrent empty-to-populated
/// edit cannot reuse an earlier confirmation.
public struct ItemTypeSchemaImpactState: Sendable, Equatable {
    public struct ItemState: Sendable, Equatable {
        public let itemID: UUID
        public let fieldValues: [FieldValue]

        public init(itemID: UUID, fieldValues: [FieldValue]) {
            self.itemID = itemID
            self.fieldValues = fieldValues
        }
    }

    public let relevantFieldIDs: Set<UUID>
    public let items: [ItemState]

    public init(relevantFieldIDs: Set<UUID>, items: [ItemState]) {
        self.relevantFieldIDs = relevantFieldIDs
        self.items = items
    }

    public static let none = ItemTypeSchemaImpactState(relevantFieldIDs: [], items: [])
}

public enum ItemTypeUpdateError: LocalizedError, Sendable, Equatable {
    case staleDefinition(UUID)
    case generatedCardRetirementImpactChanged(expected: Int, actual: Int)
    case studyResponseImpactChanged(expected: Int, actual: Int)
    case schemaImpactChanged(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .staleDefinition:
            return "This item type changed after editing began. Reload it and review your changes again."
        case let .generatedCardRetirementImpactChanged(_, actual):
            let noun = actual == 1 ? "card" : "cards"
            return "Generated cards changed after confirmation. Saving would now retire \(actual) \(noun). Review the impact again."
        case let .studyResponseImpactChanged(_, actual):
            let noun = actual == 1 ? "response" : "responses"
            return "Private spoken responses changed after confirmation. Saving would now remove \(actual) \(noun). Review the impact again."
        case let .schemaImpactChanged(_, actual):
            let noun = actual == 1 ? "item" : "items"
            return "Item field contents changed after confirmation. Saving could now affect \(actual) \(noun). Review the impact again."
        }
    }
}

public extension ItemTypeSchemaChangeImpact {
    static let none = ItemTypeSchemaChangeImpact(
        affectedItemCount: 0,
        removedPopulatedFields: [],
        typeChangedPopulatedFields: []
    )
}
