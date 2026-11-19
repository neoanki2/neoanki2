import Foundation
@testable import NeoAnkiAPI
import NeoAnkiCore
import Testing

@Test func studySessionReservesGradesReplaysAndEndsSafely() async throws {
    let (api, store) = try await makeAPIAndStore()
    let token = try await pair(api, scopes: ["study.review"])
    let auth = ["Authorization": "Bearer \(token)"]
    let item = Item(
        itemTypeID: BuiltInItemTypes.basicID,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Question")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
        ]
    )
    _ = try await store.createItem(item)

    let created = await api.handle(
        request(
            .post,
            "/v1/study-sessions",
            headers: auth,
            body: #"{"scope":{"kind":"allDecks"}}"#
        )
    )
    #expect(created.status == 201)
    #expect(created.headers["ETag"] == "\"revision-1\"")
    let sessionID = try #require(try jsonObject(created)["id"] as? String)

    let next = await api.handle(
        request(.post, "/v1/study-sessions/\(sessionID)/next", headers: auth)
    )
    #expect(next.status == 200)
    let nextBody = try jsonObject(next)
    let cardID = try #require(nextBody["id"] as? String)
    #expect((nextBody["prompt"] as? [Any])?.isEmpty == false)
    let memoryBeforeReview = try await store.card(id: UUID(uuidString: cardID)!).memory
    let retryNext = await api.handle(
        request(.post, "/v1/study-sessions/\(sessionID)/next", headers: auth)
    )
    #expect(try jsonObject(retryNext)["id"] as? String == cardID)

    let oversizedDuration = await api.handle(request(
        .post,
        "/v1/reviews",
        headers: auth.merging(["Idempotency-Key": "duration-too-large"]) { _, new in new },
        body: """
            {"sessionId":"\(sessionID)","cardId":"\(cardID)","rating":"good","durationMs":1800001}
            """
    ))
    #expect(oversizedDuration.status == 422)

    let reviewBody = """
        {"sessionId":"\(sessionID)","cardId":"\(cardID)","rating":"good","durationMs":125}
        """
    var reviewHeaders = auth
    reviewHeaders["Idempotency-Key"] = "grade-once"
    let reviewed = await api.handle(
        request(.post, "/v1/reviews", headers: reviewHeaders, body: reviewBody)
    )
    let replayed = await api.handle(
        request(.post, "/v1/reviews", headers: reviewHeaders, body: reviewBody)
    )
    #expect(reviewed.status == 201)
    #expect(replayed.status == 201)
    #expect(reviewed.body == replayed.body)
    let reviewLogID = try #require(try jsonObject(reviewed)["reviewLogId"] as? String)
    #expect(try await store.activeReviewLogCount(for: UUID(uuidString: cardID)!) == 1)
    #expect(!reviewLogID.isEmpty)

    let duplicate = await api.handle(
        request(
            .post,
            "/v1/reviews",
            headers: auth.merging(["Idempotency-Key": "different-attempt"]) { _, new in new },
            body: reviewBody
        )
    )
    #expect(duplicate.status == 409)
    #expect(try jsonObject(duplicate)["code"] as? String == "study_conflict")

    let reverted = await api.handle(request(
        .post,
        "/v1/reviews/\(reviewLogID)/reverts",
        headers: auth.merging([
            "If-Match": try #require(reviewed.headers["ETag"]),
            "Idempotency-Key": "revert-once",
        ]) { _, new in new }
    ))
    #expect(reverted.status == 204)
    #expect(try await store.card(id: UUID(uuidString: cardID)!).memory == memoryBeforeReview)
    #expect(try await store.activeReviewLogCount(for: UUID(uuidString: cardID)!) == 0)
    let repeatedRevert = await api.handle(request(
        .post,
        "/v1/reviews/\(reviewLogID)/reverts",
        headers: auth.merging([
            "If-Match": try #require(reviewed.headers["ETag"]),
            "Idempotency-Key": "different-revert",
        ]) { _, new in new }
    ))
    #expect([404, 412].contains(repeatedRevert.status))
    #expect(try await store.card(id: UUID(uuidString: cardID)!).memory == memoryBeforeReview)

    let session = await api.handle(
        request(.get, "/v1/study-sessions/\(sessionID)", headers: auth)
    )
    let etag = try #require(session.headers["ETag"])
    let ended = await api.handle(
        request(
            .delete,
            "/v1/study-sessions/\(sessionID)",
            headers: auth.merging(["If-Match": etag]) { _, new in new }
        )
    )
    #expect(ended.status == 204)
}

