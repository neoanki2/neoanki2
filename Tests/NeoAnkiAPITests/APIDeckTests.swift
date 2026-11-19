import Foundation
@testable import NeoAnkiAPI
import NeoAnkiCore
import Testing

@Test func deckCreateReplayPaginationAndOptimisticUpdateAreStable() async throws {
    let api = try await makeAPI()
    let token = try await pair(api, scopes: ["library.read", "decks.write"])
    let authorization = ["Authorization": "Bearer \(token)"]
    let deckID = UUID().uuidString.lowercased()
    let createBody = "{\"id\":\"\(deckID)\",\"name\":\"Geography\",\"newCardsPerDay\":10}"
    var createHeaders = authorization
    createHeaders["Idempotency-Key"] = "create-geography"

    let created = await api.handle(
        request(.post, "/v1/decks", headers: createHeaders, body: createBody)
    )
    let replayed = await api.handle(
        request(.post, "/v1/decks", headers: createHeaders, body: createBody)
    )
    #expect(created.status == 201)
    #expect(replayed.status == 201)
    #expect(created.body == replayed.body)
    #expect(created.headers["ETag"] == "\"revision-1\"")
    #expect(try jsonObject(created)["id"] as? String == deckID)
    let createdMaturity = try #require(try jsonObject(created)["maturity"] as? [String: Any])
    #expect(createdMaturity["status"] as? String == "noActiveCards")
    #expect(createdMaturity["activeCardCount"] as? Int == 0)

    let listed = await api.handle(
        request(.get, "/v1/decks", headers: authorization)
    )
    #expect(listed.status == 200)
    let data = try #require(try jsonObject(listed)["data"] as? [[String: Any]])
    #expect(data.count == 1)

    let withoutIdempotency = await api.handle(request(
        .post,
        "/v1/decks",
        headers: authorization,
        body: #"{"name":"No idempotency required"}"#
    ))
    #expect(withoutIdempotency.status == 201)
    let collision = await api.handle(request(
        .post,
        "/v1/decks",
        headers: authorization,
        body: #"{"id":"\#(deckID)","name":"Collision"}"#
    ))
    #expect(collision.status == 409)
    #expect(try jsonObject(collision)["code"] as? String == "resource_id_conflict")

    var staleHeaders = authorization
    staleHeaders["If-Match"] = "\"revision-0\""
    let stale = await api.handle(
        request(
            .patch,
            "/v1/decks/\(deckID)",
            headers: staleHeaders,
            body: "{\"name\":\"World Geography\"}"
        )
    )
    #expect(stale.status == 412)

    var updateHeaders = authorization
    updateHeaders["If-Match"] = "\"revision-1\""
    let updated = await api.handle(
        request(
            .patch,
            "/v1/decks/\(deckID)",
            headers: updateHeaders,
            body: "{\"name\":\"World Geography\",\"newCardsPerDay\":null}"
        )
    )
    #expect(updated.status == 200)
    #expect(updated.headers["ETag"] == "\"revision-2\"")
    #expect(try jsonObject(updated)["name"] as? String == "World Geography")

    let changes = await api.handle(
        request(.get, "/v1/changes?unused", headers: authorization)
    )
    // The transport parser owns query splitting; the service rejects a literal
    // path not present in the versioned router.
    #expect(changes.status == 404)
}

