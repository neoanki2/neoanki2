import Foundation
import NeoAnkiApplication
import NeoAnkiCore

/// Identifies a sidebar row in the deck navigator.
enum SidebarSelection: Hashable, Sendable {
    case allDecks
    case unassigned
    case deck(UUID)
}

/// Study and list scope derived from sidebar selection.
struct StudyScope: Sendable, Equatable {
    var filter: DeckScope
    var label: String

    static let allDecks = StudyScope(filter: .allDecks, label: "All Decks")
    static let unassigned = StudyScope(filter: .unassigned, label: "Unassigned")

    static func deck(_ id: UUID, name: String, includeDescendants: Bool = true) -> StudyScope {
        StudyScope(
            filter: .deck(id, includeDescendants: includeDescendants),
            label: name
        )
    }
}

@MainActor
@Observable
final class DecksModel {
    private(set) var deckTree: [DeckNode] = []
    private(set) var summaries: [DeckSummary] = []
    private(set) var allDecksDueCount = 0
    private(set) var unassignedDueCount = 0
    private(set) var unassignedItemCount = 0
    /// True only until the sidebar first has something to show. Later reloads
    /// revise the counts in place, because replacing the tree the learner is
    /// pointing at with a progress view loses their place to say nothing new.
    private(set) var isLoading = true
    private(set) var errorMessage: String?

    private var hasLoaded = false
    var needsInitialLoad: Bool { !hasLoaded }

    var selectedScope: SidebarSelection = .allDecks

    let library: any LibraryBrowsing & LibraryDeckManaging

    init(library: any LibraryBrowsing & LibraryDeckManaging) {
        self.library = library
    }

    var studyScope: StudyScope {
        switch selectedScope {
        case .allDecks:
            return .allDecks
        case .unassigned:
            return .unassigned
        case let .deck(id):
            let name = summaries.first(where: { $0.id == id })?.name ?? "Deck"
            return .deck(id, name: name)
        }
    }

    var scopeDueCount: Int {
        switch selectedScope {
        case .allDecks:
            allDecksDueCount
        case .unassigned:
            unassignedDueCount
        case let .deck(id):
            summaries.first(where: { $0.id == id })?.dueCount ?? 0
        }
    }

    var selectedDeckID: UUID? {
        if case let .deck(id) = selectedScope { return id }
        return nil
    }

    var defaultDeckIDForNewItem: UUID? {
        selectedDeckID
    }

    /// Every count in one reload is measured against the same instant, so the
    /// sidebar totals cannot drift from the detail pane's.
    func load(asOf now: Date = .now) async {
        isLoading = !hasLoaded
        errorMessage = nil
        do {
            try await applyCounts(asOf: now)
            hasLoaded = true
        } catch {
            errorMessage = UserFacingError.message(from: error)
        }
        isLoading = false
    }

    func applyColdSnapshot(_ snapshot: ColdLibrarySnapshot) {
        summaries = snapshot.deckSummaries
        deckTree = DeckTree.build(from: summaries)
        allDecksDueCount = snapshot.allDecksSummary.dueNow
        unassignedDueCount = snapshot.unassignedSummary.dueNow
        unassignedItemCount = snapshot.unassignedSummary.itemCount
        if case let .deck(id) = selectedScope,
           !summaries.contains(where: { $0.id == id }) {
            selectedScope = .allDecks
        }
        errorMessage = nil
        hasLoaded = true
        isLoading = false
    }

    func applyColdHomeSnapshot(_ snapshot: ColdLibraryHomeSnapshot) {
        summaries = snapshot.deckSummaries
        deckTree = DeckTree.build(from: summaries)
        allDecksDueCount = snapshot.allDecksSummary.dueNow
        unassignedDueCount = snapshot.unassignedSummary.dueNow
        unassignedItemCount = snapshot.unassignedSummary.itemCount
        if case let .deck(id) = selectedScope,
           !summaries.contains(where: { $0.id == id }) {
            selectedScope = .allDecks
        }
        errorMessage = nil
        hasLoaded = true
        isLoading = false
    }

    /// Revises the counts alone, leaving `isLoading` and the error banner
    /// untouched. What is due changes on a schedule and after every save, so
    /// this runs often; anything that made the sidebar flicker would run often
    /// too. A failure here keeps the previous numbers rather than interrupting.
    func refreshCounts(asOf now: Date = .now) async {
        guard hasLoaded else { return }
        try? await applyCounts(asOf: now)
    }

