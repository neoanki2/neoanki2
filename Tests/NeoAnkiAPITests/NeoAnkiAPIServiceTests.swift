import Foundation
@testable import NeoAnkiAPI
import NeoAnkiCore
import Testing

private actor BlockingPairingApprover: APIPairingApprover {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var started = false
    private(set) var completed = false
    private(set) var requestedApproval: APIPairingRequest?
    private(set) var cancelledRequest: APIPairingRequest?

    func approve(_ request: APIPairingRequest) async -> Bool {
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        requestedApproval = request
        defer { completed = true }
        // The expiry task may win before the approval task enters this actor.
        if cancelledRequest != nil { return false }
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func cancel(_ request: APIPairingRequest) {
        cancelledRequest = request
        continuation?.resume(returning: false)
        continuation = nil
    }

    func resolve(_ approved: Bool) {
        continuation?.resume(returning: approved)
        continuation = nil
    }
}

@Test func discoveryIsBoundedAndProtectedRoutesRequireAuthentication() async throws {
    let api = try await makeAPI()

    let health = await api.handle(request(.get, "/health"))
    #expect(health.status == 200)
    #expect(try jsonObject(health)["status"] as? String == "ok")
    #expect(health.headers["Cache-Control"] == "no-store")

    let metadata = await api.handle(request(.get, "/v1/meta"))
    #expect(metadata.status == 200)
    #expect(try jsonObject(metadata)["apiVersion"] as? Int == 1)

    let denied = await api.handle(request(.get, "/v1/decks"))
    #expect(denied.status == 401)
    #expect(try jsonObject(denied)["code"] as? String == "unauthorized")

    let foreignHost = await api.handle(
        request(.get, "/health", headers: ["Host": "attacker.invalid"])
    )
    #expect(foreignHost.status == 403)
    #expect(try jsonObject(foreignHost)["code"] as? String == "invalid_host")

    let credentialQuery = await api.handle(APIRequest(
        method: .get,
        path: "/health",
        query: ["access_token": ["must-not-be-accepted"]],
        headers: ["Host": "127.0.0.1:8766"]
    ))
    #expect(credentialQuery.status == 422)
    #expect(try jsonObject(credentialQuery)["code"] as? String == "validation_failed")

    let readToken = try await pair(api, scopes: ["library.read"])
    let duplicateScalarQuery = await api.handle(APIRequest(
        method: .get,
        path: "/v1/decks",
        query: ["limit": ["1", "2"]],
        headers: [
            "Host": "127.0.0.1:8766",
            "Authorization": "Bearer \(readToken)",
        ]
    ))
    #expect(duplicateScalarQuery.status == 422)

    let bodyOnBodylessRoute = await api.handle(request(
        .get, "/v1/meta", body: #"{"ignored":true}"#
    ))
    #expect(bodyOnBodylessRoute.status == 422)
}

@Test func openAPIDocumentDeclaresTheCompleteVersionOneRouteInventory() throws {
    let root = try #require(
        JSONSerialization.jsonObject(with: APIOpenAPI.document) as? [String: Any]
    )
    #expect(root["openapi"] as? String == "3.1.0")
    let paths = try #require(root["paths"] as? [String: [String: Any]])
    let actual = Set(paths.flatMap { path, item in
        item.keys.map { "\($0.uppercased()) \(path)" }
    })
    let registered = Set(APIOpenAPI.endpoints.map {
        "\($0.method.rawValue) \($0.pathTemplate)"
    })
    #expect(actual == registered)
    #expect(Set(APIOpenAPI.endpoints.map(\.handler)) == Set(APIEndpointHandler.allCases))
    #expect(APIOpenAPI.endpoints.count == APIEndpointHandler.allCases.count)
    #expect(Set(APIOpenAPI.endpoints.map(\.operationID)).count == APIOpenAPI.endpoints.count)

    let vocabularySearchPath = try #require(
        paths["/v1/vocabulary-packs/{id}/entries"]
    )
    let vocabularySearch = try #require(vocabularySearchPath["get"] as? [String: Any])
    #expect(vocabularySearch["x-required-scope"] as? String == "vocabulary.read")
    let searchParameters = try #require(
        vocabularySearch["parameters"] as? [[String: Any]]
    )
    let queryParameter = try #require(searchParameters.first {
        $0["name"] as? String == "query"
    })
    #expect(queryParameter["required"] as? Bool == true)

    let commitPath = try #require(
        paths["/v1/vocabulary-pack-imports/{id}/commits"]
    )
    let commit = try #require(commitPath["post"] as? [String: Any])
    #expect(commit["x-required-scope"] as? String == "vocabulary.write")
    let commitParameters = try #require(commit["parameters"] as? [[String: Any]])
    #expect(commitParameters.contains {
        $0["name"] as? String == "If-Match" && $0["required"] as? Bool == true
    })
    #expect(commitParameters.contains {
        $0["name"] as? String == "Idempotency-Key" && $0["required"] as? Bool == true
    })

    let components = try #require(root["components"] as? [String: Any])
    let schemas = try #require(components["schemas"] as? [String: Any])
    #expect(schemas["Object"] == nil)
    #expect(schemas["Resource"] == nil)
    #expect(schemas["VocabularyPack"] != nil)
    #expect(schemas["LexicalEntry"] != nil)
    #expect(schemas["VocabularyPackImport"] != nil)

    var references: [String] = []
    func collectReferences(_ value: Any) {
        if let dictionary = value as? [String: Any] {
            if let reference = dictionary["$ref"] as? String {
                references.append(reference)
            }
            dictionary.values.forEach(collectReferences)
        } else if let values = value as? [Any] {
            values.forEach(collectReferences)
        }
    }
    collectReferences(root)
    for reference in references {
        let prefix = "#/components/schemas/"
        #expect(reference.hasPrefix(prefix))
        #expect(schemas[String(reference.dropFirst(prefix.count))] != nil)
    }

    for (_, pathItem) in paths {
        for (_, rawOperation) in pathItem {
            let operation = try #require(rawOperation as? [String: Any])
            #expect((operation["summary"] as? String)?.isEmpty == false)
            #expect((operation["description"] as? String)?.isEmpty == false)
            #expect((operation["tags"] as? [String])?.count == 1)
            #expect((operation["x-codeSamples"] as? [[String: Any]])?.isEmpty == false)
            #expect(APIEndpointHandler(rawValue: operation["operationId"] as? String ?? "") != nil)
            for parameter in operation["parameters"] as? [[String: Any]] ?? [] {
                #expect((parameter["description"] as? String)?.isEmpty == false)
            }
            let responses = try #require(operation["responses"] as? [String: Any])
            #expect(responses["default"] != nil)
            #expect(responses.keys.contains { Int($0).map { (200 ..< 300).contains($0) } == true })
        }
    }

    for endpoint in APIOpenAPI.endpoints {
        #expect(!endpoint.description.isEmpty)
        #expect(!endpoint.errorResponses.isEmpty)
        #expect(endpoint.parameters.allSatisfy { !$0.description.isEmpty })
    }
}

