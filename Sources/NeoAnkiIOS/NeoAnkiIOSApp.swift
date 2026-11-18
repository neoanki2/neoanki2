#if os(iOS)
import NeoAnkiApplication
import NeoAnkiFeatures
import NeoAnkiVocabularyKit
import SwiftUI

/// Reusable mobile scene. The Xcode application target owns `@main`, signing,
/// capabilities, and lifecycle adapters.
public struct NeoAnkiMobileScene: View {
    @State private var model: LibraryFeatureModel
    private let vocabularyRootURL: URL
    private let fixtures: MobileUITestFixtures?
    private let packCloudTransport: (any VocabularyPackCloudTransport)?

    public init(model: LibraryFeatureModel, vocabularyRootURL: URL, packCloudTransport: (any VocabularyPackCloudTransport)? = nil, fixtures: MobileUITestFixtures? = nil) {
        _model = State(initialValue: model)
        self.vocabularyRootURL = vocabularyRootURL
        self.packCloudTransport = packCloudTransport
        self.fixtures = fixtures
    }

    public var body: some View {
        MobileRootView(model: model, vocabularyRootURL: vocabularyRootURL, packCloudTransport: packCloudTransport)
            .environment(\.mobileUITestFixtures, fixtures)
            .onOpenURL { _ = model.handle(url: $0) }
    }
}
#endif
