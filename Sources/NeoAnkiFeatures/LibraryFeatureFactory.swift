import Foundation
import NeoAnkiApplication
import NeoAnkiCore

/// Constructs shared workflows without vending repository capabilities to views.
/// Optional Studio support is resolved here, before presenting an editable screen.
@MainActor
public struct LibraryFeatureFactory {
    private let library: any LibraryRepository
    public let authoring: ItemTypeAuthoring
    public let deckCreation: NativeDeckCreation
    public let generatedDeckEditing: GeneratedDeckEditing

    public init(library: any LibraryRepository) {
        self.library = library
        authoring = .init(library: library)
        deckCreation = .init(library: library)
        generatedDeckEditing = .init(library: library)
    }
    public func makeItemTypesModel() -> ItemTypesFeatureModel? {
        guard let studio = library as? any LibraryBrowsing & LibraryItemTypeManaging
            & LibraryItemTypeEditingSafeguarding & LibraryItemTypeStudioSaving else { return nil }
        return ItemTypesFeatureModel(library: studio)
    }
    public func openItemType(id: UUID, deckID: UUID) async -> ItemTypesFeatureModel? {
        guard let model = makeItemTypesModel() else { return nil }
        model.destinationDeckID = deckID
        await model.load()
        model.selectItemType(id: id)
        if !model.isSelectedItemTypeReadOnly { model.beginEditingSelectedItemType() }
        return model
    }
    public func makeTypeChooser(deckID: UUID?) -> ItemTypeChooserFeatureModel {
        .init(authoring: authoring, deckID: deckID)
    }
    public func makeDeckItemTypes(deckID: UUID, onChanged: @escaping () async -> Void = {}) -> DeckItemTypesFeatureModel {
        .init(authoring: authoring, decks: library,
              safeguards: library as? any LibraryItemTypeEditingSafeguarding, deckID: deckID, onChanged: onChanged)
    }
    public func extraStudyAvailability(in scope: DeckScope) async throws -> Int {
        try await (library as? any LibraryExtraStudying)?.availableExtraStudyCardCount(scope: scope) ?? 0
    }

    public var personalVocabulary: (any PersonalVocabulary)? { library as? any PersonalVocabulary }
    public var vocabularyDecks: any LibraryDeckManaging { library }

    public func makeSavedResponses() -> SavedResponsesFeatureModel { .init(library: library) }
    public func makeStatistics(scope: DeckScope = .allDecks, sessionID: UUID? = nil) -> StatisticsFeatureModel {
        .init(library: library, scope: scope, sessionID: sessionID)
    }
    public func makeStatisticsWorkspace() -> StatisticsWorkspace {
        .init(library: library)
    }
    public func makeWordCapture(rootURL: URL, onSaved: @escaping @MainActor () async -> Void = {}) -> WordCaptureModel {
        .init(library: library, rootURL: rootURL, onSaved: onSaved)
    }
    public func makeLearnInContext(rootURL: URL, onSaved: @escaping @MainActor () async -> Void = {}) -> LearnInContextModel {
        .init(library: library, rootURL: rootURL, onSaved: onSaved)
    }
}