@Test func representativeEncodedDTOsMatchTheirDeclaredSchemaKeys() throws {
    let root = try #require(
        JSONSerialization.jsonObject(with: APIOpenAPI.document) as? [String: Any]
    )
    let components = try #require(root["components"] as? [String: Any])
    let schemas = try #require(components["schemas"] as? [String: Any])

    func expectSchemaKeys<T: Encodable>(
        _ value: T,
        schema name: String
    ) throws {
        let schema = try #require(schemas[name] as? [String: Any])
        let properties = Set(try #require((schema["properties"] as? [String: Any])?.keys))
        let required = Set(schema["required"] as? [String] ?? [])
        let encoded = try #require(
            JSONSerialization.jsonObject(with: APIJSON.encoder.encode(value)) as? [String: Any]
        )
        let keys = Set(encoded.keys)
        #expect(keys.isSubset(of: properties))
        #expect(required.isSubset(of: keys))
    }

    try expectSchemaKeys(APIHealth(status: "ok"), schema: "Health")
    try expectSchemaKeys(APIMeta(
        apiVersion: 1,
        applicationVersion: "test",
        serverInstanceId: "00000000-0000-0000-0000-000000000001",
        pairingAvailable: true,
        capabilities: ["decks.read"]
    ), schema: "Meta")
    try expectSchemaKeys(APIProblem(
        status: 403,
        code: "insufficient_scope",
        title: "Insufficient scope",
        detail: "A scope is required.",
        requestID: "00000000-0000-0000-0000-000000000002",
        requiredScope: "library.read"
    ), schema: "Problem")
}

@Test func runtimeOpenAPIDocumentIsTheRegistryDocument() async throws {
    let api = try await makeAPI()
    let response = await api.handle(request(.get, "/v1/openapi.json"))
    #expect(response.status == 200)
    #expect(response.body == APIOpenAPI.document)
    #expect(response.headers["X-NeoAnki-Contract-Digest"] == APIOpenAPI.contractDigest)
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let published = try Data(contentsOf: repositoryRoot.appendingPathComponent(
        "docs/api/openapi.json"
    ))
    #expect(published == APIOpenAPI.document)
    #expect("sha256:" + APICrypto.sha256Hex(published) == APIOpenAPI.contractDigest)
}

@Test func pairingIssuesOneScopedTokenAndCurrentClientCanRevokeIt() async throws {
    let api = try await makeAPI()
    let token = try await pair(api, scopes: ["library.read"])
    #expect(token.count >= 43)

    let current = await api.handle(
        request(
            .get,
            "/v1/clients/current",
            headers: ["Authorization": "Bearer \(token)"]
        )
    )
    #expect(current.status == 200)
    let client = try jsonObject(current)
    #expect((client["id"] as? String)?.lowercased() == client["id"] as? String)
    #expect(client["scopes"] as? [String] == ["library.read"])

    let insufficient = await api.handle(
        request(
            .post,
            "/v1/decks",
            headers: [
                "Authorization": "Bearer \(token)",
                "Idempotency-Key": "one",
            ],
            body: "{\"name\":\"Test\"}"
        )
    )
    #expect(insufficient.status == 403)
    #expect(try jsonObject(insufficient)["code"] as? String == "insufficient_scope")

    let revoke = await api.handle(
        request(
            .delete,
            "/v1/clients/current",
            headers: [
                "Authorization": "Bearer \(token)",
                "If-Match": "\"revision-1\"",
            ]
        )
    )
    #expect(revoke.status == 204)
    let after = await api.handle(
        request(
            .get,
            "/v1/clients/current",
            headers: ["Authorization": "Bearer \(token)"]
        )
    )
    #expect(after.status == 401)
}

