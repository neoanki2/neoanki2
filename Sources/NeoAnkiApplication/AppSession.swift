import Foundation
import NeoAnkiCore
import Observation

/// The mutually exclusive content destination rendered by a platform shell.
public enum AppRoute: Sendable, Hashable {
    case scopeHome
    case browse
    case itemDetail(UUID)
    case addItem
    case editItem(UUID)
    case study(DeckScope)
    case itemTypes
}

/// A single modal destination prevents overlapping presentation booleans.
public enum AppPresentation: Sendable, Hashable, Identifiable {
    case importItems
    case deckBuilder
    case vocabularyPacks
    case vocabularyBuilder(deckID: UUID)
    case scheduling
    case syncIssues

    public var id: String {
        switch self {
        case .importItems: "import-items"
        case .deckBuilder: "deck-builder"
        case .vocabularyPacks: "vocabulary-packs"
        case let .vocabularyBuilder(deckID): "vocabulary-builder-\(deckID.uuidString)"
        case .scheduling: "scheduling"
        case .syncIssues: "sync-issues"
        }
    }
}

/// Shared, observable navigation and lifecycle state. Feature models are
/// attached through `FeatureRegistry` while their extraction proceeds; this
/// keeps platform shells independent of concrete persistence.
@MainActor @Observable
public final class AppSession {
    public var route: AppRoute
    public var presentation: AppPresentation?
    public private(set) var startupState: StartupState
    public private(set) var dueCount: Int
    public private(set) var syncStatus: SyncStatus
    public private(set) var syncIssues: [SyncIssue]

    public init(
        route: AppRoute = .scopeHome,
        presentation: AppPresentation? = nil,
        startupState: StartupState = .loading,
        dueCount: Int = 0,
        syncStatus: SyncStatus = .offline,
        syncIssues: [SyncIssue] = []
    ) {
        self.route = route
        self.presentation = presentation
        self.startupState = startupState
        self.dueCount = dueCount
        self.syncStatus = syncStatus
        self.syncIssues = syncIssues
    }

    public func show(_ presentation: AppPresentation) {
        self.presentation = presentation
    }

    public func dismissPresentation(ifMatching expected: AppPresentation? = nil) {
        guard expected == nil || presentation == expected else { return }
        presentation = nil
    }

    public func updateStartupState(_ state: StartupState) {
        startupState = state
    }

    public func updateDueCount(_ count: Int) {
        dueCount = max(0, count)
    }

    public func updateSync(status: SyncStatus, issues: [SyncIssue]? = nil) {
        syncStatus = status
        if let issues { syncIssues = issues }
    }
}

public enum StartupState: Sendable, Equatable {
    case loading
    case ready
    case failed(UserFacingError)
}
