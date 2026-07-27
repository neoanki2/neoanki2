import Foundation

extension ItemStore {
    /// Corrupts a persisted item type definition for UI testing only.
    public func testingCorruptItemTypeDefinition(id: UUID) async throws {
        try await database.replaceItemTypeDefinition(
            id: id,
            with: Data(#"{"templates":[{"broken":true}]}"#.utf8)
        )
    }
}