@Test func pairingLimitsExpiryValidationAndCredentialRedactionAreEnforced() async throws {
    let store = try ItemStore(databaseURL: apiTestDatabaseURL(), starterItemTypes: [])
    try await store.bootstrap()
    let persistence = InMemoryAPICredentialPersistence()
    let authorization = APIAuthorizationStore(persistence: persistence)
    let blocker = BlockingPairingApprover()
    let blockedAPI = NeoAnkiAPIService(
        store: store,
        authorization: authorization,
        pairingApprover: blocker,
        applicationVersion: "test"
    )
    let pairingBody = #"{"displayName":"Browser","requestedScopes":["library.read","items.write","media.write"],"origin":"https://approved.example"}"#
    let firstTask = Task {
        await blockedAPI.handle(request(
            .post,
            "/v1/pairings",
            headers: ["Origin": "https://approved.example"],
            body: pairingBody
        ))
    }
    await blocker.waitUntilStarted()
    let overlapping = await blockedAPI.handle(request(
        .post,
        "/v1/pairings",
        headers: ["Origin": "https://approved.example"],
        body: pairingBody
    ))
    #expect(overlapping.status == 429)
    await blocker.resolve(true)
    let approved = await firstTask.value
    #expect(approved.status == 201)
    let approvedObject = try jsonObject(approved)
    let token = try #require(approvedObject["token"] as? String)
    var base64Token = token
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    base64Token += String(repeating: "=", count: (4 - base64Token.count % 4) % 4)
    #expect(Data(base64Encoded: base64Token)?.count == 32)
    let client = try #require(approvedObject["client"] as? [String: Any])
    #expect(Set(client["scopes"] as? [String] ?? []) == Set([
        "library.read", "items.write", "media.write",
    ]))
    let persistedCredentials = try #require(await persistence.load())
    #expect(!String(decoding: persistedCredentials, as: UTF8.self).contains(token))
    #expect(String(decoding: persistedCredentials, as: UTF8.self).contains(APICrypto.sha256Hex(Data(token.utf8))))

    let invalidName = await blockedAPI.handle(request(
        .post,
        "/v1/pairings",
        body: #"{"displayName":"bad\u0000name","requestedScopes":["library.read"]}"#
    ))
    #expect(invalidName.status == 422)
    let overlongName = String(repeating: "é", count: 129)
    let overlongBody = try JSONSerialization.data(withJSONObject: [
        "displayName": overlongName,
        "requestedScopes": ["library.read"],
    ])
    let overlong = await blockedAPI.handle(APIRequest(
        method: .post,
        path: "/v1/pairings",
        headers: ["Host": "127.0.0.1:8766"],
        body: overlongBody
    ))
    #expect(overlong.status == 422)

    let rateAPI = try await makeAPI()
    for index in 0 ..< 5 {
        let result = await rateAPI.handle(request(
            .post,
            "/v1/pairings",
            body: #"{"displayName":"Client \#(index)","requestedScopes":["library.read"]}"#
        ))
        #expect(result.status == 201)
    }
    let sixth = await rateAPI.handle(request(
        .post,
        "/v1/pairings",
        body: #"{"displayName":"Sixth","requestedScopes":["library.read"]}"#
    ))
    #expect(sixth.status == 429)

    let expiringStore = try ItemStore(databaseURL: apiTestDatabaseURL(), starterItemTypes: [])
    try await expiringStore.bootstrap()
    let expiringApprover = BlockingPairingApprover()
    let expiringAPI = NeoAnkiAPIService(
        store: expiringStore,
        authorization: APIAuthorizationStore(
            persistence: InMemoryAPICredentialPersistence()
        ),
        pairingApprover: expiringApprover,
        applicationVersion: "test",
        pairingRequestLifetime: 0
    )
    let expired = await expiringAPI.handle(request(
        .post,
        "/v1/pairings",
        body: #"{"displayName":"Expires","requestedScopes":["library.read"]}"#
    ))
    #expect(expired.status == 403)
    #expect(try jsonObject(expired)["code"] as? String == "pairing_denied")
    #expect(await expiringApprover.started)
    #expect(await expiringApprover.completed)
    let expiredRequest = APIPairingRequest(displayName: "Expires", origin: nil, requestedScopes: [.libraryRead])
    #expect(await expiringApprover.requestedApproval == expiredRequest)
    #expect(await expiringApprover.cancelledRequest == expiredRequest)
}

