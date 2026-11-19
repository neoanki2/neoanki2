import Foundation
@testable import NeoAnkiAPI
import NeoAnkiCore
import Testing

@Test func transferJobsValidateCommitReplayAndPortableRoundTrip() async throws {
    let (api, store) = try await makeAPIAndStore()
    let token = try await pair(
        api,
        scopes: ["library.read", "library.import", "library.export"]
    )
    let auth = ["Authorization": "Bearer \(token)"]

    func createImport(
        api: NeoAnkiAPIService,
        token: String,
        format: String,
        path: String,
        bytes: Data,
        extra: [String: Any] = [:]
    ) async throws -> (id: String, fileID: String, job: APIResponse) {
        var body: [String: Any] = [
            "format": format,
            "files": [[
                "relativePath": path,
                "byteSize": bytes.count,
                "sha256": APICrypto.sha256Hex(bytes),
            ]],
        ]
        for (key, value) in extra { body[key] = value }
        let encoded = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let created = await api.handle(APIRequest(
            method: .post,
            path: "/v1/imports",
            headers: [
                "Host": "127.0.0.1:8766",
                "Authorization": "Bearer \(token)",
            ],
            body: encoded
        ))
        #expect(created.status == 201)
        let object = try jsonObject(created)
        let id = try #require(object["id"] as? String)
        let files = try #require(object["files"] as? [[String: Any]])
        let fileID = try #require(files.first?["id"] as? String)
        return (id, fileID, created)
    }

    func upload(
        api: NeoAnkiAPIService,
        token: String,
        importID: String,
        fileID: String,
        bytes: Data
    ) async -> APIResponse {
        let status = await api.handle(request(
            .get,
            "/v1/imports/\(importID)",
            headers: ["Authorization": "Bearer \(token)"]
        ))
        guard let currentETag = status.headers["ETag"] else { return status }
        return await api.handle(APIRequest(
            method: .put,
            path: "/v1/imports/\(importID)/files/\(fileID)",
            headers: [
                "Host": "127.0.0.1:8766",
                "Authorization": "Bearer \(token)",
                "If-Match": currentETag,
            ],
            body: bytes
        ))
    }

    let json = Data(#"{"itemType":"Basic","rows":[{"Front":"Imported","Back":"Answer","tags":["api"]}]}"#.utf8)
    let source = try await createImport(
        api: api, token: token, format: "json", path: "items.json", bytes: json
    )
    #expect(await upload(
        api: api, token: token, importID: source.id, fileID: source.fileID,
        bytes: Data("wrong".utf8)
    ).status == 422)
    #expect(await upload(
        api: api, token: token, importID: source.id, fileID: source.fileID, bytes: json
    ).status == 204)
    let validated = await api.handle(request(
        .post, "/v1/imports/\(source.id)/validations", headers: auth
    ))
    #expect(validated.status == 200)
    let planToken = try #require(try jsonObject(validated)["planToken"] as? String)
    _ = try await store.createDeck(Deck(name: "Invalidate import"))
    let stale = await api.handle(request(
        .post,
        "/v1/imports/\(source.id)/commits",
        headers: auth.merging([
            "Idempotency-Key": "stale-import",
            "If-Match": try #require(validated.headers["ETag"]),
        ]) { _, new in new },
        body: #"{"planToken":"\#(planToken)"}"#
    ))
    #expect(stale.status == 412)

    let revalidated = await api.handle(request(
        .post, "/v1/imports/\(source.id)/validations", headers: auth
    ))
    let currentToken = try #require(try jsonObject(revalidated)["planToken"] as? String)
    let commitHeaders = auth.merging([
        "Idempotency-Key": "json-import",
        "If-Match": try #require(revalidated.headers["ETag"]),
    ]) { _, new in new }
    let commit = await api.handle(request(
        .post,
        "/v1/imports/\(source.id)/commits",
        headers: commitHeaders,
        body: #"{"planToken":"\#(currentToken)"}"#
    ))
    let replay = await api.handle(request(
        .post,
        "/v1/imports/\(source.id)/commits",
        headers: commitHeaders,
        body: #"{"planToken":"\#(currentToken)"}"#
    ))
    #expect(commit.status == 200)
    #expect(replay.body == commit.body)
    #expect(try await store.itemRecords().contains { record in
        record.item.value(for: BuiltInItemTypes.frontFieldID) == .text("Imported")
    })

    let authoredManifest = Data(([
        #"{"kind":"neoanki","version":2,"root":"root","parts":["items/items.jsonl"]}"#,
        #"{"kind":"type","id":"Study","name":"API Authored","fields":[{"id":"front","name":"Front","type":"text","required":true},{"id":"back","name":"Back","type":"text","required":true}],"templates":[{"name":"Forward","prompt":[{"field":"front"}],"answer":[{"field":"back"}],"interaction":"reveal","skill":{"input":"text","output":"text","operation":"recall"}}]}"#,
        #"{"kind":"deck","id":"root","name":"Authored through API"}"#,
    ].joined(separator: "\n") + "\n").utf8)
    let authoredItems = Data((
        #"{"kind":"item","deck":"root","type":"Study","fields":{"front":{"text":"Question"},"back":{"text":"Answer"}}}"#
            + "\n"
    ).utf8)
    let authoredFiles: [[String: Any]] = [
        [
            "relativePath": "deck.jsonl",
            "byteSize": authoredManifest.count,
            "sha256": APICrypto.sha256Hex(authoredManifest),
        ],
        [
            "relativePath": "items/items.jsonl",
            "byteSize": authoredItems.count,
            "sha256": APICrypto.sha256Hex(authoredItems),
        ],
    ]
    let authoredCreated = await api.handle(APIRequest(
        method: .post,
        path: "/v1/imports",
        headers: [
            "Host": "127.0.0.1:8766",
            "Authorization": "Bearer \(token)",
        ],
        body: try JSONSerialization.data(
            withJSONObject: ["format": "authoredDeck", "files": authoredFiles],
            options: [.sortedKeys]
        )
    ))
    #expect(authoredCreated.status == 201)
    let authoredObject = try jsonObject(authoredCreated)
    let authoredID = try #require(authoredObject["id"] as? String)
    let authoredFileObjects = try #require(authoredObject["files"] as? [[String: Any]])
    for file in authoredFileObjects {
        let path = try #require(file["relativePath"] as? String)
        let bytes = path == "deck.jsonl" ? authoredManifest : authoredItems
        #expect(await upload(
            api: api,
            token: token,
            importID: authoredID,
            fileID: try #require(file["id"] as? String),
            bytes: bytes
        ).status == 204)
    }
    let authoredValidation = await api.handle(request(
        .post, "/v1/imports/\(authoredID)/validations", headers: auth
    ))
    #expect(authoredValidation.status == 200)
    let authoredValidationObject = try jsonObject(authoredValidation)
    let authoredPlan = try #require(authoredValidationObject["planToken"] as? String)
    let authoredReport = try #require(authoredValidationObject["report"] as? [String: Any])
    #expect(authoredReport["itemCount"] as? Int == 1)
    #expect(authoredReport["deckCount"] as? Int == 1)
    #expect(authoredReport["createdItemTypeCount"] as? Int == 1)
    #expect(authoredReport["warnings"] as? [String] == [])
    let authoredCommit = await api.handle(request(
        .post,
        "/v1/imports/\(authoredID)/commits",
        headers: auth.merging([
            "Idempotency-Key": "authored-import",
            "If-Match": try #require(authoredValidation.headers["ETag"]),
        ]) { _, new in new },
        body: #"{"planToken":"\#(authoredPlan)"}"#
    ))
    #expect(authoredCommit.status == 200)
    let committedAuthoredReport = try #require(
        try jsonObject(authoredCommit)["report"] as? [String: Any]
    )
    #expect(committedAuthoredReport["itemCount"] as? Int == authoredReport["itemCount"] as? Int)
    #expect(committedAuthoredReport["deckCount"] as? Int == authoredReport["deckCount"] as? Int)
    #expect(
        committedAuthoredReport["createdItemTypeCount"] as? Int
            == authoredReport["createdItemTypeCount"] as? Int
    )

    let exportDeck = try await store.createDeck(Deck(name: "Portable API"))
    _ = try await store.createItem(Item(
        itemTypeID: BuiltInItemTypes.basicID,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Portable")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Round trip")),
        ],
        deckID: exportDeck.id
    ))
    let export = await api.handle(request(
        .post,
        "/v1/exports",
        headers: auth,
        body: #"{"format":"portableDeck","deckId":"\#(exportDeck.id.uuidString.lowercased())"}"#
    ))
    #expect(export.status == 201)
    let exportID = try #require(try jsonObject(export)["id"] as? String)
    let content = await api.handle(request(
        .get, "/v1/exports/\(exportID)/content", headers: auth
    ))
    #expect(content.status == 200)
    #expect(content.body.starts(with: Data("SQLite format 3\0".utf8)))

    let (destinationAPI, destinationStore) = try await makeAPIAndStore()
    let destinationToken = try await pair(
        destinationAPI, scopes: ["library.import", "library.read"]
    )
    let portable = try await createImport(
        api: destinationAPI,
        token: destinationToken,
        format: "portableDeck",
        path: "source.neodeck",
        bytes: content.body
    )
    #expect(await upload(
        api: destinationAPI,
        token: destinationToken,
        importID: portable.id,
        fileID: portable.fileID,
        bytes: content.body
    ).status == 204)
    let portableAuth = ["Authorization": "Bearer \(destinationToken)"]
    let portableValidation = await destinationAPI.handle(request(
        .post, "/v1/imports/\(portable.id)/validations", headers: portableAuth
    ))
    #expect(portableValidation.status == 200)
    let portableReport = try #require(
        try jsonObject(portableValidation)["report"] as? [String: Any]
    )
    #expect(portableReport["itemCount"] as? Int == 1)
    #expect(portableReport["deckCount"] as? Int == 1)
    #expect(portableReport["createdItemTypeCount"] as? Int == 0)
    #expect(portableReport["reusedItemTypeCount"] as? Int == 1)
    #expect(portableReport["warnings"] as? [String] == [])
    let portableToken = try #require(
        try jsonObject(portableValidation)["planToken"] as? String
    )
    let portableCommit = await destinationAPI.handle(request(
        .post,
        "/v1/imports/\(portable.id)/commits",
        headers: portableAuth.merging([
            "Idempotency-Key": "portable-import",
            "If-Match": try #require(portableValidation.headers["ETag"]),
        ]) { _, new in new },
        body: #"{"planToken":"\#(portableToken)"}"#
    ))
    #expect(portableCommit.status == 200)
    #expect(try await destinationStore.itemRecords().contains { record in
        record.item.fields.contains { $0.value == .text("Portable") }
    })

    #expect(await api.handle(request(
        .delete,
        "/v1/exports/\(exportID)",
        headers: auth.merging(["If-Match": try #require(export.headers["ETag"])]) { _, new in new }
    )).status == 204)
    #expect(await api.handle(request(
        .get, "/v1/exports/\(exportID)/content", headers: auth
    )).status == 404)
}

