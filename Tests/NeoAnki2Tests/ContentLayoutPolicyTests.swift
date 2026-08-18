import NeoAnkiApplication
import Testing

@testable import NeoAnki2

@Test func studyUsesTheFullWindowInsteadOfTheLibrarySplitView() {
    #expect(!ContentLayoutPolicy.usesLibrarySplitView(for: .study(.allDecks)))
}

@Test func libraryDestinationsRetainTheSidebar() {
    #expect(ContentLayoutPolicy.usesLibrarySplitView(for: .scopeHome))
    #expect(ContentLayoutPolicy.usesLibrarySplitView(for: .browse))
    #expect(ContentLayoutPolicy.usesLibrarySplitView(for: .itemTypes))
}