@Test func verifierFilePersistsOnlyTokenHashesWithPrivatePermissions() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "neoanki-api-verifiers-\(UUID().uuidString)", isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory
        .appendingPathComponent(".neoanki-api", isDirectory: true)
        .appendingPathComponent(VerifierFileAPICredentialPersistence.fileName)
    let authorization = APIAuthorizationStore(
        persistence: VerifierFileAPICredentialPersistence(fileURL: fileURL)
    )

    let issued = try await authorization.issueGrant(
        displayName: "Durable client",
        origin: "https://approved.example",
        scopes: [.libraryRead, .itemsWrite]
    )
    let persisted = try Data(contentsOf: fileURL)
    let persistedText = String(decoding: persisted, as: UTF8.self)
    #expect(!persistedText.contains(issued.token))
    #expect(persistedText.contains(APICrypto.sha256Hex(Data(issued.token.utf8))))

    let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let directoryAttributes = try FileManager.default.attributesOfItem(
        atPath: fileURL.deletingLastPathComponent().path
    )
    #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    #expect(try fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)

    let reopened = APIAuthorizationStore(
        persistence: VerifierFileAPICredentialPersistence(fileURL: fileURL)
    )
    let restoredGrant = try #require(try await reopened.authenticate(token: issued.token))
    #expect(restoredGrant.id == issued.grant.id)
    #expect(restoredGrant.displayName == issued.grant.displayName)
    #expect(restoredGrant.origin == issued.grant.origin)
    #expect(restoredGrant.scopes == issued.grant.scopes)
    #expect(try await reopened.revoke(clientID: issued.grant.id))

    let afterRevocation = APIAuthorizationStore(
        persistence: VerifierFileAPICredentialPersistence(fileURL: fileURL)
    )
    #expect(try await afterRevocation.authenticate(token: issued.token) == nil)
}

@Test func verifierFileRejectsInsecureOrUnexpectedFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "neoanki-api-verifier-security-\(UUID().uuidString)", isDirectory: true
    )
    let directory = root.appendingPathComponent(".neoanki-api", isDirectory: true)
    let fileURL = directory.appendingPathComponent(
        VerifierFileAPICredentialPersistence.fileName,
        isDirectory: false
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    try Data("[]".utf8).write(to: fileURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o644],
        ofItemAtPath: fileURL.path
    )
    let insecure = VerifierFileAPICredentialPersistence(fileURL: fileURL)
    await #expect(throws: APIAuthorizationError.self) {
        try await insecure.load()
    }

    try FileManager.default.removeItem(at: fileURL)
    let targetURL = root.appendingPathComponent("target.json")
    try Data("[]".utf8).write(to: targetURL)
    try FileManager.default.createSymbolicLink(at: fileURL, withDestinationURL: targetURL)
    let symbolicLink = VerifierFileAPICredentialPersistence(fileURL: fileURL)
    await #expect(throws: APIAuthorizationError.self) {
        try await symbolicLink.load()
    }
}

@Test func resolvedCardContentMatchesCoreForEveryInteraction() async throws {
    let (api, store) = try await makeAPIAndStore()
    let token = try await pair(api, scopes: ["library.read"])
    let auth = ["Authorization": "Bearer \(token)"]

    for (index, interaction) in Interaction.allCases.enumerated() {
        let promptField = FieldDef(
            name: "Prompt",
            type: interaction == .cloze ? .cloze : interaction == .imageOcclusion ? .imageOcclusion : .text,
            isRequired: true
        )
        let answerField = FieldDef(name: "Answer", type: .text, isRequired: true)
        let answer = interaction == .audioSubmission
            ? Side(slots: [])
            : Side(slots: [
                Slot(source: .literal("Answer:")),
                Slot(
                    source: .field(answerField.id),
                    presentation: Presentation(reveal: .hiddenUntilAnswer)
                ),
            ])
        let template = Template(
            name: interaction.rawValue,
            prompt: Side(slots: [Slot(
                source: .field(promptField.id),
                presentation: Presentation(reveal: .blurred)
            )]),
            answer: answer,
            interaction: interaction,
            skill: Skill(
                input: .text,
                output: interaction == .audioSubmission ? .audio : .text,
                operation: .recall
            )
        )
        let type = ItemType(
            name: "Interaction \(index)",
            fields: [promptField, answerField],
            templates: [template]
        )
        _ = try await store.createItemType(type)
        let promptValue: ContentValue
        if interaction == .imageOcclusion {
            let reservation = try await store.reserveMedia(data: Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), kind: .image, altText: "Diagram")
            var content = ImageOcclusionContent(image: reservation.reference)
            content.addMask(rect: .init(x: 0.1, y: 0.2, width: 0.3, height: 0.2))
            promptValue = .imageOcclusion(content)
        } else if interaction == .cloze {
            promptValue = .cloze("One two", blanks: [ClozeSpan(group: 1, start: 4, length: 3)])
        } else { promptValue = .text("Prompt \(index)") }
        let item = Item(
            itemTypeID: type.id,
            fields: [
                FieldValue(fieldID: promptField.id, value: promptValue),
                FieldValue(fieldID: answerField.id, value: .text("Answer \(index)")),
            ]
        )
        _ = try await store.createItem(item)
        let card = try #require(try await store.cards().first { $0.itemID == item.id })
        let response = await api.handle(request(
            .get,
            "/v1/cards/\(card.id.uuidString.lowercased())/content",
            headers: auth
        ))
        #expect(response.status == 200)
        let representation = try APIJSON.decoder.decode(APIStudyCard.self, from: response.body)
        let expectedComponents = SideContent.resolvedComponents(for: template, from: item)
        let expectedPrompt = SideContent.resolvedSlots(for: template.prompt, from: item)
        let expectedAnswer = SideContent.resolvedSlots(for: template.answer, from: item)
        #expect(representation.interaction == interaction.rawValue)
        #expect(representation.layout == template.layout.rawValue)
        #expect(representation.components.map(\.value) == expectedComponents.map(\.value))
        #expect(representation.components.map(\.region) == expectedComponents.map { $0.region.rawValue })
        #expect(representation.components.map(\.purpose) == expectedComponents.map { $0.purpose.rawValue })
        #expect(representation.prompt.map(\.value) == expectedPrompt.map(\.value))
        #expect(representation.prompt.map(\.presentation) == expectedPrompt.map(\.presentation))
        #expect(representation.answer.map(\.value) == expectedAnswer.map(\.value))
        #expect(representation.answer.map(\.presentation) == expectedAnswer.map(\.presentation))
    }
}