@Test func transferJobsAndPrivateStagingSurviveAPIServiceRestart() async throws {
    let databaseURL = apiTestDatabaseURL()
    let store = try ItemStore(databaseURL: databaseURL)
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
    let token = try await pair(
        firstService,
        scopes: ["library.import", "library.export"]
    )
    let auth = ["Authorization": "Bearer \(token)"]
    let importBytes = Data(#"{"itemType":"Basic","rows":[]}"#.utf8)
    let importManifest: [String: Any] = [
        "format": "json",
        "files": [[
            "relativePath": "items.json",
            "byteSize": importBytes.count,
            "sha256": APICrypto.sha256Hex(importBytes),
        ]],
    ]
    let createdImport = await firstService.handle(APIRequest(
        method: .post,
        path: "/v1/imports",
        headers: [
            "Host": "127.0.0.1:8766",
            "Authorization": "Bearer \(token)",
        ],
        body: try JSONSerialization.data(withJSONObject: importManifest, options: [.sortedKeys])
    ))
    #expect(createdImport.status == 201)
    let importObject = try jsonObject(createdImport)
    let importID = try #require(importObject["id"] as? String)
    let importFiles = try #require(importObject["files"] as? [[String: Any]])
    let fileID = try #require(importFiles.first?["id"] as? String)
    let upload = await firstService.handle(APIRequest(
        method: .put,
        path: "/v1/imports/\(importID)/files/\(fileID)",
        headers: [
            "Host": "127.0.0.1:8766",
            "Authorization": "Bearer \(token)",
            "If-Match": try #require(createdImport.headers["ETag"]),
        ],
        body: importBytes
    ))
    #expect(upload.status == 204)

    let deck = try await store.createDeck(Deck(name: "Restart export"))
    let createdExport = await firstService.handle(request(
        .post,
        "/v1/exports",
        headers: auth,
        body: #"{"format":"portableDeck","deckId":"\#(deck.id.uuidString.lowercased())"}"#
    ))
    #expect(createdExport.status == 201)
    let exportID = try #require(try jsonObject(createdExport)["id"] as? String)
    let expectedExportBytes = await firstService.handle(request(
        .get, "/v1/exports/\(exportID)/content", headers: auth
    )).body

    let stateURL = await store.localAPITransferStateURL()
    let attributes = try FileManager.default.attributesOfItem(atPath: stateURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

    let restartedService = service()
    let restoredImport = await restartedService.handle(request(
        .get, "/v1/imports/\(importID)", headers: auth
    ))
    #expect(restoredImport.status == 200)
    let restoredFiles = try #require(try jsonObject(restoredImport)["files"] as? [[String: Any]])
    #expect(restoredFiles.first?["uploaded"] as? Bool == true)

    let restoredExport = await restartedService.handle(request(
        .get, "/v1/exports/\(exportID)/content", headers: auth
    ))
    #expect(restoredExport.status == 200)
    #expect(restoredExport.body == expectedExportBytes)

    #expect(await restartedService.handle(request(
        .delete,
        "/v1/imports/\(importID)",
        headers: auth.merging(["If-Match": try #require(restoredImport.headers["ETag"])]) {
            _, new in new
        }
    )).status == 204)
    let restoredExportStatus = await restartedService.handle(request(
        .get, "/v1/exports/\(exportID)", headers: auth
    ))
    #expect(await restartedService.handle(request(
        .delete,
        "/v1/exports/\(exportID)",
        headers: auth.merging([
            "If-Match": try #require(restoredExportStatus.headers["ETag"]),
        ]) { _, new in new }
    )).status == 204)

    let afterDeletionRestart = service()
    let missing = await afterDeletionRestart.handle(request(
        .get, "/v1/imports/\(importID)", headers: auth
    ))
    #expect(missing.status == 404)
    #expect(try jsonObject(missing)["code"] as? String == "resource_not_found")
}

