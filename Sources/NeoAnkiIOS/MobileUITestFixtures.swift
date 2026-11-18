#if os(iOS)
import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import SwiftUI

/// Explicit fixture dependency composed by the app root. Presentation receives
/// scenario operations, never the repository used to seed an isolated test library.
public struct MobileUITestFixtures: Sendable {
    private let library: any LibraryRepository
    public init(library: any LibraryRepository) { self.library = library }
    @MainActor func prepareStudio() async throws {
        try await MobileItemTypeStudioUITestSeeder.seedIfRequested(library: library)
    }
    @MainActor func prepareRedesign() async throws {
        try await MobileRedesignUITestSeeder.seedIfRequested(library: library)
    }
    @MainActor func prepareVocabulary(_ model: MobileVocabularyLibraryModel) async throws {
        try await model.seedVisualFixtureIfRequested(library: library)
    }
    func createOcclusionType(_ type: ItemType) async throws { _ = try await library.createItemType(type) }
    func reserveOcclusionImage(_ data: Data) async throws -> MediaRef {
        try await library.reserveMedia(data: data, kind: .image, altText: "", asOf: .now).reference
    }
    func saveOcclusionItem(_ item: Item, isNew: Bool) async throws {
        if isNew { _ = try await library.createItem(item, asOf: .now) }
        else { _ = try await library.updateItem(item, asOf: .now) }
    }
}
private struct MobileUITestFixturesKey: EnvironmentKey {
    static let defaultValue: MobileUITestFixtures? = nil
}
public extension EnvironmentValues {
    var mobileUITestFixtures: MobileUITestFixtures? {
        get { self[MobileUITestFixturesKey.self] }
        set { self[MobileUITestFixturesKey.self] = newValue }
    }
}
#endif
