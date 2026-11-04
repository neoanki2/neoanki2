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
    private let packCloudTransport: (any VocabularyPackCloudTransport)?

    public init(model: LibraryFeatureModel, vocabularyRootURL: URL, packCloudTransport: (any VocabularyPackCloudTransport)? = nil) {
        _model = State(initialValue: model)
        self.vocabularyRootURL = vocabularyRootURL
        self.packCloudTransport = packCloudTransport
    }

    public var body: some View {
        MobileRootView(model: model, vocabularyRootURL: vocabularyRootURL, packCloudTransport: packCloudTransport)
            .onOpenURL { _ = model.handle(url: $0) }
    }
}
#endif
