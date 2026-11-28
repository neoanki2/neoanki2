import Foundation

/// Columns use the same field definitions and values as the rest of an item.
/// A nil sharedRows means each item supplies its own rows.
public struct ItemList: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var columns: [FieldDef]
    public var sharedRows: [ItemListRow]?

    public init(id: UUID = UUID(), name: String, columns: [FieldDef], sharedRows: [ItemListRow]? = nil) {
        self.id = id
        self.name = name
        self.columns = columns
        self.sharedRows = sharedRows
    }

    public func rows(in item: Item) -> [ItemListRow] {
        if let sharedRows { return sharedRows }
        guard case let .rows(rows)? = item.value(for: id) else { return [] }
        return rows
    }
}

public struct ItemListRow: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var values: [FieldValue]

    public init(id: UUID = UUID(), values: [FieldValue] = []) {
        self.id = id
        self.values = values
    }
}

public struct CardRowSelection: Codable, Equatable, Hashable, Sendable {
    public let listID: UUID
    public let rowID: UUID

    public init(listID: UUID, rowID: UUID) {
        self.listID = listID
        self.rowID = rowID
    }
}

public enum PromptFormat: String, Codable, CaseIterable, Sendable {
    case standard, cloze, imageOcclusion
}

public enum ResponseMode: String, Codable, CaseIterable, Sendable {
    case onYourOwn, type, choose, arrange, record, audioSubmission
}

public struct CardCreation: Codable, Equatable, Sendable {
    public var listIDs: [UUID]
    public var startSuspended: Bool
    public var checkedFieldIDs: [UUID]?

    public init(listIDs: [UUID] = [], startSuspended: Bool = false, checkedFieldIDs: [UUID] = []) {
        self.listIDs = listIDs
        self.startSuspended = startSuspended
        self.checkedFieldIDs = checkedFieldIDs.isEmpty ? nil : checkedFieldIDs
    }
}

/// Shared by save, dry run and reconciliation. List order changes presentation
/// order, while the selected row for each list remains the same coordinate.
public struct CardGenerationKey: Hashable, Sendable {
    public let templateID: UUID
    public let clozeGroup: Int?
    public let occlusionGroup: Int?
    public let rows: [CardRowSelection]

    public init(_ card: Card) {
        templateID = card.templateID
        clozeGroup = card.clozeGroup
        occlusionGroup = card.occlusionGroup
        rows = card.rowSelections.sorted { $0.listID.uuidString < $1.listID.uuidString }
    }
}

public struct CardCreationPreview: Equatable, Sendable {
    public let kept: Int
    public let added: Int
    public let retired: Int
    public let addedSuspended: Int

    public init(kept: Int = 0, added: Int = 0, retired: Int = 0, addedSuspended: Int = 0) {
        self.kept = kept
        self.added = added
        self.retired = retired
        self.addedSuspended = addedSuspended
    }

    public static func + (left: Self, right: Self) -> Self {
        Self(kept: left.kept + right.kept, added: left.added + right.added,
             retired: left.retired + right.retired, addedSuspended: left.addedSuspended + right.addedSuspended)
    }

    public init(existing: [Card], desired: [Card]) {
        let existingKeys = Set(existing.map(CardGenerationKey.init))
        let desiredKeys = Set(desired.map(CardGenerationKey.init))
        let additions = desired.filter { !existingKeys.contains(CardGenerationKey($0)) }
        kept = existingKeys.intersection(desiredKeys).count
        added = additions.count
        retired = existingKeys.subtracting(desiredKeys).count
        addedSuspended = additions.filter(\.isSuspended).count
    }
}