@Test func deckDeletionAndResetPlansBindExactImpactAndRevisions() async throws {
    let (api, store) = try await makeAPIAndStore()
    let token = try await pair(
        api,
        scopes: ["library.read", "decks.write", "study.review"]
    )
    let auth = ["Authorization": "Bearer \(token)"]
    let parent = try await store.createDeck(Deck(name: "Outside parent"))
    let root = try await store.createDeck(Deck(name: "Planned root", parentID: parent.id))
    let child = try await store.createDeck(Deck(name: "Planned child", parentID: root.id))

    func basicItem(deckID: UUID, front: String) -> Item {
        Item(
            itemTypeID: BuiltInItemTypes.basicID,
            fields: [
                FieldValue(
                    fieldID: BuiltInItemTypes.frontFieldID,
                    value: .text(front)
                ),
                FieldValue(
                    fieldID: BuiltInItemTypes.backFieldID,
                    value: .text("Back")
                ),
            ],
            deckID: deckID
        )
    }
    let rootItem = basicItem(deckID: root.id, front: "Root")
    let childItem = basicItem(deckID: child.id, front: "Child")
    _ = try await store.createItem(rootItem)
    _ = try await store.createItem(childItem)
    let reviewedCardID = try #require(try await store.itemRecord(id: childItem.id).cardIDs.first)
    _ = try await store.submitReview(cardID: reviewedCardID, rating: .good)

    func deletionPlan(_ policy: String) async throws -> APIResponse {
        await api.handle(request(
            .post,
            "/v1/deck-deletion-plans",
            headers: auth,
            body: #"{"deckId":"\#(root.id.uuidString.lowercased())","policy":"\#(policy)"}"#
        ))
    }
    var plans: [String: [String: Any]] = [:]
    var planETags: [String: String] = [:]
    for policy in [
        "rejectIfNonempty", "unassignItems", "moveItemsToParent", "deleteSubtreeAndItems",
    ] {
        let response = try await deletionPlan(policy)
        #expect(response.status == 201)
        let object = try jsonObject(response)
        let impact = try #require(object["impact"] as? [String: Any])
        #expect(impact["deckCount"] as? Int == 2)
        #expect(impact["itemCount"] as? Int == 2)
        #expect(impact["cardCount"] as? Int == 2)
        #expect(impact["reviewLogCount"] as? Int == 1)
        #expect(impact["mediaReferenceCount"] as? Int == 0)
        plans[policy] = object
        planETags[policy] = response.headers["ETag"]
    }

    let rejectID = try #require(plans["rejectIfNonempty"]?["id"] as? String)
    let rejected = await api.handle(request(
        .post,
        "/v1/deck-deletion-plans/\(rejectID)/commits",
        headers: auth.merging([
            "Idempotency-Key": "reject-nonempty",
            "If-Match": try #require(planETags["rejectIfNonempty"]),
        ]) { _, new in new },
        body: #"{"confirm":false}"#
    ))
    #expect(rejected.status == 409)
    #expect(try jsonObject(rejected)["code"] as? String == "resource_in_use")
    _ = try await store.deck(id: root.id)

    let destructiveID = try #require(plans["deleteSubtreeAndItems"]?["id"] as? String)
    let unconfirmed = await api.handle(request(
        .post,
        "/v1/deck-deletion-plans/\(destructiveID)/commits",
        headers: auth.merging([
            "Idempotency-Key": "missing-confirmation",
            "If-Match": try #require(planETags["deleteSubtreeAndItems"]),
        ]) { _, new in new },
        body: #"{"confirm":false}"#
    ))
    #expect(unconfirmed.status == 422)
    _ = try await store.deck(id: child.id)

    var changedItem = try await store.itemRecord(id: rootItem.id).item
    changedItem.tags = ["invalidates-plan"]
    _ = try await store.updateItem(changedItem)
    let invalidated = await api.handle(request(
        .post,
        "/v1/deck-deletion-plans/\(destructiveID)/commits",
        headers: auth.merging([
            "Idempotency-Key": "invalidated-plan",
            "If-Match": try #require(planETags["deleteSubtreeAndItems"]),
        ]) { _, new in new },
        body: #"{"confirm":true}"#
    ))
    #expect(invalidated.status == 412)
    _ = try await store.deck(id: root.id)

    let fresh = try await deletionPlan("deleteSubtreeAndItems")
    let freshID = try #require(try jsonObject(fresh)["id"] as? String)
    let committed = await api.handle(request(
        .post,
        "/v1/deck-deletion-plans/\(freshID)/commits",
        headers: auth.merging([
            "Idempotency-Key": "confirmed-deletion",
            "If-Match": try #require(fresh.headers["ETag"]),
        ]) { _, new in new },
        body: #"{"confirm":true}"#
    ))
    #expect(committed.status == 200)
    await #expect(throws: DatabaseError.self) { try await store.deck(id: root.id) }
    await #expect(throws: DatabaseError.self) { try await store.itemRecord(id: childItem.id) }

    let resetRoot = try await store.createDeck(Deck(name: "Reset root"))
    let resetChild = try await store.createDeck(Deck(name: "Reset child", parentID: resetRoot.id))
    let resetItem = basicItem(deckID: resetChild.id, front: "Reset me")
    _ = try await store.createItem(resetItem)
    let resetCardID = try #require(try await store.itemRecord(id: resetItem.id).cardIDs.first)
    _ = try await store.submitReview(cardID: resetCardID, rating: .easy)
    _ = try await store.setCardSuspended(id: resetCardID, isSuspended: true)
    let resetPlan = await api.handle(request(
        .post,
        "/v1/deck-reset-plans",
        headers: auth,
        body: #"{"deckId":"\#(resetRoot.id.uuidString.lowercased())"}"#
    ))
    #expect(resetPlan.status == 201)
    let resetObject = try jsonObject(resetPlan)
    let resetImpact = try #require(resetObject["impact"] as? [String: Any])
    #expect(resetImpact["deckCount"] as? Int == 2)
    #expect(resetImpact["cardCount"] as? Int == 1)
    #expect(resetImpact["reviewLogCount"] as? Int == 1)
    let resetPlanID = try #require(resetObject["id"] as? String)
    let resetCommit = await api.handle(request(
        .post,
        "/v1/deck-reset-plans/\(resetPlanID)/commits",
        headers: auth.merging([
            "Idempotency-Key": "reset-subtree",
            "If-Match": try #require(resetPlan.headers["ETag"]),
        ]) { _, new in new },
        body: #"{"confirm":true}"#
    ))
    #expect(resetCommit.status == 200)
    let resetCard = try await store.card(id: resetCardID)
    #expect(resetCard.memory.phase == .new)
    #expect(resetCard.isSuspended)
    #expect(try await store.rawReviewLogCount(for: resetCardID) == 1)
    #expect(try await store.activeReviewLogCount(for: resetCardID) == 0)
    #expect(try await store.itemRecord(id: resetItem.id).item == resetItem)
}

