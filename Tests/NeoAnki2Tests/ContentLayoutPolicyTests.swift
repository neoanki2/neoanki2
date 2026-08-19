import NeoAnkiApplication
import Testing

@testable import NeoAnki2

@Test func focusedDestinationsUseTheFullWindowInsteadOfTheLibrarySplitView() {
    #expect(!ContentLayoutPolicy.usesLibrarySplitView(for: .study(.allDecks)))
    #expect(!ContentLayoutPolicy.usesLibrarySplitView(for: .itemTypes))
}

@Test func libraryDestinationsRetainTheSidebar() {
    #expect(ContentLayoutPolicy.usesLibrarySplitView(for: .scopeHome))
    #expect(ContentLayoutPolicy.usesLibrarySplitView(for: .browse))
}
