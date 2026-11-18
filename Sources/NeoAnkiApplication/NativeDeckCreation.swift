import Foundation
import NeoAnkiCore

/// Native generated creation and legacy bundle placement share the same command
/// boundary on both platforms. Platform views own only document access/lifetime.
public struct NativeDeckCreation: Sendable {
    private let library: any LibraryTransferring
    public init(library: any LibraryTransferring) { self.library = library }
    @MainActor
    public func create(_ prepared: PreparedAuthoredDeck, parentDeckID: UUID,
                       context: NativeCommandContext) async throws -> (result: PortableDeckImportResult, warnings: [String]) {
        try await NativeLibraryCommands.createGeneratedDeck(on: library,
            prepared: prepared, parentDeckID: parentDeckID, context: context)
    }
    @MainActor
    public func importGeneratedBundle(from source: URL, parentDeckID: UUID?) async throws -> PortableDeckImportResult {
        if let parentDeckID {
            return try await NativeLibraryCommands.createGeneratedDeck(on: library, source: source, parentDeckID: parentDeckID)
        }
        return try await NativeLibraryCommands.importDeck(on: library, source: source, authored: true)
    }
}