@Test func studySessionReservesCardAgainAfterEveryAgainRating() async throws {
    let (api, store) = try await makeAPIAndStore()
    let token = try await pair(api, scopes: ["study.review"])
    let auth = ["Authorization": "Bearer \(token)"]
    _ = try await store.createItem(Item(
        itemTypeID: BuiltInItemTypes.basicID,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Question")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
        ]
    ))

    let created = await api.handle(request(
        .post,
        "/v1/study-sessions",
        headers: auth,
        body: #"{"scope":{"kind":"allDecks"}}"#
    ))
    let sessionID = try #require(try jsonObject(created)["id"] as? String)
    let first = await api.handle(request(
        .post,
        "/v1/study-sessions/\(sessionID)/next",
        headers: auth
    ))
    let cardID = try #require(try jsonObject(first)["id"] as? String)

    for attempt in 1 ... 2 {
        let reviewed = await api.handle(request(
            .post,
            "/v1/reviews",
            headers: auth.merging(["Idempotency-Key": "again-\(attempt)"]) { _, new in new },
            body: """
                {"sessionId":"\(sessionID)","cardId":"\(cardID)","rating":"again","durationMs":250}
                """
        ))
        #expect(reviewed.status == 201)

        let repeated = await api.handle(request(
            .post,
            "/v1/study-sessions/\(sessionID)/next",
            headers: auth
        ))
        #expect(repeated.status == 200)
        #expect(try jsonObject(repeated)["id"] as? String == cardID)
    }

    let memory = try await store.card(id: UUID(uuidString: cardID)!).memory
    #expect(memory.phase == .learning)
    #expect(memory.stepIndex == 1)
    #expect(memory.due <= Date.now)
}

@Test func concurrentRevisionsAndOneHundredIdempotentReviewReplaysAreLinearizable() async throws {
    let store = try ItemStore(databaseURL: apiTestDatabaseURL())
    try await store.bootstrap()
    let authorization = APIAuthorizationStore(
        persistence: InMemoryAPICredentialPersistence()
    )
    func service() -> NeoAnkiAPIService {
        NeoAnkiAPIService(
            store: store,
            authorization: authorization,
            pairingApprover: ApproveAllPairings(),
            applicationVersion: "test"
        )
    }
    let api = service()
    let secondAPIAdapter = service()
    let token = try await pair(
        api,
        scopes: ["library.read", "decks.write", "study.review"]
    )
    let auth = ["Authorization": "Bearer \(token)"]

    let deck = await api.handle(request(
        .post,
        "/v1/decks",
        headers: auth.merging(["Idempotency-Key": "concurrent-deck"]) { _, new in new },
        body: #"{"name":"Initial"}"#
    ))
    let deckID = try #require(try jsonObject(deck)["id"] as? String)
    let deckETag = try #require(deck.headers["ETag"])
    let updateResults = await withTaskGroup(of: APIResponse.self) { group in
        for (adapter, name) in [
            (api, "First winner"),
            (secondAPIAdapter, "Second winner"),
        ] {
            group.addTask {
                await adapter.handle(request(
                    .patch,
                    "/v1/decks/\(deckID)",
                    headers: auth.merging(["If-Match": deckETag]) { _, new in new },
                    body: #"{"name":"\#(name)"}"#
                ))
            }
        }
        var values: [APIResponse] = []
        for await value in group { values.append(value) }
        return values
    }
    #expect(updateResults.map(\.status).sorted() == [200, 412])
    let winningResponse = try #require(updateResults.first { $0.status == 200 })
    let winningName = try #require(try jsonObject(winningResponse)["name"] as? String)
    let persistedDeck = await api.handle(request(
        .get, "/v1/decks/\(deckID)", headers: auth
    ))
    #expect(try jsonObject(persistedDeck)["name"] as? String == winningName)

    _ = try await store.createItem(Item(
        itemTypeID: BuiltInItemTypes.basicID,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Replay")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Exactly once")),
        ]
    ))
    let session = await api.handle(request(
        .post,
        "/v1/study-sessions",
        headers: auth,
        body: #"{"scope":{"kind":"allDecks"}}"#
    ))
    let sessionID = try #require(try jsonObject(session)["id"] as? String)
    let next = await api.handle(request(
        .post, "/v1/study-sessions/\(sessionID)/next", headers: auth
    ))
    let cardID = try #require(try jsonObject(next)["id"] as? String)
    let reviewBody = #"{"sessionId":"\#(sessionID)","cardId":"\#(cardID)","rating":"good","durationMs":42}"#
    let reviewHeaders = auth.merging(["Idempotency-Key": "one-hundred-replays"]) {
        _, new in new
    }
    let responses = await withTaskGroup(of: APIResponse.self) { group in
        for _ in 0 ..< 100 {
            group.addTask {
                await api.handle(request(
                    .post, "/v1/reviews", headers: reviewHeaders, body: reviewBody
                ))
            }
        }
        var values: [APIResponse] = []
        for await value in group { values.append(value) }
        return values
    }
    #expect(responses.count == 100)
    #expect(responses.allSatisfy { $0.status == 201 })
    #expect(Set(responses.map(\.body)).count == 1)
    let reviewID = try #require(try jsonObject(responses[0])["reviewLogId"] as? String)
    #expect(try await store.rawReviewLogCount(for: UUID(uuidString: cardID)!) == 1)
    let reviewChanges = try await store.libraryChanges(after: 0).filter {
        $0.resourceID.lowercased() == reviewID
    }
    #expect(reviewChanges.count == 1)
}

