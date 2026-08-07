import NeoAnkiApplication
import Testing

@MainActor
struct AppSessionTests {
    @Test func presentationIsMutuallyExclusive() {
        let session = AppSession()
        session.show(.importItems)
        session.show(.syncIssues)
        #expect(session.presentation == .syncIssues)
        session.dismissPresentation(ifMatching: .importItems)
        #expect(session.presentation == .syncIssues)
        session.dismissPresentation(ifMatching: .syncIssues)
        #expect(session.presentation == nil)
    }

    @Test func dueCountCannotBecomeNegative() {
        let session = AppSession()
        session.updateDueCount(-10)
        #expect(session.dueCount == 0)
    }
}