@Test func everyCollectionTraversesDeterministicallyAndRejectsMismatchedCursors() async throws {
    let (api, store) = try await makeAPIAndStore()
    let token = try await pair(api, scopes: ["library.read"])
    let headers = [
        "Host": "127.0.0.1:8766",
        "Authorization": "Bearer \(token)",
    ]
    let decks = try await ["Zulu", "Alpha", "Middle"].asyncMap {
        try await store.createDeck(Deck(name: $0))
    }
    for index in 0 ..< 3 {
        _ = try await store.createItem(Item(
            itemTypeID: BuiltInItemTypes.basicID,
            fields: [
                FieldValue(
                    fieldID: BuiltInItemTypes.frontFieldID,
                    value: .text("Front \(index)")
                ),
                FieldValue(
                    fieldID: BuiltInItemTypes.backFieldID,
                    value: .text("Back \(index)")
                ),
            ],
            tags: index < 2 ? ["shared", "tag-\(index)"] : ["tag-\(index)"],
            deckID: decks[index].id
        ))
    }

    func page(
        _ path: String,
        cursor: String? = nil,
        extra: [String: [String]] = [:],
        service: NeoAnkiAPIService? = nil,
        requestHeaders: [String: String]? = nil
    ) async -> APIResponse {
        var query = extra
        query["limit"] = ["1"]
        if let cursor { query["cursor"] = [cursor] }
        return await (service ?? api).handle(APIRequest(
            method: .get,
            path: path,
            query: query,
            headers: requestHeaders ?? headers
        ))
    }

    func traverse(_ path: String, identity: String) async throws -> [String] {
        var cursor: String?
        var values: [String] = []
        repeat {
            let response = await page(path, cursor: cursor)
            #expect(response.status == 200)
            let object = try jsonObject(response)
            let data = try #require(object["data"] as? [[String: Any]])
            #expect(data.count <= 1)
            values += try data.map { try #require($0[identity] as? String) }
            let pageObject = try #require(object["page"] as? [String: Any])
            cursor = pageObject["nextCursor"] as? String
        } while cursor != nil
        #expect(Set(values).count == values.count)
        return values
    }

    for (path, identity) in [
        ("/v1/decks", "id"), ("/v1/item-types", "id"),
        ("/v1/items", "id"), ("/v1/tags", "name"), ("/v1/cards", "id"),
    ] {
        let first = try await traverse(path, identity: identity)
        let second = try await traverse(path, identity: identity)
        #expect(first == second)
    }

    let filteredFirst = await page(
        "/v1/items", extra: ["tag": ["shared"]]
    )
    let filteredCursor = try #require(
        (try jsonObject(filteredFirst)["page"] as? [String: Any])?["nextCursor"] as? String
    )
    let mismatched = await page(
        "/v1/items", cursor: filteredCursor, extra: ["tag": ["tag-2"]]
    )
    #expect(mismatched.status == 400)
    #expect(try jsonObject(mismatched)["code"] as? String == "invalid_cursor")

    let replacement = filteredCursor.last == "a" ? "b" : "a"
    let tamperedCursor = String(filteredCursor.dropLast()) + replacement
    let tampered = await page(
        "/v1/items", cursor: tamperedCursor, extra: ["tag": ["shared"]]
    )
    #expect(tampered.status == 400)

    let (otherAPI, _) = try await makeAPIAndStore()
    let otherToken = try await pair(otherAPI, scopes: ["library.read"])
    let foreign = await page(
        "/v1/items",
        cursor: filteredCursor,
        extra: ["tag": ["shared"]],
        service: otherAPI,
        requestHeaders: [
            "Host": "127.0.0.1:8766",
            "Authorization": "Bearer \(otherToken)",
        ]
    )
    #expect(foreign.status == 400)

    let excessive = await api.handle(APIRequest(
        method: .get,
        path: "/v1/items",
        query: ["limit": ["201"]],
        headers: headers
    ))
    #expect(excessive.status == 422)
}

private extension Array where Element == String {
    func asyncMap<T>(_ transform: (String) async throws -> T) async throws -> [T] {
        var values: [T] = []
        values.reserveCapacity(count)
        for value in self { values.append(try await transform(value)) }
        return values
    }
}
