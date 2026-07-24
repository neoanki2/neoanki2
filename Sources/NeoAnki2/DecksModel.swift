import Foundation
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
    private(set) var isLoading = true
    private(set) var errorMessage: String?

    var selectedScope: SidebarSelection = .allDecks

    let store: ItemStore

    init(store: ItemStore) {
        self.store = store
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

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            summaries = try await store.deckSummaries()
            deckTree = DeckTree.build(from: summaries)
            allDecksDueCount = try await store.dueCount(scope: .allDecks)
            unassignedDueCount = try await store.unassignedDueCount()
            unassignedItemCount = try await store.unassignedItemCount()

            if case let .deck(id) = selectedScope,
               !summaries.contains(where: { $0.id == id }) {
                selectedScope = .allDecks
            }
        } catch {
            errorMessage = UserFacingError.message(from: error)
        }
        isLoading = false
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
                    _ = try await store.deck(id: parentID)
                } catch {
                    errorMessage = "Parent deck could not be found."
                    return nil
                }
            }

            let deck = Deck(name: trimmed, parentID: parentID)
            let created = try await store.createDeck(deck)
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
            var deck = try await store.deck(id: id)
            deck.name = trimmed
            _ = try await store.updateDeck(deck)
            await load()
            return true
        } catch {
            errorMessage = UserFacingError.message(from: error)
            return false
        }
    }

    func deleteDeck(id: UUID) async -> Bool {
        errorMessage = nil
        do {
            guard try await store.deleteDeck(id: id) else { return false }
            if selectedScope == .deck(id) {
                selectedScope = .allDecks
            }
            await load()
            return true
        } catch {
            errorMessage = UserFacingError.message(from: error)
            return false
        }
    }

    func deckName(for id: UUID) -> String? {
        summaries.first(where: { $0.id == id })?.name
    }
}
