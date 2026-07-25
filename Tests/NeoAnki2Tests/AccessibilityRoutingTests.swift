import Foundation
import Testing

@testable import NeoAnki2

@Test @MainActor func accessibilityRouterRoutesAnswerAndErrorsToExpectedFocus() {
    let router = AccessibilityRouter()
    let cardID = UUID()

    #expect(router.route(.answerRevealed(cardID: cardID)) == AccessibilityRoute(
        announcement: "Answer revealed.",
        focus: .answer
    ))
    #expect(router.route(.recordingError("Permission denied.")) == AccessibilityRoute(
        announcement: "Recording error. Permission denied.",
        focus: .recordingError
    ))
    #expect(router.route(.errorBanner("Import failed.")) == AccessibilityRoute(
        announcement: "Error. Import failed.",
        focus: .errorBanner
    ))
}

@Test @MainActor func accessibilityRouterSuppressesOnlyDuplicateConsecutiveEvents() {
    let router = AccessibilityRouter()
    let event = AccessibilityEvent.errorBanner("Try again.")

    #expect(router.route(event) != nil)
    #expect(router.route(event) == nil)
    #expect(router.route(.errorBanner("Choose another file.")) != nil)
    #expect(router.route(event) != nil)
}
