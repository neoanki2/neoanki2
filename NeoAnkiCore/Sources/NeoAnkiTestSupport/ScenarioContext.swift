import Foundation
import NeoAnkiCore

public struct ScenarioContext: Sendable {
    public let store: ItemStore
    public var clock: TestClock

    public init(store: ItemStore, clock: TestClock) {
        self.store = store
        self.clock = clock
    }

    public mutating func onboard() async throws {
        try await store.bootstrap()
        let items = try await store.listItems()
        guard items.isEmpty else {
            throw ScenarioError.unexpectedState("Expected empty library after onboarding.")
        }
    }

    public mutating func createCapitalsItemType() async throws -> (
        ItemType,
        FieldDef,
        FieldDef,
        FieldDef
    ) {
        let fixture = ItemTypeFixtures.capitals()
        _ = try await store.createItemType(fixture.type)
        return (fixture.type, fixture.country, fixture.capital, fixture.map)
    }

    public mutating func createBasicItem(front: String, back: String) async throws -> SavedItemSummary {
        let itemType = try await store.defaultItemType()
        let item = ItemBuilder(itemTypeID: itemType.id)
            .field(itemType.fields[0], text: front)
            .field(itemType.fields[1], text: back)
            .build()
        return try await store.createItem(item, now: clock.now())
    }

    public mutating func createCapitalsItem(
        country: String,
        capital: String,
        includeMap: Bool = false,
        type: ItemType,
        countryField: FieldDef,
        capitalField: FieldDef,
        mapField: FieldDef
    ) async throws -> SavedItemSummary {
        var builder = ItemBuilder(itemTypeID: type.id)
            .field(countryField, text: country)
            .field(capitalField, text: capital)

        if includeMap {
            builder.fields.append(
                FieldValue(
                    fieldID: mapField.id,
                    value: .media(MediaRef(kind: .image, url: URL(string: "file:///map.png")!))
                )
            )
        }

        return try await store.createItem(builder.build(), now: clock.now())
    }

    public mutating func startStudySession() async throws -> [DueCard] {
        try await store.fetchDueCards(asOf: clock.now())
    }

    public mutating func grade(_ rating: ReviewRating, on cardID: UUID) async throws -> MemoryState {
        try await store.submitReview(cardID: cardID, rating: rating, now: clock.now())
    }

    public func assertDueCount(_ expected: Int) async throws {
        let count = try await store.dueCount(asOf: clock.now())
        guard count == expected else {
            throw ScenarioError.unexpectedState("Expected \(expected) due cards, found \(count).")
        }
    }

    public func assertItemCount(_ expected: Int) async throws {
        let items = try await store.listItems()
        guard items.count == expected else {
            throw ScenarioError.unexpectedState("Expected \(expected) items, found \(items.count).")
        }
    }
}

public enum ScenarioError: Error, Sendable, Equatable, LocalizedError {
    case unexpectedState(String)

    public var errorDescription: String? {
        switch self {
        case let .unexpectedState(message):
            return message
        }
    }
}
