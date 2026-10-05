/// The same study-eligible, library-wide count on every app icon.
public struct AppIconBadge: Sendable, Equatable {
    public let count: Int
    public var label: String? { count > 0 ? String(count) : nil }

    public init(dueCount: Int) {
        count = max(0, dueCount)
    }
}

public protocol AppIconBadgePublishing: Sendable {
    func publish(_ badge: AppIconBadge) async throws
}
