#if os(iOS)
import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures

typealias MobileAppModel = LibraryFeatureModel

enum MobileScope: Hashable, Sendable {
    case allDecks
    case unassigned
    case deck(UUID)

    var filter: DeckScope {
        switch self {
        case .allDecks: .allDecks
        case .unassigned: .unassigned
        case let .deck(id): .deck(id)
        }
    }

    init(_ scope: DeckScope) {
        switch scope {
        case .allDecks: self = .allDecks
        case .unassigned: self = .unassigned
        case let .deck(id, _): self = .deck(id)
        }
    }
}

extension LibraryFeatureModel {
    func scopeTitle(_ scope: MobileScope) -> String {
        switch scope {
        case .allDecks: "All Decks"
        case .unassigned: "Unassigned"
        case let .deck(id): decks.first(where: { $0.id == id })?.name ?? "Deck"
        }
    }

    func summary(for scope: MobileScope) async throws -> ScopeSummary {
        try await scopeSummary(for: scope.filter)
    }

    func beginStudy(scope: MobileScope) async {
        await beginStudy(scope: scope.filter, title: scopeTitle(scope))
    }

    func deckDepth(_ deck: DeckSummary) -> Int {
        var depth = 0
        var parentID = deck.parentID
        var visited: Set<UUID> = []
        while let id = parentID,
              visited.insert(id).inserted,
              let parent = decks.first(where: { $0.id == id }) {
            depth += 1
            parentID = parent.parentID
        }
        return depth
    }

    func createDeck(name: String) async throws {
        try await createDeck(name: name, parentID: nil, newCardsPerDay: nil)
    }

    func createItem(itemType: ItemType, deckID: UUID?, values: [UUID: String]) async throws {
        var content: [UUID: ContentValue] = [:]
        for field in itemType.fields {
            let input = values[field.id] ?? ""
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { content[field.id] = .empty; continue }
            switch field.type {
            case .text: content[field.id] = .text(input)
            case .richText: content[field.id] = .rich([Span(input)])
            case .number:
                guard let number = NumberFormatter.localizedNumber(from: trimmed) else {
                    throw ItemDraftError.invalidNumber(field.name)
                }
                content[field.id] = .number(number)
            case .cloze: content[field.id] = .cloze(input, blanks: [])
            case .audio, .image, .gif, .video: throw ItemDraftError.unsupportedValue(field.name)
            }
        }
        try await createItem(itemType: itemType, deckID: deckID, values: content)
    }

    static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

private extension NumberFormatter {
    static func localizedNumber(from value: String) -> Double? {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        return formatter.number(from: value)?.doubleValue
    }
}
#endif
