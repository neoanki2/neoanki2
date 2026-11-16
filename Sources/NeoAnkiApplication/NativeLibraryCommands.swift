import Foundation
import NeoAnkiCore

/// Optional additive capability. Older API/test adapters remain source compatible.
public protocol LibraryNativeCommandSupporting: Sendable {
    func moveItems(_ selection: [ItemMoveSelection], to deckID: UUID?) async throws -> Int
    func importItems(_ data: Data, format: NativeImportFormat, itemTypeID: UUID?,
        destinationDeckID: UUID?, context: ImportContext, asOf: Date) async throws -> [SavedItemSummary]
    func deleteItemsAtomically(_ ids: Set<UUID>, asOf: Date) async throws -> Int
    func nativeCommandReceipt(_ context: NativeCommandContext) async throws -> NativeCommandReceipt?
}

public enum NativeImportFormat: Sendable {
    case json
    case csv(itemTypeName: String)
}

extension SQLiteLibraryRepository: LibraryNativeCommandSupporting {
    public func moveItems(_ selection: [ItemMoveSelection], to deckID: UUID?) async throws -> Int {
        try await store.moveItems(selection, to: deckID)
    }
    public func importItems(_ data: Data, format: NativeImportFormat, itemTypeID: UUID?,
        destinationDeckID: UUID?, context: ImportContext, asOf: Date) async throws -> [SavedItemSummary] {
        switch format {
        case .json:
            try await store.importItemSummaries(from: data, adapter: JSONImportAdapter(),
                itemTypeID: itemTypeID, context: context, destinationDeckID: destinationDeckID, now: asOf)
        case let .csv(name):
            try await store.importItemSummaries(from: data, adapter: CSVImportAdapter(itemTypeName: name),
                itemTypeID: itemTypeID, context: context, destinationDeckID: destinationDeckID, now: asOf)
        }
    }
    public func deleteItemsAtomically(_ ids: Set<UUID>, asOf: Date) async throws -> Int {
        try await store.deleteItemsAtomically(ids, now: asOf)
    }
    public func nativeCommandReceipt(_ context: NativeCommandContext) async throws -> NativeCommandReceipt? {
        try await store.nativeCommandReceipt(context)
    }
}

/// A successful write remains successful when a subsequent read or OS publisher
/// fails. The caller can refresh again using the receipt without repeating writes.
public struct CommandOutcome<Value: Sendable>: Sendable {
    public let value: Value?
    public let receipt: NativeCommandReceipt?
    public let warnings: [String]
    public var affectedCount: Int? { receipt?.affectedCount }
}

public struct NativeCommandConfirmationUnavailable: Error, LocalizedError, Sendable {
    public let commandID: UUID
    public var errorDescription: String? {
        "The save status could not be confirmed. Refresh the library before repeating this operation."
    }
}

public enum NativeLibraryCommands {
    @MainActor
    public static func perform<Value: Sendable>(
        on repository: any Sendable,
        context: NativeCommandContext,
        operation: () async throws -> Value
    ) async throws -> CommandOutcome<Value> {
        let durable = repository as? any LibraryNativeCommandSupporting
        if let receipt = try await durable?.nativeCommandReceipt(context) {
            return CommandOutcome(value: nil, receipt: receipt, warnings: [])
        }
        do {
            let value = try await NativeCommandContext.$current.withValue(context) { try await operation() }
            // Receipt lookup is a refresh, never the definition of write success.
            do {
                let receipt = try await durable?.nativeCommandReceipt(context)
                return CommandOutcome(value: value, receipt: receipt, warnings: [])
            } catch {
                return CommandOutcome(value: value, receipt: nil,
                    warnings: ["Saved. The confirmation could not be refreshed: \(error.localizedDescription)"])
            }
        } catch let completed as NativeCommandAlreadyCommitted {
            return CommandOutcome(value: nil, receipt: completed.receipt, warnings: [])
        } catch {
            let receipt: NativeCommandReceipt?
            do { receipt = try await durable?.nativeCommandReceipt(context) }
            catch { throw NativeCommandConfirmationUnavailable(commandID: context.id) }
            if let receipt {
                return CommandOutcome(value: nil, receipt: receipt,
                    warnings: ["Saved. Refresh could not finish: \(error.localizedDescription)"])
            }
            throw error
        }
    }

    @MainActor
    public static func importDeck(on repository: any LibraryTransferring, source: URL,
        authored: Bool, conflict: PortableDeckTypeConflictResolution = .reject,
        context: NativeCommandContext? = nil) async throws -> PortableDeckImportResult {
        let context = context ?? NativeCommandContext(operation: authored ? "import-authored" : "import-portable",
            input: Data(source.standardizedFileURL.path.utf8))
        let outcome = try await perform(on: repository, context: context) {
            if authored { return try await repository.importAuthoredDeck(from: source) }
            return try await repository.importPortableDeck(from: source, conflictResolution: conflict)
        }
        if let result = outcome.value { return result }
        guard let data = outcome.receipt?.resultData else { throw DatabaseError.decodingFailed }
        return try JSONDecoder().decode(PortableDeckImportResult.self, from: data)
    }