@Test func templateAPIProjectionKeepsPromptAndAnswerPurposeBasedAndOrdered() throws {
    let frontID = UUID(uuidString: "51000000-0000-4000-8000-000000000001")!
    let backID = UUID(uuidString: "51000000-0000-4000-8000-000000000002")!
    let components = [
        TemplateComponent(
            id: UUID(uuidString: "52000000-0000-4000-8000-000000000001")!,
            region: .primary,
            purpose: .expectedAnswer,
            source: .field(backID),
            presentation: Presentation(reveal: .blurred)
        ),
        TemplateComponent(
            id: UUID(uuidString: "52000000-0000-4000-8000-000000000002")!,
            region: .label,
            purpose: .supporting,
            source: .literal("Instruction")
        ),
        TemplateComponent(
            id: UUID(uuidString: "52000000-0000-4000-8000-000000000003")!,
            region: .secondary,
            purpose: .question,
            source: .field(frontID)
        ),
    ]
    let template = Template(
        id: UUID(uuidString: "53000000-0000-4000-8000-000000000001")!,
        name: "API Contract",
        layout: .actionStage,
        components: components,
        interaction: .type,
        skill: Skill(input: .text, output: .freeResponse, operation: .recall),
        generateWhen: .any([.fieldNotEmpty(frontID), .fieldEmpty(backID)]),
        fitStudyArea: true
    )

    let representation = APITemplateDefinition(template)
    #expect(representation.layout == "actionStage")
    #expect(representation.fitStudyArea == true)
    #expect(representation.components?.map(\.id) == components.map { $0.id.uuidString.lowercased() })
    #expect(representation.prompt.map(\.source.kind) == ["literal", "field"])
    #expect(representation.prompt.map(\.source.text) == ["Instruction", nil])
    #expect(representation.prompt.map(\.source.fieldId) == [nil, frontID.uuidString.lowercased()])
    #expect(representation.answer.map(\.source.fieldId) == [backID.uuidString.lowercased()])
    #expect(representation.answer.map(\.presentation.reveal) == ["blurred"])

    let roundTrip = try representation.domain(
        parseUUID: { value, _ in try #require(UUID(uuidString: value)) },
        pointer: "/templates/0"
    )
    #expect(roundTrip == template)
}

@Test func studyResponseAPIProtectsPrivateAudioAndSupportsKeysetAndIdempotentDeletion() async throws {
    let (api, store) = try await makeAPIAndStore()
    let prompt = FieldDef(name: "Prompt", type: .text, isRequired: true)
    let template = Template(
        name: "Spoken response",
        prompt: Side(slots: [Slot(source: .field(prompt.id))]),
        answer: Side(slots: []),
        interaction: .audioSubmission,
        skill: Skill(input: .text, output: .audio, operation: .explain)
    )
    let itemType = ItemType(name: "Spoken", fields: [prompt], templates: [template])
    _ = try await store.createItemType(itemType)

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-response-api-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data([0x00, 0x00, 0x00, 0x18] + Array("ftypM4A ".utf8))

    var created: [StudyResponse] = []
    for index in 0 ..< 2 {
        let item = Item(
            itemTypeID: itemType.id,
            fields: [FieldValue(fieldID: prompt.id, value: .text("Prompt \(index)"))],
            tags: ["private-speaking"]
        )
        _ = try await store.createItem(item)
        let card = try #require(try await store.cards().first { $0.itemID == item.id })
        let file = root.appendingPathComponent("draft-\(index).m4a")
        try bytes.write(to: file)
        created.append(try await store.completeAudioSubmission(
            StudyResponseDraft(
                cardID: card.id,
                fileURL: file,
                durationMilliseconds: 10_000 + index,
                capturedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
            ),
            submittedAt: Date(timeIntervalSince1970: 1_800_000_100 + Double(index))
        ))
    }

    let ordinaryToken = try await pair(api, scopes: ["library.read"])
    let readToken = try await pair(api, scopes: ["study.responses.read"])
    let deleteToken = try await pair(api, scopes: ["study.responses.delete"])
    func auth(_ token: String) -> [String: String] {
        ["Authorization": "Bearer \(token)"]
    }

    #expect(await api.handle(request(
        .get, "/v1/study-responses", headers: auth(ordinaryToken)
    )).status == 403)

    let firstPage = await api.handle(APIRequest(
        method: .get,
        path: "/v1/study-responses",
        query: ["limit": ["1"], "tag": ["PRIVATE-SPEAKING"]],
        headers: [
            "Host": "127.0.0.1:8766",
            "Authorization": "Bearer \(readToken)",
        ]
    ))
    #expect(firstPage.status == 200)
    let firstObject = try jsonObject(firstPage)
    let firstData = try #require(firstObject["data"] as? [[String: Any]])
    #expect(firstData.count == 1)
    #expect(firstData[0]["reviewLogId"] == nil)
    let nextCursor = try #require((firstObject["page"] as? [String: Any])?["nextCursor"] as? String)
    let secondPage = await api.handle(APIRequest(
        method: .get,
        path: "/v1/study-responses",
        query: [
            "limit": ["1"], "tag": ["PRIVATE-SPEAKING"], "cursor": [nextCursor],
        ],
        headers: [
            "Host": "127.0.0.1:8766",
            "Authorization": "Bearer \(readToken)",
        ]
    ))
    #expect(secondPage.status == 200)
    #expect((try jsonObject(secondPage)["data"] as? [[String: Any]])?.count == 1)

    let targetID = try #require(firstData[0]["id"] as? String)
    let detail = await api.handle(request(
        .get, "/v1/study-responses/\(targetID)", headers: auth(readToken)
    ))
    #expect(detail.status == 200)
    let detailObject = try jsonObject(detail)
    let hash = try #require(detailObject["assetHash"] as? String)
    let content = await api.handle(request(
        .get, "/v1/study-responses/\(targetID)/content", headers: auth(readToken)
    ))
    #expect(content.status == 200)
    #expect(content.body == bytes)
    #expect(content.headers["Digest"] == "sha-256=\(hash)")
    #expect(await api.handle(request(
        .get, "/v1/media/\(hash)", headers: auth(ordinaryToken)
    )).status == 404)

    var deleteHeaders = auth(deleteToken)
    deleteHeaders["If-Match"] = detail.headers["ETag"]
    deleteHeaders["Idempotency-Key"] = "delete-private-response"
    let deleted = await api.handle(request(
        .delete, "/v1/study-responses/\(targetID)", headers: deleteHeaders
    ))
    #expect(deleted.status == 204)
    let retried = await api.handle(request(
        .delete, "/v1/study-responses/\(targetID)", headers: deleteHeaders
    ))
    #expect(retried.status == 204)
    #expect(await api.handle(request(
        .get, "/v1/study-responses/\(targetID)", headers: auth(readToken)
    )).status == 404)

    let sourceResponse = try #require(created.first { $0.id.uuidString.lowercased() != targetID })
    let itemToken = try await pair(api, scopes: ["library.read", "items.write"])
    let itemDetail = await api.handle(request(
        .get,
        "/v1/items/\(sourceResponse.itemID.uuidString.lowercased())",
        headers: auth(itemToken)
    ))
    var sourceDeleteHeaders = auth(itemToken)
    sourceDeleteHeaders["If-Match"] = itemDetail.headers["ETag"]
    let needsConfirmation = await api.handle(request(
        .delete,
        "/v1/items/\(sourceResponse.itemID.uuidString.lowercased())",
        headers: sourceDeleteHeaders
    ))
    #expect(needsConfirmation.status == 409)
    let problem = try jsonObject(needsConfirmation)
    #expect(problem["code"] as? String == "study_response_deletion_confirmation_required")
    #expect((problem["impact"] as? [String: Any])?["affectedStudyResponseCount"] as? Int == 1)
    sourceDeleteHeaders["NeoAnki-Impact-Token"] = try #require(problem["impactToken"] as? String)
    #expect(await api.handle(request(
        .delete,
        "/v1/items/\(sourceResponse.itemID.uuidString.lowercased())",
        headers: sourceDeleteHeaders
    )).status == 204)
    #expect(await api.handle(request(
        .get,
        "/v1/study-responses/\(sourceResponse.id.uuidString.lowercased())",
        headers: auth(readToken)
    )).status == 404)

    let ordinaryChanges = await api.handle(request(
        .get, "/v1/changes", headers: auth(ordinaryToken)
    ))
    let serialized = String(decoding: ordinaryChanges.body, as: UTF8.self)
    #expect(!serialized.contains("studyResponse"))
}

