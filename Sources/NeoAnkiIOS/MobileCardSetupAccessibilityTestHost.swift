#if os(iOS)
import NeoAnkiFeatures
import SwiftUI

/// A deterministic entry point for the isolated Card setup accessibility
/// matrix. The application exposes it only behind an explicit UI-test launch
/// argument; normal launches continue through the adaptive mobile shell.
public struct MobileCardSetupAccessibilityTestHost: View {
    @State private var libraryModel: LibraryFeatureModel
    @State private var studioModel: ItemTypesFeatureModel?
    @State private var isPreparing = false
    @State private var errorMessage: String?

    public init(model: LibraryFeatureModel) {
        _libraryModel = State(initialValue: model)
    }

    public var body: some View {
        NavigationStack {
            Group {
                if let studioModel {
                    ItemTypeStudioMobileView(
                        model: studioModel,
                        reloadLibrary: { try await libraryModel.reload() },
                        initialCardSetupID: MobileItemTypeStudioUITestSeeder.legacyCardSetupID
                    )
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Card Setup Fixture Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else {
                    ProgressView("Opening Card setup…")
                }
            }
        }
        .task { await prepareFixture() }
    }

    private func prepareFixture() async {
        guard !isPreparing, studioModel == nil, errorMessage == nil else { return }
        isPreparing = true
        defer { isPreparing = false }

        await libraryModel.bootstrap(startSync: false)
        do {
            try await MobileItemTypeStudioUITestSeeder.seedIfRequested(
                library: libraryModel.library
            )
            guard let studioLibrary = libraryModel.itemTypeStudioLibrary else {
                throw MobileCardSetupAccessibilityTestHostError.studioUnavailable
            }
            let preparedModel = ItemTypesFeatureModel(library: studioLibrary)
            await preparedModel.load()
            preparedModel.selectItemType(id: MobileItemTypeStudioUITestSeeder.legacyItemTypeID)
            guard preparedModel.beginEditingSelectedItemType() else {
                throw MobileCardSetupAccessibilityTestHostError.fixtureUnavailable
            }
            studioModel = preparedModel
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum MobileCardSetupAccessibilityTestHostError: LocalizedError {
    case studioUnavailable
    case fixtureUnavailable

    var errorDescription: String? {
        switch self {
        case .studioUnavailable:
            "Item Type Studio is unavailable in this test repository."
        case .fixtureUnavailable:
            "The seeded Studio Legacy Fixture could not be opened."
        }
    }
}
#endif
