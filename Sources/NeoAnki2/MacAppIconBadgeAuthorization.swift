import OSLog
import UserNotifications

enum MacAppIconBadgeAuthorization {
    private static let logger = Logger(subsystem: "com.neoanki2.app", category: "AppIconBadge")

    static func request() async throws -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        logger.info("Badge settings: authorization=\(settings.authorizationStatus.rawValue, privacy: .public), badge=\(settings.badgeSetting.rawValue, privacy: .public)")
        guard settings.authorizationStatus != .denied else { return false }
        // Alert/sound authorization does not imply badge authorization. Ask
        // for badges explicitly even when another notification type is allowed.
        let granted = try await center.requestAuthorization(options: [.badge])
        let updated = await center.notificationSettings()
        logger.info("Badge permission completed: granted=\(granted, privacy: .public), badge=\(updated.badgeSetting.rawValue, privacy: .public)")
        return granted
    }
}
