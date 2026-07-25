import AppKit
import Foundation

enum AccessibilityEvent: Hashable {
    case answerRevealed(cardID: UUID)
    case recordingError(String)
    case errorBanner(String)
}

struct AccessibilityRoute: Equatable {
    enum Focus: Equatable {
        case answer
        case recordingError
        case errorBanner
    }

    let announcement: String
    let focus: Focus
}

@MainActor
final class AccessibilityRouter {
    private var lastEvent: AccessibilityEvent?

    func route(_ event: AccessibilityEvent) -> AccessibilityRoute? {
        guard event != lastEvent else { return nil }
        lastEvent = event
        switch event {
        case .answerRevealed:
            return AccessibilityRoute(announcement: "Answer revealed.", focus: .answer)
        case let .recordingError(message):
            return AccessibilityRoute(announcement: "Recording error. \(message)", focus: .recordingError)
        case let .errorBanner(message):
            return AccessibilityRoute(announcement: "Error. \(message)", focus: .errorBanner)
        }
    }
}

@MainActor
final class AccessibilityNotifier {
    static let shared = AccessibilityNotifier()
    private let router = AccessibilityRouter()

    @discardableResult
    func post(_ event: AccessibilityEvent) -> AccessibilityRoute? {
        guard let route = router.route(event) else { return nil }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: route.announcement,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
        return route
    }
}