    /// Loads the sidebar on first presentation and otherwise takes the
    /// non-flickering count refresh path.
    func loadOrRefresh(asOf now: Date = .now) async {
        if hasLoaded {
            await refreshCounts(asOf: now)
        } else {
            await load(asOf: now)
        }
    }

    /// Reads every count before assigning any, so the sidebar never renders a
    /// half-updated set, and assigns only what changed, so an unchanged library
    /// costs no view updates.
    private func applyCounts(asOf now: Date) async throws {
        let loadedSummaries = try await library.deckSummaries(asOf: now)
        let allDecksSummary = try await library.scopeSummary(
            scope: .allDecks,
            asOf: now
        )
        let unassignedSummary = try await library.scopeSummary(
            scope: .unassigned,
            asOf: now
        )
        let allDecksDue = allDecksSummary.dueNow
        let unassignedDue = unassignedSummary.dueNow
        let unassignedItems = unassignedSummary.itemCount

        if summaries != loadedSummaries {
            summaries = loadedSummaries
            deckTree = DeckTree.build(from: loadedSummaries)
        }
        if allDecksDueCount != allDecksDue {
            allDecksDueCount = allDecksDue
        }
        if unassignedDueCount != unassignedDue {
            unassignedDueCount = unassignedDue
        }
        if unassignedItemCount != unassignedItems {
            unassignedItemCount = unassignedItems
        }

        if case let .deck(id) = selectedScope,
           !loadedSummaries.contains(where: { $0.id == id }) {
            selectedScope = .allDecks
        }
    }

    func createDeck(name: String, parentID: UUID? = nil) async -> Deck? {
        errorMessage = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Deck name can't be empty."
            return nil
        }

        do {
            if let parentID {
                do {
                    _ = try await library.deck(id: parentID)
                } catch {
                    errorMessage = "Parent deck could not be found."
                    return nil
                }
            }

            let deck = Deck(name: trimmed, parentID: parentID)
            let created = try await library.createDeck(deck)
            await load()
            selectedScope = .deck(created.id)
            return created
        } catch {
            errorMessage = UserFacingError.message(from: error)
            return nil
        }
    }

    func renameDeck(id: UUID, name: String) async -> Bool {
        errorMessage = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Deck name can't be empty."
            return false
        }

        do {
            var deck = try await library.deck(id: id)
            deck.name = trimmed
            _ = try await library.updateDeck(deck)
            await load()
            return true
        } catch {
            errorMessage = UserFacingError.message(from: error)
            return false
        }
    }

    func updateNewCardsPerDay(id: UUID, limit: Int?) async -> Bool {
        errorMessage = nil
        if let limit, limit < 0 {
            errorMessage = "New cards per day cannot be negative."
            return false
        }

        do {
            var deck = try await library.deck(id: id)
            deck.newCardsPerDay = limit
            _ = try await library.updateDeck(deck)
            // The tree is unchanged; only the limit and the due counts it gates
            // moved, so there is nothing here worth a reload.
            await refreshCounts()
            return true
        } catch {
            errorMessage = UserFacingError.message(from: error)
            return false
        }
    }

    func deleteDeck(id: UUID) async -> Bool {
        errorMessage = nil
        do {
            guard try await library.deleteDeck(id: id) else { return false }
            if case let .deck(selectedID) = selectedScope {
                let deletedIDs = DeckTree.descendantIDs(of: id, in: summaries)
                if deletedIDs.contains(selectedID) {
                    selectedScope = .allDecks
                }
            }
            await load()
            return true
        } catch {
            errorMessage = UserFacingError.message(from: error)
            return false
        }
    }

    func resetProgress(id: UUID, now: Date = .now) async -> Int? {
        errorMessage = nil
        do {
            let resetCount = try await library.resetDeckProgress(id: id, asOf: now)
            await refreshCounts(asOf: now)
            return resetCount
        } catch {
            errorMessage = UserFacingError.message(from: error)
            return nil
        }
    }

    func deckName(for id: UUID) -> String? {
        summaries.first(where: { $0.id == id })?.name
    }
}