    public static func selection(_ ids: Set<UUID>, rows: [SavedItemSummary]) throws -> [ItemMoveSelection] {
        let selected = rows.filter { ids.contains($0.id) }
        guard selected.count == ids.count else {
            throw DatabaseError.invalidItem("The selection changed. Refresh and select the items again.")
        }
        return selected.map { ItemMoveSelection(itemID: $0.id, expectedDeckID: $0.deckID) }
    }

    public static func move(on repository: any LibraryBrowsing & LibraryItemMutating,
        selection: [ItemMoveSelection], to deckID: UUID?) async throws -> Int {
        guard let native = repository as? any LibraryNativeCommandSupporting else {
            throw DatabaseError.invalidItem("This library cannot move a selection atomically.")
        }
        return try await native.moveItems(selection, to: deckID)
    }

    public static func delete(on repository: any LibraryItemMutating, ids: Set<UUID>, asOf: Date) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        if let native = repository as? any LibraryNativeCommandSupporting {
            return try await native.deleteItemsAtomically(ids, asOf: asOf)
        }
        // Compatibility adapters retain the existing public bulk contract.
        let operations = ids.sorted { $0.uuidString < $1.uuidString }.map {
            ItemBulkOperation(operationID: "delete-\($0)", action: .delete($0))
        }
        return try await repository.performBulkItemOperations(operations, asOf: asOf).count
    }

    public static func importItems(on repository: any LibraryImporting, data: Data,
        format: NativeImportFormat, itemTypeID: UUID?, deckID: UUID?,
        context: ImportContext, asOf: Date) async throws -> [SavedItemSummary] {
        if let native = repository as? any LibraryNativeCommandSupporting {
            return try await native.importItems(data, format: format, itemTypeID: itemTypeID,
                destinationDeckID: deckID, context: context, asOf: asOf)
        }
        guard deckID == nil else {
            throw DatabaseError.invalidItem("This library cannot import into a deck atomically.")
        }
        switch format {
        case .json:
            return try await repository.importJSONItems(from: data, itemTypeID: itemTypeID, context: context, asOf: asOf)
        case let .csv(name):
            return try await repository.importCSVItems(from: data, itemTypeID: itemTypeID,
                itemTypeName: name, context: context, asOf: asOf)
        }
    }
}

/// Separate capability keeps existing transfer adapters source compatible.
public protocol LibraryGeneratedDeckCreating: Sendable {
    func createGeneratedDeck(from source: URL, parentDeckID: UUID) async throws -> PortableDeckImportResult
    func createGeneratedDeck(_ prepared: PreparedAuthoredDeck, parentDeckID: UUID) async throws -> PortableDeckImportResult
}

extension SQLiteLibraryRepository: LibraryGeneratedDeckCreating {
    public func createGeneratedDeck(from source: URL, parentDeckID: UUID) async throws -> PortableDeckImportResult {
        try await AuthoredDeck.importDeck(from: source, into: store, parentDeckID: parentDeckID)
    }

    public func createGeneratedDeck(_ prepared: PreparedAuthoredDeck, parentDeckID: UUID) async throws -> PortableDeckImportResult {
        try await AuthoredDeck.importPrepared(prepared, into: store, parentDeckID: parentDeckID)
    }
}

public extension NativeLibraryCommands {
    @MainActor
    static func createGeneratedDeck(on repository: any Sendable, source: URL,
        parentDeckID: UUID) async throws -> PortableDeckImportResult {
        guard let native = repository as? any LibraryGeneratedDeckCreating else {
            throw DatabaseError.invalidItem("This library cannot create a generated deck atomically.")
        }
        let context = NativeCommandContext(operation: "create-generated-bundle",
            input: Data((source.standardizedFileURL.path + ":" + parentDeckID.uuidString).utf8))
        let outcome = try await perform(on: repository, context: context) {
            try await native.createGeneratedDeck(from: source, parentDeckID: parentDeckID)
        }
        if let value = outcome.value { return value }
        guard let data = outcome.receipt?.resultData else { throw DatabaseError.decodingFailed }
        return try JSONDecoder().decode(PortableDeckImportResult.self, from: data)
    }

    @MainActor
    static func createGeneratedDeck(on repository: any Sendable, prepared: PreparedAuthoredDeck,
        parentDeckID: UUID, context: NativeCommandContext) async throws -> (result: PortableDeckImportResult, warnings: [String]) {
        guard let native = repository as? any LibraryGeneratedDeckCreating else {
            throw DatabaseError.invalidItem("This library cannot create a generated deck atomically.")
        }
        let outcome = try await perform(on: repository, context: context) {
            try await native.createGeneratedDeck(prepared, parentDeckID: parentDeckID)
        }
        if let value = outcome.value { return (value, outcome.warnings) }
        guard let data = outcome.receipt?.resultData else { throw DatabaseError.decodingFailed }
        return (try JSONDecoder().decode(PortableDeckImportResult.self, from: data), outcome.warnings)
    }
}