@Test func optionalIdempotencyReplaysOrdinaryMutationsAndRejectsDifferentInput() async throws {
    let (api, store) = try await makeAPIAndStore()
    let token = try await pair(api, scopes: ["library.read", "items.write"])
    let auth = ["Authorization": "Bearer \(token)"]
    let item = Item(
        itemTypeID: BuiltInItemTypes.basicID,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Front")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Back")),
        ],
        tags: ["source"]
    )
    _ = try await store.createItem(item)

    let tags = await api.handle(request(.get, "/v1/tags", headers: auth))
    let cursor = try await store.currentChangeCursor()
    let headers = auth.merging([
        "If-Match": try #require(tags.headers["ETag"]),
        "Idempotency-Key": "rename-once",
    ]) { _, new in new }
    let first = await api.handle(request(
        .post,
        "/v1/tag-renames",
        headers: headers,
        body: #"{"from":"source","to":"destination"}"#
    ))
    let replay = await api.handle(request(
        .post,
        "/v1/tag-renames",
        headers: headers,
        body: #"{"from":"source","to":"destination"}"#
    ))
    #expect(first.status == 200)
    #expect(replay.status == first.status)
    #expect(replay.body == first.body)
    #expect(try await store.itemRecord(id: item.id).item.tags == ["destination"])
    let changes = try await store.libraryChanges(after: cursor, limit: 20)
    #expect(changes.count == 1)

    let conflict = await api.handle(request(
        .post,
        "/v1/tag-renames",
        headers: headers,
        body: #"{"from":"source","to":"different"}"#
    ))
    #expect(conflict.status == 409)
    #expect(try jsonObject(conflict)["code"] as? String == "idempotency_conflict")
}

