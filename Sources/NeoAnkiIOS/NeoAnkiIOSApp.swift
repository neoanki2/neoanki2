#if os(iOS)
import NeoAnkiApplication
import NeoAnkiFeatures
import SwiftUI

/// Reusable mobile scene. The Xcode application target owns `@main`, signing,
/// capabilities, and lifecycle adapters.
public struct NeoAnkiMobileScene: View {
    @State private var model: LibraryFeatureModel
    private let vocabularyRootURL: URL

    public init(model: LibraryFeatureModel, vocabularyRootURL: URL) {
        _model = State(initialValue: model)
        self.vocabularyRootURL = vocabularyRootURL
    }

    public var body: some View {
        MobileRootView(model: model, vocabularyRootURL: vocabularyRootURL)
            .onOpenURL { _ = model.handle(url: $0) }
    }
}
#endif
