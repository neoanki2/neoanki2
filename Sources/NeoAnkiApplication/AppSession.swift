import Foundation
import NeoAnkiCore
import Observation

/// The mutually exclusive content destination rendered by a platform shell.
public enum AppSection: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {
    case home
    case library
    case create
    case settings

    public var id: Self { self }
}

public enum AppRoute: Sendable, Hashable {
    case scopeHome
    case scope(DeckScope)
    case browse
    case itemDetail(UUID)
    case addItem
    case editItem(UUID)
    case moveItem(UUID)
    case study(DeckScope)
    case itemTypes
    case itemType(UUID)
    case templates(itemTypeID: UUID)
    case template(itemTypeID: UUID, templateID: UUID)
    case imports
    case builders
    case vocabularyPacks
    case savedResponses
    case scheduling
    case syncIssues
    case settings
}

/// A single modal destination prevents overlapping presentation booleans.
public enum AppPresentation: Sendable, Hashable, Identifiable {
    case importItems
    case exportDeck(UUID)
    case deckBuilder
    case poemBuilder
    case vocabularyPacks
    case vocabularyBuilder(deckID: UUID)
    case scheduling
    case syncIssues
    case reminderEditor
    case syncOnboarding

    public var id: String {
        switch self {
        case .importItems: "import-items"
        case let .exportDeck(deckID): "export-deck-\(deckID.uuidString)"
        case .deckBuilder: "deck-builder"
        case .poemBuilder: "poem-builder"
        case .vocabularyPacks: "vocabulary-packs"
        case let .vocabularyBuilder(deckID): "vocabulary-builder-\(deckID.uuidString)"
        case .scheduling: "scheduling"
        case .syncIssues: "sync-issues"
        case .reminderEditor: "reminder-editor"
        case .syncOnboarding: "sync-onboarding"
        }
    }
}

public enum AppDeepLink: Sendable, Equatable {
    case scope(DeckScope)
    case item(UUID)
    case study(DeckScope)

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "neoanki2" else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let values: [String: String] = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).compactMap {
            guard let value = $0.value else { return nil }
            return ($0.name, value)
        })
        switch url.host?.lowercased() {
        case "item":
            guard let rawID = values["id"] ?? url.pathComponents.dropFirst().first,
                  let id = UUID(uuidString: rawID)
            else { return nil }
            self = .item(id)
        case "scope", "study":
            let scope: DeckScope
            switch values["kind"] {
            case "unassigned": scope = .unassigned
            case "deck":
                guard let rawID = values["id"], let id = UUID(uuidString: rawID) else { return nil }
                scope = .deck(id, includeDescendants: values["descendants"] != "false")
            default: scope = .allDecks
            }
            self = url.host?.lowercased() == "study" ? .study(scope) : .scope(scope)
        default:
            return nil
        }
    }

    public var route: AppRoute {
        switch self {
        case let .scope(scope): .scope(scope)
        case let .item(id): .itemDetail(id)
        case let .study(scope): .study(scope)
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