@Test func expiredTransferJobsRemoveStagedInputAndOutput() async throws {
    let store = try ItemStore(databaseURL: apiTestDatabaseURL())
    try await store.bootstrap()
    let authorization = APIAuthorizationStore(
        persistence: InMemoryAPICredentialPersistence()
    )
    let service = NeoAnkiAPIService(
        store: store,
        authorization: authorization,
        pairingApprover: ApproveAllPairings(),
        applicationVersion: "test"
    )
    let token = try await pair(
        service,
        scopes: ["library.import", "library.export"]
    )
    let auth = ["Authorization": "Bearer \(token)"]
    let stagedBytes = Data("private-expiring-import-payload".utf8)
    let manifest: [String: Any] = [
        "format": "json",
        "files": [[
            "relativePath": "items.json",
            "byteSize": stagedBytes.count,
            "sha256": APICrypto.sha256Hex(stagedBytes),
        ]],
    ]
    let createdImport = await service.handle(APIRequest(
        method: .post,
        path: "/v1/imports",
        headers: [
            "Host": "127.0.0.1:8766",
            "Authorization": "Bearer \(token)",
        ],
        body: try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
    ))
    let importObject = try jsonObject(createdImport)
    let importID = try #require(importObject["id"] as? String)
    let fileID = try #require(
        (importObject["files"] as? [[String: Any]])?.first?["id"] as? String
    )
    #expect(await service.handle(APIRequest(
        method: .put,
        path: "/v1/imports/\(importID)/files/\(fileID)",
        headers: [
            "Host": "127.0.0.1:8766",
            "Authorization": "Bearer \(token)",
            "If-Match": try #require(createdImport.headers["ETag"]),
        ],
        body: stagedBytes
    )).status == 204)

    let deck = try await store.createDeck(Deck(name: "Expiring export"))
    let createdExport = await service.handle(request(
        .post,
        "/v1/exports",
        headers: auth,
        body: #"{"format":"portableDeck","deckId":"\#(deck.id.uuidString.lowercased())"}"#
    ))
    let exportID = try #require(try jsonObject(createdExport)["id"] as? String)

    let expiringService = NeoAnkiAPIService(
        store: store,
        authorization: authorization,
        pairingApprover: ApproveAllPairings(),
        applicationVersion: "test",
        transferJobLifetime: -1
    )
    let missingImport = await expiringService.handle(request(
        .get, "/v1/imports/\(importID)", headers: auth
    ))
    let missingExport = await expiringService.handle(request(
        .get, "/v1/exports/\(exportID)/content", headers: auth
    ))
    #expect(missingImport.status == 404)
    #expect(missingExport.status == 404)

    let persisted = try Data(contentsOf: await store.localAPITransferStateURL())
    #expect(persisted.range(of: stagedBytes) == nil)
}