@Test func studySessionsArePrivateToTheirOwningClientAndValidateNestedInput() async throws {
    let (api, _) = try await makeAPIAndStore()
    let firstToken = try await pair(api, scopes: ["study.review"])
    let secondToken = try await pair(api, scopes: ["study.review"])
    let firstAuth = ["Authorization": "Bearer \(firstToken)"]
    let created = await api.handle(
        request(
            .post,
            "/v1/study-sessions",
            headers: firstAuth,
            body: #"{"scope":{"kind":"unassigned"}}"#
        )
    )
    let sessionID = try #require(try jsonObject(created)["id"] as? String)

    let hidden = await api.handle(
        request(
            .get,
            "/v1/study-sessions/\(sessionID)",
            headers: ["Authorization": "Bearer \(secondToken)"]
        )
    )
    #expect(hidden.status == 404)

    let unknown = await api.handle(
        request(
            .post,
            "/v1/study-sessions",
            headers: firstAuth,
            body: #"{"scope":{"kind":"allDecks","typo":true}}"#
        )
    )
    #expect(unknown.status == 422)
    #expect(try jsonObject(unknown)["code"] as? String == "validation_failed")
}

@Test func studyScopesAndOneHundredConcurrentSessionsNeverDoubleReserve() async throws {
    let (api, store) = try await makeAPIAndStore()
    let token = try await pair(api, scopes: ["study.review"])
    let auth = ["Authorization": "Bearer \(token)"]
    let root = try await store.createDeck(Deck(name: "Scope root"))
    let child = try await store.createDeck(Deck(name: "Scope child", parentID: root.id))

    func item(_ index: Int, deckID: UUID?) -> Item {
        Item(
            itemTypeID: BuiltInItemTypes.basicID,
            fields: [
                FieldValue(
                    fieldID: BuiltInItemTypes.frontFieldID,
                    value: .text("Concurrent \(index)")
                ),
                FieldValue(
                    fieldID: BuiltInItemTypes.backFieldID,
                    value: .text("Answer \(index)")
                ),
            ],
            deckID: deckID
        )
    }
    _ = try await store.createItem(item(0, deckID: nil))
    _ = try await store.createItem(item(1, deckID: root.id))
    _ = try await store.createItem(item(2, deckID: child.id))

    func reserve(scope: String) async throws -> [String: Any] {
        let session = await api.handle(request(
            .post, "/v1/study-sessions", headers: auth,
            body: "{\"scope\":\(scope)}"
        ))
        #expect(session.status == 201)
        let id = try #require(try jsonObject(session)["id"] as? String)
        let next = await api.handle(request(
            .post, "/v1/study-sessions/\(id)/next", headers: auth
        ))
        #expect(next.status == 200)
        return try jsonObject(next)
    }
    #expect(try await reserve(scope: #"{"kind":"unassigned"}"#)["deckId"] == nil)
    #expect(try await reserve(
        scope: #"{"kind":"deck","deckId":"\#(root.id.uuidString.lowercased())","includeDescendants":false}"#
    )["deckId"] as? String == root.id.uuidString.lowercased())
    #expect(try await reserve(
        scope: #"{"kind":"deck","deckId":"\#(root.id.uuidString.lowercased())","includeDescendants":true}"#
    )["deckId"] as? String == child.id.uuidString.lowercased())

    for index in 3 ..< 103 {
        _ = try await store.createItem(item(index, deckID: nil))
    }
    var sessionIDs: [String] = []
    for _ in 0 ..< 100 {
        let response = await api.handle(request(
            .post,
            "/v1/study-sessions",
            headers: auth,
            body: #"{"scope":{"kind":"allDecks"}}"#
        ))
        sessionIDs.append(try #require(try jsonObject(response)["id"] as? String))
    }
    let reservedIDs = await withTaskGroup(of: String?.self) { group in
        for sessionID in sessionIDs {
            group.addTask {
                let response = await api.handle(request(
                    .post, "/v1/study-sessions/\(sessionID)/next", headers: auth
                ))
                return (try? jsonObject(response)["id"] as? String) ?? nil
            }
        }
        var values: [String] = []
        for await value in group {
            if let value { values.append(value) }
        }
        return values
    }
    #expect(reservedIDs.count == 100)
    #expect(Set(reservedIDs).count == 100)
}

