import Foundation
@testable import NeoAnkiAPI
import NeoAnkiCore
import NeoAnkiTestSupport
import Testing

@Test func referenceScaleAPILatencyMeetsVersionOneReleaseBudgets() async throws {
    guard ProcessInfo.processInfo.environment["NEOANKI_RUN_API_PERFORMANCE_TEST"] != nil else {
        return
    }
    let fixture = try await PerformanceFixtures.makeStore(label: "local-api-v1-release")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    _ = try await PerformanceFixtures.seedBasicItems(count: 100_000, in: fixture.store)
    let authorization = APIAuthorizationStore(
        persistence: InMemoryAPICredentialPersistence()
    )
    let api = NeoAnkiAPIService(
        store: fixture.store,
        authorization: authorization,
        pairingApprover: ApproveAllPairings(),
        applicationVersion: "test"
    )
    let token = try await pair(
        api,
        scopes: ["library.read", "study.review"]
    )
    let auth = ["Authorization": "Bearer \(token)"]

    func percentile95(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
    }
    func measure(_ operation: () async -> APIResponse) async -> (APIResponse, Double) {
        let start = Date.now
        let response = await operation()
        return (response, Date.now.timeIntervalSince(start) * 1_000)
    }
    func assertBudget(
        _ values: [Double],
        milliseconds: Double,
        operation: String
    ) {
        let measured = percentile95(values)
        #expect(
            measured <= milliseconds,
            "\(operation) p95 was \(measured) ms; budget is \(milliseconds) ms."
        )
    }

    _ = await api.handle(request(.get, "/health"))
    _ = await api.handle(request(.get, "/v1/meta"))
    let pageRequest = APIRequest(
        method: .get,
        path: "/v1/items",
        query: ["limit": ["200"]],
        headers: [
            "Host": "127.0.0.1:8766",
            "Authorization": "Bearer \(token)",
        ]
    )
    _ = await api.handle(pageRequest)

    var healthTimes: [Double] = []
    var metadataTimes: [Double] = []
    var collectionTimes: [Double] = []
    for _ in 0 ..< 100 {
        let (health, healthTime) = await measure {
            await api.handle(request(.get, "/health"))
        }
        let (metadata, metadataTime) = await measure {
            await api.handle(request(.get, "/v1/meta"))
        }
        let (page, pageTime) = await measure { await api.handle(pageRequest) }
        #expect(health.status == 200)
        #expect(metadata.status == 200)
        #expect(page.status == 200)
        healthTimes.append(healthTime)
        metadataTimes.append(metadataTime)
        collectionTimes.append(pageTime)
    }

    let session = await api.handle(request(
        .post,
        "/v1/study-sessions",
        headers: auth,
        body: #"{"scope":{"kind":"allDecks"}}"#
    ))
    let sessionID = try #require(try jsonObject(session)["id"] as? String)
    var reviewTimes: [Double] = []
    for index in 0 ..< 100 {
        let next = await api.handle(request(
            .post,
            "/v1/study-sessions/\(sessionID)/next",
            headers: auth
        ))
        let cardID = try #require(try jsonObject(next)["id"] as? String)
        let reviewBody = #"{"sessionId":"\#(sessionID)","cardId":"\#(cardID)","rating":"good","durationMs":0}"#
        let (review, reviewTime) = await measure {
            await api.handle(request(
                .post,
                "/v1/reviews",
                headers: auth.merging([
                    "Idempotency-Key": "performance-review-\(index)",
                ]) { _, new in new },
                body: reviewBody
            ))
        }
        #expect(review.status == 201)
        reviewTimes.append(reviewTime)
    }

    assertBudget(healthTimes, milliseconds: 100, operation: "GET /health")
    assertBudget(metadataTimes, milliseconds: 100, operation: "GET /v1/meta")
    assertBudget(collectionTimes, milliseconds: 500, operation: "GET /v1/items?limit=200")
    assertBudget(reviewTimes, milliseconds: 500, operation: "POST /v1/reviews")
}