@Test func everyItemFilterMatchesTheNativeContractFixture() async throws {
    let (api, store) = try await makeAPIAndStore()
    let token = try await pair(api, scopes: ["library.read"])
    let root = try await store.createDeck(Deck(name: "Filter root"))
    let child = try await store.createDeck(Deck(name: "Filter child", parentID: root.id))
    let otherType = try await store.createItemType(ItemType(
        name: "Filter alternate",
        fields: BuiltInItemTypes.basic.fields,
        templates: BuiltInItemTypes.basic.templates
    ))
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    func basic(
        typeID: UUID = BuiltInItemTypes.basicID,
        deckID: UUID?,
        front: String,
        tags: [String]
    ) -> Item {
        Item(
            itemTypeID: typeID,
            fields: [
                FieldValue(
                    fieldID: BuiltInItemTypes.frontFieldID,
                    value: .text(front)
                ),
                FieldValue(
                    fieldID: BuiltInItemTypes.backFieldID,
                    value: .text("Answer \(front)")
                ),
            ],
            tags: tags,
            deckID: deckID
        )
    }
    let rootItem = try await store.createItem(
        basic(deckID: root.id, front: "Café root", tags: ["alpha", "beta"]),
        now: base
    )
    var childDomain = basic(
        deckID: child.id,
        front: "Nested child",
        tags: ["alpha", "gamma"]
    )
    let childItem = try await store.createItem(
        childDomain,
        now: base.addingTimeInterval(10)
    )
    let alternateItem = try await store.createItem(
        basic(
            typeID: otherType.id,
            deckID: nil,
            front: "Alternate",
            tags: ["beta"]
        ),
        now: base.addingTimeInterval(20)
    )
    childDomain.tags.append("updated")
    _ = try await store.updateItem(childDomain, now: base.addingTimeInterval(30))

    func timestamp(_ date: Date) throws -> String {
        let encoded = try APIJSON.encoder.encode(date)
        return try #require(String(data: encoded, encoding: .utf8))
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
    func filtered(_ query: [String: [String]]) async throws -> Set<String> {
        let response = await api.handle(APIRequest(
            method: .get,
            path: "/v1/items",
            query: query,
            headers: [
                "Host": "127.0.0.1:8766",
                "Authorization": "Bearer \(token)",
            ]
        ))
        #expect(response.status == 200)
        let rows = try #require(try jsonObject(response)["data"] as? [[String: Any]])
        return Set(rows.compactMap { $0["id"] as? String })
    }
    let rootID = rootItem.id.uuidString.lowercased()
    let childID = childItem.id.uuidString.lowercased()
    let alternateID = alternateItem.id.uuidString.lowercased()

    #expect(try await filtered([
        "deckId": [root.id.uuidString.lowercased()],
    ]) == [rootID])
    #expect(try await filtered([
        "deckId": [root.id.uuidString.lowercased()],
        "includeDescendants": ["true"],
    ]) == [rootID, childID])
    #expect(try await filtered([
        "itemTypeId": [otherType.id.uuidString.lowercased()],
    ]) == [alternateID])
    #expect(try await filtered(["tag": ["alpha", "beta"]]) == [rootID])
    #expect(try await filtered(["text": ["cafe"]]) == [rootID])
    #expect(try await filtered(["schedulePhase": ["new"]]) == [
        rootID, childID, alternateID,
    ])
    #expect(try await filtered([
        "dueBefore": [timestamp(base.addingTimeInterval(15))],
    ]) == [rootID, childID])
    #expect(try await filtered([
        "createdAfter": [timestamp(base.addingTimeInterval(5))],
    ]) == [childID, alternateID])
    #expect(try await filtered([
        "updatedAfter": [timestamp(base.addingTimeInterval(25))],
    ]) == [childID])
}

