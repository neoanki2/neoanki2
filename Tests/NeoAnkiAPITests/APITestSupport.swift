import Foundation
@testable import NeoAnkiAPI
import NeoAnkiCore
import Testing

struct ApproveAllPairings: APIPairingApprover {
    func approve(_ request: APIPairingRequest) async -> Bool { true }
}

struct ConfiguredAPIFaultInjector: APIFaultInjector {
    let point: APIFaultPoint

    func simulatesProcessExit(at candidate: APIFaultPoint) -> Bool {
        switch (point, candidate) {
        case (.mediaAfterReservation, .mediaAfterReservation),
             (.importBeforeDomainCommit, .importBeforeDomainCommit),
             (.importAfterDomainCommit, .importAfterDomainCommit),
             (.importAfterCompletedJobPersisted, .importAfterCompletedJobPersisted),
             (.exportAfterPendingJobPersisted, .exportAfterPendingJobPersisted),
             (.exportAfterOutputGenerated, .exportAfterOutputGenerated),
             (.exportAfterCompletedJobPersisted, .exportAfterCompletedJobPersisted):
            true
        default:
            false
        }
    }
}

func apiTestDatabaseURL() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-api-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("library.sqlite")
}

func makeAPI(authority: String = "127.0.0.1:8766") async throws -> NeoAnkiAPIService {
    let store = try ItemStore(databaseURL: apiTestDatabaseURL(), starterItemTypes: [])
    try await store.bootstrap()
    let credentials = InMemoryAPICredentialPersistence()
    let authorization = APIAuthorizationStore(persistence: credentials)
    return NeoAnkiAPIService(
        store: store,
        authorization: authorization,
        pairingApprover: ApproveAllPairings(),
        applicationVersion: "test",
        authority: authority
    )
}

func makeAPIAndStore() async throws -> (NeoAnkiAPIService, ItemStore) {
    let store = try ItemStore(databaseURL: apiTestDatabaseURL())
    try await store.bootstrap()
    let authorization = APIAuthorizationStore(
        persistence: InMemoryAPICredentialPersistence()
    )
    return (
        NeoAnkiAPIService(
            store: store,
            authorization: authorization,
            pairingApprover: ApproveAllPairings(),
            applicationVersion: "test"
        ),
        store
    )
}

func request(
    _ method: APIHTTPMethod,
    _ path: String,
    headers: [String: String] = [:],
    body: String = ""
) -> APIRequest {
    var allHeaders = headers
    allHeaders["Host"] = allHeaders["Host"] ?? "127.0.0.1:8766"
    return APIRequest(
        method: method,
        path: path,
        headers: allHeaders,
        body: Data(body.utf8)
    )
}

func jsonObject(_ response: APIResponse) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
}

func pair(
    _ api: NeoAnkiAPIService,
    scopes: [String],
    origin: String? = nil
) async throws -> String {
    var payload: [String: Any] = [
        "displayName": "Contract Test",
        "requestedScopes": scopes,
    ]
    if let origin { payload["origin"] = origin }
    let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    var headers: [String: String] = ["Host": "127.0.0.1:8766"]
    if let origin { headers["Origin"] = origin }
    let response = await api.handle(
        APIRequest(method: .post, path: "/v1/pairings", headers: headers, body: body)
    )
    #expect(response.status == 201)
    return try #require(try jsonObject(response)["token"] as? String)
}
