import Foundation

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