@Test func imageOcclusionAPIAuthorsReadsAndValidatesStructuredMasks() async throws {
    let directory = apiTestDatabaseURL().deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    let media = try MediaStore(rootDirectory: directory)
    let store = try ItemStore(databaseURL: directory.appendingPathComponent("library.sqlite"), mediaStore: media)
    try await store.bootstrap()
    let field = FieldDef(name: "Image", type: .imageOcclusion, isRequired: true)
    let type = ItemType(name: "Occlusion", fields: [field], templates: [
        Template(name: "Regions", prompt: .init(slots: [.init(source: .field(field.id))]),
                 answer: .init(slots: [.init(source: .field(field.id))]), interaction: .imageOcclusion,
                 skill: .init(input: .image, output: .freeResponse, operation: .recall)),
    ])
    _ = try await store.createItemType(type)
    let reservation = try await store.reserveMedia(data: Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), kind: .image, altText: "Diagram")
    var ref = reservation.reference
    ref.altText = nil
    var content = ImageOcclusionContent(image: ref)
    content.addMask(rect: .init(x: 0.1, y: 0.2, width: 0.3, height: 0.2))
    content.addMask(rect: .init(x: 0.5, y: 0.6, width: 0.2, height: 0.1))
    let dto = APIContentValue(.imageOcclusion(content))
    #expect(try dto.domain(pointer: "/value") == .imageOcclusion(content))
    let api = NeoAnkiAPIService(store: store, authorization: APIAuthorizationStore(persistence: InMemoryAPICredentialPersistence()), pairingApprover: ApproveAllPairings(), applicationVersion: "test")
    let token = try await pair(api, scopes: ["library.read", "items.write", "study.review"])
    let itemID = UUID().uuidString.lowercased()
    var value = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(dto)) as? [String: Any])
    #expect(value["altText"] == nil)
    let schemaResponse = await api.handle(request(.get, "/v1/openapi.json"))
    let schemaDocument = try jsonObject(schemaResponse)
    let components = try #require(schemaDocument["components"] as? [String: Any])
    let schemas = try #require(components["schemas"] as? [String: Any])
    let contentSchema = try #require(schemas["ContentValue"] as? [String: Any])
    let variants = try #require(contentSchema["oneOf"] as? [[String: Any]])
    let occlusionSchema = try #require(variants.first { variant in
        let properties = variant["properties"] as? [String: Any]
        return (properties?["type"] as? [String: Any])?["const"] as? String == "imageOcclusion"
    })
    #expect((occlusionSchema["required"] as? [String])?.contains("altText") == false)
    value["reservationId"] = reservation.reservationID.uuidString.lowercased()
    let input: [String: Any] = ["id": itemID, "itemTypeId": type.id.uuidString.lowercased(), "fields": [["fieldId": field.id.uuidString.lowercased(), "value": value]], "tags": []]
    let body = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
    let auth = ["Authorization": "Bearer \(token)"]
    let created = await api.handle(request(.post, "/v1/items", headers: auth.merging(["Idempotency-Key": UUID().uuidString]) { _, new in new }, body: body))
    #expect(created.status == 201, Comment(rawValue: String(decoding: created.body, as: UTF8.self)))
    let read = await api.handle(request(.get, "/v1/items/\(itemID)", headers: auth))
    #expect(read.status == 200)
    #expect(String(decoding: read.body, as: UTF8.self).contains("imageOcclusion"))
    let cards = await api.handle(request(.get, "/v1/cards", headers: auth))
    #expect(cards.status == 200)
    #expect(String(decoding: cards.body, as: UTF8.self).contains("occlusionGroup"))
    let due = try await store.fetchDueCards()
    #expect(due.count == 1)
    let generated = try await store.cards()
    #expect(Set(generated.compactMap(\.occlusionGroup)) == [1, 2])
    let originalCardIDs = Set(generated.map(\.id))
    content.mode = .hideOneRevealOne
    content.masks[0].rect.x = 0.2
    var replacement = input
    replacement.removeValue(forKey: "id")
    replacement["fields"] = [["fieldId": field.id.uuidString.lowercased(), "value": try JSONSerialization.jsonObject(with: JSONEncoder().encode(APIContentValue(.imageOcclusion(content))))]]
    let updated = await api.handle(request(.put, "/v1/items/\(itemID)", headers: auth.merging(["If-Match": try #require(read.headers["ETag"])]) { _, new in new }, body: String(decoding: try JSONSerialization.data(withJSONObject: replacement), as: UTF8.self)))
    #expect(updated.status == 200, Comment(rawValue: String(decoding: updated.body, as: UTF8.self)))
    #expect(Set(try await store.cards().map(\.id)) == originalCardIDs)
    content.masks[0].rect.width = 2
    let badValue = try JSONSerialization.jsonObject(with: JSONEncoder().encode(APIContentValue(.imageOcclusion(content))))
    var invalid = input
    invalid["id"] = UUID().uuidString.lowercased()
    invalid["fields"] = [["fieldId": field.id.uuidString.lowercased(), "value": badValue]]
    let rejected = await api.handle(request(.post, "/v1/items", headers: auth.merging(["Idempotency-Key": UUID().uuidString]) { _, new in new }, body: String(decoding: try JSONSerialization.data(withJSONObject: invalid), as: UTF8.self)))
    #expect(rejected.status == 422)
    #expect(try await store.listItems().count == 1)
}