@Test func importCommitRecoversAcrossAllProcessExitBoundaries() async throws {
    for (index, point) in [
        APIFaultPoint.importBeforeDomainCommit,
        .importAfterDomainCommit,
        .importAfterCompletedJobPersisted,
    ].enumerated() {
        let store = try ItemStore(databaseURL: apiTestDatabaseURL())
        try await store.bootstrap()
        let authorization = APIAuthorizationStore(
            persistence: InMemoryAPICredentialPersistence()
        )
        let faultedService = NeoAnkiAPIService(
            store: store,
            authorization: authorization,
            pairingApprover: ApproveAllPairings(),
            applicationVersion: "test",
            faultInjector: ConfiguredAPIFaultInjector(point: point)
        )
        let token = try await pair(faultedService, scopes: ["library.import"])
        let auth = ["Authorization": "Bearer \(token)"]
        let bytes = Data(
            #"{"itemType":"Basic","rows":[{"Front":"Boundary","Back":"\#(index)"}]}"#.utf8
        )
        let manifest: [String: Any] = [
            "format": "json",
            "files": [[
                "relativePath": "items.json",
                "byteSize": bytes.count,
                "sha256": APICrypto.sha256Hex(bytes),
            ]],
        ]
        let created = await faultedService.handle(APIRequest(
            method: .post,
            path: "/v1/imports",
            headers: [
                "Host": "127.0.0.1:8766",
                "Authorization": "Bearer \(token)",
            ],
            body: try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        ))
        let createdObject = try jsonObject(created)
        let importID = try #require(createdObject["id"] as? String)
        let fileID = try #require(
            (createdObject["files"] as? [[String: Any]])?.first?["id"] as? String
        )
        let uploaded = await faultedService.handle(APIRequest(
            method: .put,
            path: "/v1/imports/\(importID)/files/\(fileID)",
            headers: [
                "Host": "127.0.0.1:8766",
                "Authorization": "Bearer \(token)",
                "If-Match": try #require(created.headers["ETag"]),
            ],
            body: bytes
        ))
        #expect(uploaded.status == 204)
        let statusAfterUpload = await faultedService.handle(request(
            .get, "/v1/imports/\(importID)", headers: auth
        ))
        let validated = await faultedService.handle(request(
            .post, "/v1/imports/\(importID)/validations", headers: auth
        ))
        #expect(validated.status == 200)
        #expect(statusAfterUpload.headers["ETag"] != validated.headers["ETag"])
        let planToken = try #require(try jsonObject(validated)["planToken"] as? String)
        let key = "import-boundary-\(index)"
        let commitHeaders = auth.merging([
            "Idempotency-Key": key,
            "If-Match": try #require(validated.headers["ETag"]),
        ]) { _, new in new }
        let commitBody = #"{"planToken":"\#(planToken)"}"#
        let interrupted = await faultedService.handle(request(
            .post,
            "/v1/imports/\(importID)/commits",
            headers: commitHeaders,
            body: commitBody
        ))
        #expect(interrupted.status == 500)
        let countBeforeRecovery = try await store.itemRecords().filter { record in
            record.item.value(for: BuiltInItemTypes.frontFieldID) == .text("Boundary")
        }.count
        #expect(countBeforeRecovery == (index == 0 ? 0 : 1))

        let restartedService = NeoAnkiAPIService(
            store: store,
            authorization: authorization,
            pairingApprover: ApproveAllPairings(),
            applicationVersion: "test"
        )
        let recovered = await restartedService.handle(request(
            .post,
            "/v1/imports/\(importID)/commits",
            headers: commitHeaders,
            body: commitBody
        ))
        #expect(recovered.status == 200)
        #expect(try jsonObject(recovered)["state"] as? String == "completed")
        #expect(try await store.itemRecords().filter { record in
            record.item.value(for: BuiltInItemTypes.frontFieldID) == .text("Boundary")
        }.count == 1)
        let replay = await restartedService.handle(request(
            .post,
            "/v1/imports/\(importID)/commits",
            headers: commitHeaders,
            body: commitBody
        ))
        #expect(replay.body == recovered.body)
    }
}

