import Foundation
import NeoAnkiTestSupport
import Testing

@testable import NeoAnkiCore

@Test func dueCardHydrationLoadsEveryItemAcrossDatabaseChunks() async throws {
    let (store, directory) = try await PerformanceFixtures.makeStore(
        label: "due-card-hydration-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let itemCount = 501
    _ = try await PerformanceFixtures.seedBasicItems(
        count: itemCount,
        in: store,
        now: now
    )

    let dueCards = try await store.fetchDueCards(asOf: now)

    #expect(dueCards.count == itemCount)
    #expect(Set(dueCards.map(\.id)).count == itemCount)
    #expect(Set(dueCards.map(\.item.id)).count == itemCount)
    #expect(dueCards.allSatisfy { $0.itemType.id == BuiltInItemTypes.basicID })
    #expect(dueCards.allSatisfy { $0.template.id == $0.card.templateID })
}