@Test func reviewRetryAfterCommitBeforeResponseRecoversExactlyOnceAcrossServiceRestart() async throws {
    let store = try ItemStore(databaseURL: apiTestDatabaseURL())
    try await store.bootstrap()
    let authorization = APIAuthorizationStore(
        persistence: InMemoryAPICredentialPersistence()
    )
    func service() -> NeoAnkiAPIService {
        NeoAnkiAPIService(
            store: store,
            authorization: authorization,
            pairingApprover: ApproveAllPairings(),
            applicationVersion: "test"
        )
    }
    let firstService = service()
    let token = try await pair(firstService, scopes: ["study.review"])
    let grant = try #require(try await authorization.authenticate(token: token))
    _ = try await store.createItem(Item(
        itemTypeID: BuiltInItemTypes.basicID,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Crash")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Recover")),
        ]
    ))
    let auth = ["Authorization": "Bearer \(token)"]
    let session = await firstService.handle(request(
        .post,
        "/v1/study-sessions",
        headers: auth,
        body: #"{"scope":{"kind":"allDecks"}}"#
    ))
    let sessionID = try #require(try jsonObject(session)["id"] as? String)
    let next = await firstService.handle(request(
        .post, "/v1/study-sessions/\(sessionID)/next", headers: auth
    ))
    let cardID = try #require(try jsonObject(next)["id"] as? String)
    let body = Data(
        #"{"sessionId":"\#(sessionID)","cardId":"\#(cardID)","rating":"easy","durationMs":17}"#.utf8
    )
    let key = "crash-boundary-review"
    let logID = UUID()
    let hash = try APIJSON.canonicalRequestHash(
        method: .post,
        path: "/v1/reviews",
        body: body
    )
    _ = try await store.claimIdempotency(
        clientID: grant.id,
        route: "POST /v1/reviews",
        key: key,
        requestHash: hash,
        resultResourceID: logID.uuidString.lowercased()
    )
    _ = try await store.submitReservedReview(
        sessionID: UUID(uuidString: sessionID)!,
        cardID: UUID(uuidString: cardID)!,
        rating: .easy,
        reviewLogID: logID,
        durationMs: 17
    )
    #expect(try await store.rawReviewLogCount(for: UUID(uuidString: cardID)!) == 1)

    let restartedService = service()
    let recovered = await restartedService.handle(APIRequest(
        method: .post,
        path: "/v1/reviews",
        headers: [
            "Host": "127.0.0.1:8766",
            "Authorization": "Bearer \(token)",
            "Idempotency-Key": key,
        ],
        body: body
    ))
    #expect(recovered.status == 201)
    #expect(try jsonObject(recovered)["reviewLogId"] as? String == logID.uuidString.lowercased())
    #expect(recovered.headers["ETag"] == "\"revision-1\"")
    #expect(try await store.rawReviewLogCount(for: UUID(uuidString: cardID)!) == 1)

    let replay = await restartedService.handle(APIRequest(
        method: .post,
        path: "/v1/reviews",
        headers: [
            "Host": "127.0.0.1:8766",
            "Authorization": "Bearer \(token)",
            "Idempotency-Key": key,
        ],
        body: body
    ))
    #expect(replay.body == recovered.body)
    #expect(try await store.rawReviewLogCount(for: UUID(uuidString: cardID)!) == 1)
}