@Test func exportCreationRecoversAcrossAllProcessExitBoundaries() async throws {
    for (index, point) in [
        APIFaultPoint.exportAfterPendingJobPersisted,
        .exportAfterOutputGenerated,
        .exportAfterCompletedJobPersisted,
    ].enumerated() {
        let store = try ItemStore(databaseURL: apiTestDatabaseURL())
        try await store.bootstrap()
        let deck = try await store.createDeck(Deck(name: "Export boundary \(index)"))
        _ = try await store.createItem(Item(
            itemTypeID: BuiltInItemTypes.basicID,
            fields: [
                FieldValue(
                    fieldID: BuiltInItemTypes.frontFieldID,
                    value: .text("Boundary")
                ),
                FieldValue(
                    fieldID: BuiltInItemTypes.backFieldID,
                    value: .text("\(index)")
                ),
            ],
            deckID: deck.id
        ))
        let authorization = APIAuthorizationStore(
            persistence: InMemoryAPICredentialPersistence()
        )
        func service(
            faultInjector: any APIFaultInjector = NoAPIFaultInjector()
        ) -> NeoAnkiAPIService {
            NeoAnkiAPIService(
                store: store,
                authorization: authorization,
                pairingApprover: ApproveAllPairings(),
                applicationVersion: "test",
                faultInjector: faultInjector
            )
        }
        let faultedService = service(
            faultInjector: ConfiguredAPIFaultInjector(point: point)
        )
        let token = try await pair(faultedService, scopes: ["library.export"])
        let key = "export-boundary-\(index)"
        let body = Data(
            #"{"format":"portableDeck","deckId":"\#(deck.id.uuidString.lowercased())"}"#.utf8
        )
        func create(using api: NeoAnkiAPIService) async -> APIResponse {
            await api.handle(APIRequest(
                method: .post,
                path: "/v1/exports",
                headers: [
                    "Host": "127.0.0.1:8766",
                    "Authorization": "Bearer \(token)",
                    "Idempotency-Key": key,
                ],
                body: body
            ))
        }

        #expect(await create(using: faultedService).status == 500)
        let grant = try #require(try await authorization.authenticate(token: token))
        let requestHash = try APIJSON.canonicalRequestHash(
            method: .post,
            path: "/v1/exports",
            body: body
        )
        let pending = try #require(try await store.idempotencyClaim(
            clientID: grant.id,
            route: "POST /v1/exports",
            key: key,
            requestHash: requestHash
        ))
        let exportID: String
        switch pending {
        case let .pending(resultResourceID):
            exportID = try #require(resultResourceID)
        default:
            Issue.record("The interrupted export must retain its pending claim.")
            continue
        }

        let restartedService = service()
        let recovered = await create(using: restartedService)
        #expect(recovered.status == 201)
        #expect(try jsonObject(recovered)["id"] as? String == exportID)
        #expect(try jsonObject(recovered)["state"] as? String == "completed")
        #expect(await create(using: restartedService).body == recovered.body)

        let content = await restartedService.handle(request(
            .get,
            "/v1/exports/\(exportID)/content",
            headers: ["Authorization": "Bearer \(token)"]
        ))
        #expect(content.status == 200)
        #expect(!content.body.isEmpty)
        let secondRestart = service()
        #expect(await secondRestart.handle(request(
            .get,
            "/v1/exports/\(exportID)/content",
            headers: ["Authorization": "Bearer \(token)"]
        )).body == content.body)
    }
}
