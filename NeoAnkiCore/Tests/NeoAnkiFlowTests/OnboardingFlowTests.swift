import Foundation
import NeoAnkiCore
import NeoAnkiTestSupport
import Testing

@Test func onboardingFlowCreatesFirstItem() async throws {
    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()
        let saved = try await ctx.createBasicItem(front: "France", back: "Paris")
        #expect(saved.title == "France")
        #expect(saved.subtitle == "Paris")
        #expect(saved.cardCount == 1)
        try await ctx.assertItemCount(1)
    }
}

@Test func onboardingPersistsAcrossReopen() async throws {
    let url = TestDatabase.makeURL()
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    do {
        let store = try ItemStore(databaseURL: url)
        try await store.bootstrap()
        let itemType = try await store.defaultItemType()
        let item = Item(
            itemTypeID: itemType.id,
            fields: [
                FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Q")),
                FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("A")),
            ]
        )
        _ = try await store.createItem(item, now: now)
    }

    let reopened = try ItemStore(databaseURL: url)
    try await reopened.bootstrap()
    let items = try await reopened.listItems()
    #expect(items.count == 1)
    #expect(items.first?.title == "Q")
}
