import Foundation
import NeoAnkiCore

public protocol Clock: Sendable {
    var now: Date { get }
}

public struct SystemClock: Clock {
    public init() {}
    public var now: Date { .now }
}

public struct FixedClock: Clock {
    public let now: Date
    public init(now: Date) { self.now = now }
}

public protocol PreferencesService: Sendable {
    func bool(for key: String) async -> Bool?
    func set(_ value: Bool, for key: String) async
}

/// Device-local mobile preferences. These values deliberately live outside
/// the synchronized library database so each device can choose independently.
public protocol MobileSettingsStoring: Sendable {
    func loadSyncEnabled() async -> Bool
    func saveSyncEnabled(_ enabled: Bool) async
    func loadReminderSettings() async -> ReminderSettings
    func saveReminderSettings(_ settings: ReminderSettings) async
}

public actor VolatileMobileSettingsStore: MobileSettingsStoring {
    private var syncEnabled: Bool
    private var reminderSettings: ReminderSettings

    public init(syncEnabled: Bool = false, reminderSettings: ReminderSettings = .init()) {
        self.syncEnabled = syncEnabled
        self.reminderSettings = reminderSettings
    }

    public func loadSyncEnabled() async -> Bool { syncEnabled }
    public func saveSyncEnabled(_ enabled: Bool) async { syncEnabled = enabled }
    public func loadReminderSettings() async -> ReminderSettings { reminderSettings }
    public func saveReminderSettings(_ settings: ReminderSettings) async { reminderSettings = settings }
}

public protocol DocumentAccessService: Sendable {
    func openDocument(allowedContentTypes: [String]) async throws -> URL?
    func saveDocument(suggestedName: String, contentType: String) async throws -> URL?
    func withSecurityScopedAccess<T: Sendable>(
        to url: URL,
        operation: @Sendable (URL) async throws -> T
    ) async throws -> T
}

public protocol AudioService: Sendable {
    func play(url: URL) async throws
    func beginRecording() async throws
    func finishRecording() async throws -> URL
    func cancelRecording() async
}

public struct PickedMedia: Sendable, Equatable {
    public let url: URL
    public let contentType: String
    public let suggestedFilename: String?

    public init(url: URL, contentType: String, suggestedFilename: String? = nil) {
        self.url = url
        self.contentType = contentType
        self.suggestedFilename = suggestedFilename
    }
}

public enum MediaCaptureKind: String, Codable, CaseIterable, Sendable {
    case image
    case video
    case audio
}

public protocol MediaCaptureService: Sendable {
    func pickMedia(kinds: Set<MediaCaptureKind>) async throws -> PickedMedia?
    func captureMedia(kind: MediaCaptureKind) async throws -> PickedMedia?
    func discardTemporaryMedia(at url: URL) async
}

public protocol NotificationSchedulingService: Sendable {
    func authorizationStatus() async -> NotificationAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func replaceDailyReminder(_ request: DailyReminderRequest?) async throws
}

public enum NotificationAuthorizationStatus: String, Codable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
}

public protocol WidgetSnapshotPublishing: Sendable {
    func publish(_ snapshot: DueWidgetSnapshot) async throws
}

public protocol BackgroundRefreshScheduling: Sendable {
    func register() async
    func scheduleNextRefresh(earliestBeginDate: Date) async throws
}

public protocol DocumentSharingService: Sendable {
    func share(url: URL, subject: String?) async throws
}

public enum ReminderScope: Codable, Sendable, Equatable, Hashable {
    case allDecks
    case deck(UUID)

    public var deckScope: DeckScope {
        switch self {
        case .allDecks: .allDecks
        case let .deck(id): .deck(id)
        }
    }
}

public struct ReminderSettings: Codable, Sendable, Equatable {
    public var isEnabled: Bool
    public var hour: Int
    public var minute: Int
    public var scope: ReminderScope

    public init(isEnabled: Bool = false, hour: Int = 19, minute: Int = 0, scope: ReminderScope = .allDecks) {
        self.isEnabled = isEnabled
        self.hour = min(23, max(0, hour))
        self.minute = min(59, max(0, minute))
        self.scope = scope
    }
}

public struct DailyReminderRequest: Codable, Sendable, Equatable {
    public let hour: Int
    public let minute: Int
    public let scope: ReminderScope
    public let dueCount: Int

    public init(hour: Int, minute: Int, scope: ReminderScope, dueCount: Int) {
        self.hour = hour
        self.minute = minute
        self.scope = scope
        self.dueCount = max(0, dueCount)
    }
}

public struct DueWidgetDeckSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let dueCount: Int
    public let nextDueAt: Date?

    public init(id: UUID, name: String, dueCount: Int, nextDueAt: Date?) {
        self.id = id
        self.name = name
        self.dueCount = max(0, dueCount)
        self.nextDueAt = nextDueAt
    }
}

public struct DueWidgetSnapshot: Codable, Sendable, Equatable {
    public let totalDueCount: Int
    public let nextDueAt: Date?
    public let decks: [DueWidgetDeckSummary]
    public let updatedAt: Date

    public init(totalDueCount: Int, nextDueAt: Date?, decks: [DueWidgetDeckSummary], updatedAt: Date = .now) {
        self.totalDueCount = max(0, totalDueCount)
        self.nextDueAt = nextDueAt
        self.decks = Array(decks.prefix(3))
        self.updatedAt = updatedAt
    }
}

public struct RuntimeConfiguration: Sendable, Equatable {
    public var isAutomatedTesting: Bool
    public var enablesCloudSync: Bool
    public var initialRoute: AppRoute

    public init(
        isAutomatedTesting: Bool = false,
        enablesCloudSync: Bool = true,
        initialRoute: AppRoute = .scopeHome
    ) {
        self.isAutomatedTesting = isAutomatedTesting
        self.enablesCloudSync = enablesCloudSync
        self.initialRoute = initialRoute
    }
}

public struct UserFacingError: Error, Sendable, Equatable {
    public let title: String
    public let message: String
    public let recoverySuggestion: String?

    public init(title: String, message: String, recoverySuggestion: String? = nil) {
        self.title = title
        self.message = message
        self.recoverySuggestion = recoverySuggestion
    }
}

public protocol UserFacingErrorMapping: Sendable {
    func map(_ error: any Error) -> UserFacingError
}

public struct DefaultUserFacingErrorMapper: UserFacingErrorMapping {
    public init() {}

    public func map(_ error: any Error) -> UserFacingError {
        UserFacingError(
            title: "NeoAnki couldn’t complete that action",
            message: String(describing: error),
            recoverySuggestion: "Your library has not been replaced. Try again, or review Sync Issues if this came from another device."
        )
    }
}
