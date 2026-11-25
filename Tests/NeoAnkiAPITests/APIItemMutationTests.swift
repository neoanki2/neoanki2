import Foundation
@testable import NeoAnkiAPI
import NeoAnkiCore
import Testing

@Test func strictInputRejectsUnknownMembersUppercaseUUIDAndOversizedJSON() async throws {
    let api = try await makeAPI()
    let token = try await pair(api, scopes: ["decks.write"])
    let headers = [
        "Authorization": "Bearer \(token)",
        "Idempotency-Key": "strict",
    ]
    let unknown = await api.handle(
        request(.post, "/v1/decks", headers: headers, body: "{\"name\":\"X\",\"naem\":\"Y\"}")
    )
    #expect(unknown.status == 422)
    #expect(try jsonObject(unknown)["code"] as? String == "validation_failed")

    let uppercase = UUID().uuidString
    let invalidID = await api.handle(
        request(
            .post,
            "/v1/decks",
            headers: headers.merging(["Idempotency-Key": "uuid"]) { _, new in new },
            body: "{\"id\":\"\(uppercase)\",\"name\":\"X\"}"
        )
    )
    #expect(invalidID.status == 422)

    let oversized = await api.handle(
        APIRequest(
            method: .post,
            path: "/v1/decks",
            headers: ["Host": "127.0.0.1:8766"],
            body: Data(repeating: 0x20, count: NeoAnkiAPIService.maximumJSONBodyBytes + 1)
        )
    )
    #expect(oversized.status == 413)

    let writeToken = try await pair(api, scopes: ["items.write", "library.import"])
    let nestedItem = await api.handle(request(
        .post,
        "/v1/items",
        headers: [
            "Authorization": "Bearer \(writeToken)",
            "Idempotency-Key": "nested-item",
        ],
        body: """
        {"itemTypeId":"\(UUID().uuidString.lowercased())","deckId":null,
         "fields":[{"fieldId":"\(UUID().uuidString.lowercased())",
         "value":{"type":"text","text":"x","typo":true}}],"tags":[]}
        """
    ))
    #expect(nestedItem.status == 422)
    let itemErrors = try #require(try jsonObject(nestedItem)["errors"] as? [[String: Any]])
    #expect(itemErrors.first?["pointer"] as? String == "/fields/0/value/typo")

    let nestedManifest = await api.handle(request(
        .post,
        "/v1/imports",
        headers: ["Authorization": "Bearer \(writeToken)"],
        body: #"{"format":"json","files":[{"relativePath":"x.json","byteSize":0,"sha256":"0000000000000000000000000000000000000000000000000000000000000000","typo":true}]}"#
    ))
    #expect(nestedManifest.status == 422)
    let manifestErrors = try #require(
        try jsonObject(nestedManifest)["errors"] as? [[String: Any]]
    )
    #expect(manifestErrors.first?["pointer"] as? String == "/files/0/typo")

    let oversizedImportControl = await api.handle(APIRequest(
        method: .post,
        path: "/v1/imports/\(UUID().uuidString.lowercased())/validations",
        headers: ["Host": "127.0.0.1:8766"],
        body: Data(repeating: 0x20, count: NeoAnkiAPIService.maximumJSONBodyBytes + 1)
    ))
    #expect(oversizedImportControl.status == 413)
}

@Test func itemAndCardAuthoringRoutesPreserveIdentityAndEnforceRevisions() async throws {
    let (api, store) = try await makeAPIAndStore()
    let token = try await pair(
        api,
        scopes: ["library.read", "items.write", "study.review", "settings.write"]
    )
    let auth = ["Authorization": "Bearer \(token)"]
    let itemID = UUID().uuidString.lowercased()
    let createBody = """
        {
          "id":"\(itemID)",
          "itemTypeId":"\(BuiltInItemTypes.basicID.uuidString.lowercased())",
          "deckId":null,
          "fields":[
            {"fieldId":"\(BuiltInItemTypes.frontFieldID.uuidString.lowercased())","value":{"type":"text","text":"Front"}},
            {"fieldId":"\(BuiltInItemTypes.backFieldID.uuidString.lowercased())","value":{"type":"text","text":"Back"}}
          ],
          "tags":[" alpha ","alpha","beta"]
        }
        """
    var createHeaders = auth
    createHeaders["Idempotency-Key"] = "create-item"
    let created = await api.handle(
        request(.post, "/v1/items", headers: createHeaders, body: createBody)
    )
    let replay = await api.handle(
        request(.post, "/v1/items", headers: createHeaders, body: createBody)
    )
    #expect(created.status == 201)
    #expect(created.body == replay.body)
    #expect(try jsonObject(created)["tags"] as? [String] == ["alpha", "beta"])
    let cardIDs = try #require(try jsonObject(created)["cardIds"] as? [String])
    let cardID = try #require(cardIDs.first)

    let cards = await api.handle(request(.get, "/v1/cards", headers: auth))
    let cardData = try #require(try jsonObject(cards)["data"] as? [[String: Any]])
    #expect(cardData.map { $0["id"] as? String }.contains(cardID))
    #expect(cardData.first { $0["id"] as? String == cardID }?["maturityStatus"] as? String == "notStarted")

    let content = await api.handle(request(.get, "/v1/cards/\(cardID)/content", headers: auth))
    #expect(content.status == 200)
    #expect((try jsonObject(content)["prompt"] as? [Any])?.isEmpty == false)

    let cursorBefore = await api.handle(
        request(.get, "/v1/changes", headers: auth)
    ).body
    let preview = await api.handle(
        request(.get, "/v1/cards/\(cardID)/review-preview", headers: auth)
    )
    #expect(preview.status == 200)
    let previewRows = try #require(try JSONSerialization.jsonObject(with: preview.body) as? [[String: Any]])
    #expect(previewRows.map { $0["rating"] as? String } == ["again", "hard", "good", "easy"])
    #expect(previewRows.allSatisfy { ($0["intervalSeconds"] as? Double) != nil })
    #expect(previewRows.allSatisfy { ($0["reviewedAt"] as? String) != nil })
    #expect(previewRows.allSatisfy { ($0["rawIntervalDays"] as? Double) != nil })
    #expect(previewRows.allSatisfy { ($0["operationalIntervalSeconds"] as? Int) != nil })
    #expect(previewRows.allSatisfy { ($0["memoryBefore"] as? [String: Any]) != nil })
    #expect(previewRows.allSatisfy { ($0["memoryAfter"] as? [String: Any]) != nil })
    #expect(previewRows.allSatisfy { ($0["predictedRetrievability"] as? Double) != nil })
    #expect(previewRows.allSatisfy { ($0["modelVersion"] as? String)?.isEmpty == false })
    #expect(previewRows.allSatisfy { ($0["parameterSetId"] as? String) != nil })
    #expect(previewRows.allSatisfy { ($0["cohortId"] as? String) != nil })
    #expect(previewRows.allSatisfy {
        $0["timingPolicyVersion"] as? String == "neo-continuous-elapsed-v2"
    })
    #expect(previewRows.allSatisfy {
        $0["intervalPolicyVersion"] as? String == ($0["rating"] as? String == "again"
            ? "continuous-due-v1" : ReviewIntervalVariation.policyIdentifier)
    })

    let explanation = await api.handle(
        request(.get, "/v1/cards/\(cardID)/scheduling-explanation", headers: auth)
    )
    #expect(explanation.status == 200)
    #expect(try jsonObject(explanation)["cardId"] as? String == cardID)
    #expect(
        try jsonObject(explanation)["elapsedTimePolicy"] as? String
            == "neo-continuous-elapsed-v2"
    )
    let explanationObject = try jsonObject(explanation)
    #expect((explanationObject["ratings"] as? [[String: Any]])?.count == 4)
    #expect(explanationObject["parameterSetId"] as? String == previewRows.first?["parameterSetId"] as? String)
    #expect(explanationObject["cohortId"] as? String == previewRows.first?["cohortId"] as? String)
    #expect(explanationObject["modelIdentifier"] as? String == previewRows.first?["modelVersion"] as? String)

    let schedulingHealth = await api.handle(
        request(.get, "/v1/scheduling/health", headers: auth)
    )
    #expect(schedulingHealth.status == 200)
    #expect(try jsonObject(schedulingHealth)["desiredRetention"] as? Double == 0.9)
    #expect(try jsonObject(schedulingHealth)["parameterCount"] as? Int == 21)
    #expect((try jsonObject(schedulingHealth)["optimizerParityVerified"] as? Bool) != nil)
    #expect((try jsonObject(schedulingHealth)["optimizerStatus"] as? String)?.isEmpty == false)
    #expect((try jsonObject(schedulingHealth)["personalizationStatus"] as? String)?.isEmpty == false)
    #expect((try jsonObject(schedulingHealth)["activeParameterSetId"] as? String) != nil)
    #expect(try jsonObject(schedulingHealth)["activeParameterSource"] as? String == "populationDefault")
    #expect((try jsonObject(schedulingHealth)["legacyParametersQuarantined"] as? Bool) != nil)
    #expect(((try jsonObject(schedulingHealth)["cohortCount"] as? Int) ?? 0) >= 2)
    #expect((try jsonObject(schedulingHealth)["pendingMaintenance"] as? Bool) != nil)

    let parameterHistory = await api.handle(
        request(.get, "/v1/scheduling/parameter-sets", headers: auth)
    )
    #expect(parameterHistory.status == 200)
    let parameterRows = try #require(
        try JSONSerialization.jsonObject(with: parameterHistory.body) as? [[String: Any]]
    )
    #expect(parameterRows.isEmpty == false)
    #expect(parameterRows.allSatisfy { ($0["weights"] as? [Double])?.count == 21 })
    #expect(parameterRows.allSatisfy { ($0["cohortId"] as? String) != nil })
    #expect(parameterRows.filter { $0["isActive"] as? Bool == true }.count == 1)

    let optimizationHistory = await api.handle(
        request(.get, "/v1/scheduling/optimization-runs", headers: auth)
    )
    #expect(optimizationHistory.status == 200)
    #expect((try JSONSerialization.jsonObject(with: optimizationHistory.body) as? [Any]) != nil)

    var removedMutationHeaders = auth
    removedMutationHeaders["Idempotency-Key"] = UUID().uuidString.lowercased()
    let removedRestore = await api.handle(request(
        .post,
        "/v1/scheduling/default-restores",
        headers: removedMutationHeaders,
        body: #"{"confirm":true}"#
    ))
    #expect(removedRestore.status == 404)

    removedMutationHeaders["Idempotency-Key"] = UUID().uuidString.lowercased()
    let removedRollback = await api.handle(request(
        .post,
        "/v1/scheduling/rollbacks",
        headers: removedMutationHeaders,
        body: #"{"confirm":true}"#
    ))
    #expect(removedRollback.status == 404)
    let cursorAfter = await api.handle(
        request(.get, "/v1/changes", headers: auth)
    ).body
    #expect(cursorBefore == cursorAfter)

    var suspendHeaders = auth
    suspendHeaders["If-Match"] = content.headers["ETag"]
    let suspended = await api.handle(
        request(
            .patch,
            "/v1/cards/\(cardID)",
            headers: suspendHeaders,
            body: #"{"isSuspended":true}"#
        )
    )
    #expect(suspended.status == 200)
    #expect(try jsonObject(suspended)["isSuspended"] as? Bool == true)
    #expect(try jsonObject(suspended)["maturityStatus"] as? String == "inactive")

    let updateBody = createBody
        .replacingOccurrences(of: "\"id\":\"\(itemID)\",", with: "")
        .replacingOccurrences(of: "\"Front\"", with: "\"Updated front\"")
    var updateHeaders = auth
    updateHeaders["If-Match"] = created.headers["ETag"]
    let updated = await api.handle(
        request(.put, "/v1/items/\(itemID)", headers: updateHeaders, body: updateBody)
    )
    #expect(updated.status == 200)
    #expect(try jsonObject(updated)["cardIds"] as? [String] == cardIDs)

    let tags = await api.handle(request(.get, "/v1/tags", headers: auth))
    let tagData = try #require(try jsonObject(tags)["data"] as? [[String: Any]])
    #expect(tagData.map { $0["name"] as? String }.contains("alpha"))
    let renamed = await api.handle(
        request(
            .post,
            "/v1/tag-renames",
            headers: auth.merging(["If-Match": tags.headers["ETag"]!]) { _, new in new },
            body: #"{"from":"alpha","to":"beta"}"#
        )
    )
    #expect(renamed.status == 200)
    let afterRename = await api.handle(request(.get, "/v1/items/\(itemID)", headers: auth))
    #expect(try jsonObject(afterRename)["tags"] as? [String] == ["beta"])

    let itemBeforeTagRemoval = try await store.itemRecord(id: UUID(uuidString: itemID)!).item
    let cardBeforeTagRemoval = try await store.card(id: UUID(uuidString: cardID)!)
    let tagsAfterRename = await api.handle(request(.get, "/v1/tags", headers: auth))
    let removedTag = await api.handle(request(
        .delete,
        "/v1/tags/beta",
        headers: auth.merging([
            "If-Match": tagsAfterRename.headers["ETag"]!,
        ]) { _, new in new }
    ))
    #expect(removedTag.status == 204)
    let afterTagRemoval = await api.handle(request(
        .get, "/v1/items/\(itemID)", headers: auth
    ))
    #expect(try jsonObject(afterTagRemoval)["tags"] as? [String] == [])
    let itemAfterTagRemoval = try await store.itemRecord(id: UUID(uuidString: itemID)!).item
    let cardAfterTagRemoval = try await store.card(id: UUID(uuidString: cardID)!)
    #expect(itemAfterTagRemoval.fields == itemBeforeTagRemoval.fields)
    #expect(cardAfterTagRemoval == cardBeforeTagRemoval)

    var deleteHeaders = auth
    deleteHeaders["If-Match"] = afterTagRemoval.headers["ETag"]
    let deleted = await api.handle(
        request(.delete, "/v1/items/\(itemID)", headers: deleteHeaders)
    )
    #expect(deleted.status == 204)
    #expect(await api.handle(request(.get, "/v1/cards/\(cardID)", headers: auth)).status == 404)
}

@Test func itemValidationRejectsDuplicateFieldsWithoutWritingChanges() async throws {
    let (api, _) = try await makeAPIAndStore()
    let token = try await pair(api, scopes: ["library.read", "items.write"])
    let auth = ["Authorization": "Bearer \(token)"]
    let fieldID = BuiltInItemTypes.frontFieldID.uuidString.lowercased()
    let body = """
        {
          "itemTypeId":"\(BuiltInItemTypes.basicID.uuidString.lowercased())",
          "deckId":null,
          "fields":[
            {"fieldId":"\(fieldID)","value":{"type":"text","text":"One"}},
            {"fieldId":"\(fieldID)","value":{"type":"text","text":"Two"}}
          ],
          "tags":[]
        }
        """
    let before = await api.handle(request(.get, "/v1/changes", headers: auth))
    let invalid = await api.handle(
        request(.post, "/v1/items/validate", headers: auth, body: body)
    )
    let after = await api.handle(request(.get, "/v1/changes", headers: auth))
    #expect(invalid.status == 422)
    #expect(before.body == after.body)
}

@Test func itemTypeRoutesRequireImpactConfirmationAndPreserveStableTemplateCards() async throws {
    let (api, store) = try await makeAPIAndStore()
    let token = try await pair(
        api,
        scopes: ["library.read", "schemas.write"]
    )
    let auth = ["Authorization": "Bearer \(token)"]
    _ = try await store.itemType(id: BuiltInItemTypes.basicID)
    let duplicate = await api.handle(
        request(
            .post,
            "/v1/item-types/\(BuiltInItemTypes.basicID.uuidString.lowercased())/duplicate",
            headers: auth,
            body: #"{"name":"Impact Test"}"#
        )
    )
    #expect(duplicate.status == 201, Comment(rawValue: String(data: duplicate.body, encoding: .utf8) ?? ""))
    let duplicated = try jsonObject(duplicate)
    let typeID = try #require(duplicated["id"] as? String)
    let originalFields = try #require(duplicated["fields"] as? [[String: Any]])
    #expect(!Set(originalFields.compactMap { $0["id"] as? String }).contains(
        BuiltInItemTypes.frontFieldID.uuidString.lowercased()
    ))

    var updateObject: [String: Any] = [
        "id": typeID,
        "name": "Impact Test",
        "fields": originalFields,
        "templates": try #require(duplicated["templates"] as? [[String: Any]]),
    ]
    var templates = try #require(updateObject["templates"] as? [[String: Any]])
    var second = try #require(templates.first)
    let secondTemplateID = UUID().uuidString.lowercased()
    second["id"] = secondTemplateID
    second["name"] = "Second"
    second["fitStudyArea"] = true
    templates.append(second)
    updateObject["templates"] = templates
    let addTemplateBody = String(
        data: try JSONSerialization.data(withJSONObject: updateObject, options: [.sortedKeys]),
        encoding: .utf8
    )!
    var updateHeaders = auth
    updateHeaders["If-Match"] = duplicate.headers["ETag"]
    let added = await api.handle(
        request(.put, "/v1/item-types/\(typeID)", headers: updateHeaders, body: addTemplateBody)
    )
    #expect(added.status == 200, Comment(rawValue: String(data: added.body, encoding: .utf8) ?? ""))

    let typeUUID = try #require(UUID(uuidString: typeID))
    let domainType = try await store.itemType(id: typeUUID)
    #expect(domainType.templates.first { $0.id.uuidString.lowercased() == secondTemplateID }?.fitStudyArea == true)
    let item = Item(
        itemTypeID: typeUUID,
        fields: domainType.fields.map { field in
            FieldValue(fieldID: field.id, value: .text(field.name))
        }
    )
    let saved = try await store.createItem(item)
    #expect(saved.cardCount == 2)

    templates.removeAll { $0["id"] as? String == secondTemplateID }
    updateObject["templates"] = templates
    let removeTemplateBody = String(
        data: try JSONSerialization.data(withJSONObject: updateObject, options: [.sortedKeys]),
        encoding: .utf8
    )!
    var impactHeaders = auth
    impactHeaders["If-Match"] = added.headers["ETag"]
    let needsConfirmation = await api.handle(
        request(
            .put,
            "/v1/item-types/\(typeID)",
            headers: impactHeaders,
            body: removeTemplateBody
        )
    )
    #expect(needsConfirmation.status == 409)
    let problem = try jsonObject(needsConfirmation)
    #expect(problem["code"] as? String == "impact_confirmation_required")
    let impact = try #require(problem["impact"] as? [String: Any])
    #expect(impact["affectedCardCount"] as? Int == 1)
    impactHeaders["NeoAnki-Impact-Token"] = try #require(problem["impactToken"] as? String)
    let confirmed = await api.handle(
        request(
            .put,
            "/v1/item-types/\(typeID)",
            headers: impactHeaders,
            body: removeTemplateBody
        )
    )
    #expect(confirmed.status == 200)
    #expect(try await store.itemRecord(id: item.id).cardIDs.count == 1)

    var deleteHeaders = auth
    deleteHeaders["If-Match"] = confirmed.headers["ETag"]
    let inUse = await api.handle(
        request(.delete, "/v1/item-types/\(typeID)", headers: deleteHeaders)
    )
    #expect(inUse.status == 409)
    #expect(try jsonObject(inUse)["code"] as? String == "resource_in_use")
}

@Test func itemCreationRoundTripsEveryContentValueAndExactGeneratedCards() async throws {
    let (api, store) = try await makeAPIAndStore()
    let token = try await pair(
        api,
        scopes: ["library.read", "items.write", "media.write"]
    )
    let textField = FieldDef(name: "Text", type: .text, isRequired: true)
    let richField = FieldDef(name: "Rich", type: .richText, isRequired: true)
    let imageField = FieldDef(name: "Image", type: .image, isRequired: true)
    let clozeField = FieldDef(name: "Cloze", type: .cloze, isRequired: true)
    let numberField = FieldDef(name: "Number", type: .number, isRequired: true)
    let optionalField = FieldDef(name: "Optional", type: .text)
    let template = Template(
        name: "All values",
        prompt: Side(slots: [Slot(source: .field(textField.id))]),
        answer: Side(slots: [
            Slot(source: .field(richField.id)),
            Slot(source: .field(imageField.id)),
            Slot(source: .field(clozeField.id)),
            Slot(source: .field(numberField.id)),
        ]),
        interaction: .reveal,
        skill: Skill(input: .text, output: .text, operation: .recall)
    )
    let type = ItemType(
        name: "All API values",
        fields: [
            textField, richField, imageField, clozeField, numberField, optionalField,
        ],
        templates: [template]
    )
    _ = try await store.createItemType(type)

    let mediaBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x43])
    let upload = await api.handle(APIRequest(
        method: .post,
        path: "/v1/media",
        headers: [
            "Host": "127.0.0.1:8766",
            "Authorization": "Bearer \(token)",
            "Idempotency-Key": "all-values-media",
            "NeoAnki-Media-Kind": "image",
        ],
        body: mediaBytes
    ))
    let uploaded = try jsonObject(upload)
    let itemID = UUID().uuidString.lowercased()
    let body: [String: Any] = [
        "id": itemID,
        "itemTypeId": type.id.uuidString.lowercased(),
        "deckId": NSNull(),
        "fields": [
            [
                "fieldId": textField.id.uuidString.lowercased(),
                "value": ["type": "text", "text": "Plain", "lang": "en"],
            ],
            [
                "fieldId": richField.id.uuidString.lowercased(),
                "value": [
                    "type": "rich",
                    "spans": [["text": "Styled", "styles": ["bold", "italic"]]],
                ],
            ],
            [
                "fieldId": imageField.id.uuidString.lowercased(),
                "value": [
                    "type": "media",
                    "mediaId": UUID().uuidString.lowercased(),
                    "kind": "image",
                    "sha256": try #require(uploaded["assetHash"] as? String),
                    "fileExtension": "png",
                    "altText": "Diagram",
                    "reservationId": try #require(uploaded["reservationId"] as? String),
                ],
            ],
            [
                "fieldId": clozeField.id.uuidString.lowercased(),
                "value": [
                    "type": "cloze",
                    "text": "One two",
                    "blanks": [["group": 1, "start": 4, "length": 3, "hint": "number"]],
                ],
            ],
            [
                "fieldId": numberField.id.uuidString.lowercased(),
                "value": ["type": "number", "number": 42.5],
            ],
            [
                "fieldId": optionalField.id.uuidString.lowercased(),
                "value": ["type": "empty"],
            ],
        ],
        "tags": [" structured ", "structured"],
    ]
    let created = await api.handle(APIRequest(
        method: .post,
        path: "/v1/items",
        headers: [
            "Host": "127.0.0.1:8766",
            "Authorization": "Bearer \(token)",
            "Idempotency-Key": "all-content-values",
        ],
        body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    ))
    #expect(created.status == 201)
    let representation = try APIJSON.decoder.decode(APIItem.self, from: created.body)
    #expect(representation.id == itemID)
    #expect(representation.tags == ["structured"])
    #expect(representation.fields.map(\.value.type) == [
        "text", "rich", "media", "cloze", "number", "empty",
    ])
    let persisted = try await store.itemRecord(id: UUID(uuidString: itemID)!)
    #expect(persisted.item.fields.map(\.value) == representation.fields.map {
        try! $0.value.domain(pointer: "/value")
    })
    #expect(representation.cardIds.count == CardGenerator.cards(
        for: persisted.item,
        type: type
    ).count)
    #expect(try await store.mediaAsset(
        hash: try #require(uploaded["assetHash"] as? String)
    )?.refCount == 1)
}

@Test func bulkItemsMeetAtomicLimitDryRunAndReplayContracts() async throws {
    let (api, store) = try await makeAPIAndStore()
    let token = try await pair(api, scopes: ["library.read", "items.write"])
    let authorization = "Bearer \(token)"

    func operation(index: Int, valid: Bool = true) -> [String: Any] {
        let itemID = UUID().uuidString.lowercased()
        var fields: [[String: Any]] = [
            [
                "fieldId": BuiltInItemTypes.frontFieldID.uuidString.lowercased(),
                "value": ["type": "text", "text": "Front \(index)"],
            ],
            [
                "fieldId": BuiltInItemTypes.backFieldID.uuidString.lowercased(),
                "value": ["type": "text", "text": "Back \(index)"],
            ],
        ]
        if !valid { fields.append(fields[0]) }
        return [
            "operationId": "operation-\(index)",
            "action": "create",
            "item": [
                "id": itemID,
                "itemTypeId": BuiltInItemTypes.basicID.uuidString.lowercased(),
                "deckId": NSNull(),
                "fields": fields,
                "tags": ["bulk"],
            ],
        ]
    }

    func send(
        operations: [[String: Any]],
        dryRun: Bool,
        key: String? = nil
    ) async throws -> APIResponse {
        let body = try JSONSerialization.data(
            withJSONObject: ["atomic": true, "dryRun": dryRun, "operations": operations],
            options: [.sortedKeys]
        )
        var headers = [
            "Host": "127.0.0.1:8766",
            "Authorization": authorization,
        ]
        if let key { headers["Idempotency-Key"] = key }
        return await api.handle(APIRequest(
            method: .post,
            path: "/v1/items/bulk",
            headers: headers,
            body: body
        ))
    }

    let stableOperations = [operation(index: 1), operation(index: 2)]
    let beforeDryRun = try await store.currentChangeCursor()
    let dryRun = try await send(operations: stableOperations, dryRun: true)
    #expect(dryRun.status == 200)
    #expect(try await store.currentChangeCursor() == beforeDryRun)
    let dryResults = try #require(try jsonObject(dryRun)["results"] as? [[String: Any]])

    let committed = try await send(
        operations: stableOperations,
        dryRun: false,
        key: "stable-bulk"
    )
    let replay = try await send(
        operations: stableOperations,
        dryRun: false,
        key: "stable-bulk"
    )
    #expect(committed.status == 200)
    #expect(replay.body == committed.body)
    let committedResults = try #require(
        try jsonObject(committed)["results"] as? [[String: Any]]
    )
    #expect(dryResults.map { $0["itemId"] as? String } == committedResults.map { $0["itemId"] as? String })
    #expect(dryResults.map { $0["cardIds"] as? [String] } == committedResults.map { $0["cardIds"] as? [String] })

    let countBeforeInvalid = try await store.itemRecords().count
    let invalid = try await send(
        operations: [operation(index: 3), operation(index: 4, valid: false)],
        dryRun: false,
        key: "invalid-bulk"
    )
    #expect(invalid.status == 422)
    #expect(try await store.itemRecords().count == countBeforeInvalid)
    let invalidProblem = try jsonObject(invalid)
    #expect((invalidProblem["detail"] as? String)?.contains("operation-4") == true)
    let invalidErrors = try #require(invalidProblem["errors"] as? [[String: Any]])
    #expect(invalidErrors.first?["pointer"] as? String == "/operations/1")

    let oversized = try await send(
        operations: (0 ... 500).map { operation(index: 1_000 + $0) },
        dryRun: false,
        key: "oversized-bulk"
    )
    #expect([413, 422].contains(oversized.status))
    #expect(try await store.itemRecords().count == countBeforeInvalid)

    let fiveHundred = (0 ..< 500).map { operation(index: 10_000 + $0) }
    let cursorBeforeCommit = try await store.currentChangeCursor()
    let maximum = try await send(
        operations: fiveHundred,
        dryRun: false,
        key: "maximum-bulk"
    )
    #expect(maximum.status == 200)
    #expect(try await store.itemRecords().count == countBeforeInvalid + 500)
    let changes = try await store.libraryChanges(after: cursorBeforeCommit, limit: 1_000)
    #expect(changes.count == 1_000)
    #expect(Set(changes.map(\.transactionID)).count == 1)
}

@Test func orderedBulkRejectsStaleAndInvalidPlansAndPreservesHistory() async throws {
    let (api, store) = try await makeAPIAndStore()
    let token = try await pair(api, scopes: ["library.read", "items.write"])
    let deck = try await store.createDeck(Deck(name: "Ordered poem"))
    func value(id: UUID, front: String) -> [String: Any] {
        ["id": id.uuidString.lowercased(), "itemTypeId": BuiltInItemTypes.basicID.uuidString.lowercased(),
         "deckId": deck.id.uuidString.lowercased(), "tags": [], "fields": [
            ["fieldId": BuiltInItemTypes.frontFieldID.uuidString.lowercased(), "value": ["type": "text", "text": front]],
            ["fieldId": BuiltInItemTypes.backFieldID.uuidString.lowercased(), "value": ["type": "text", "text": "Answer"]],
         ]]
    }
    let originalID = UUID()
    let original = Item(id: originalID, itemTypeID: BuiltInItemTypes.basicID, fields: [
        .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Original")),
        .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
    ], deckID: deck.id)
    _ = try await store.createItem(original)
    let record = try await store.itemRecord(id: originalID)
    let learnedID = try #require(record.cardIDs.first)
    _ = try await store.submitReview(cardID: learnedID, rating: .good, now: .now)
    let learned = try await store.card(id: learnedID)
    let openingID = UUID()
    let operation: [String: Any] = ["operationId": "opening", "action": "create", "item": value(id: openingID, front: "Recall the first line.")]
    func send(dryRun: Bool, expected: [[String: Any]], ids: [UUID], operations: [[String: Any]] = [], key: String = "ordered-upgrade") async throws -> APIResponse {
        await api.handle(APIRequest(method: .post, path: "/v1/items/bulk", headers: [
            "Host": "127.0.0.1:8766", "Authorization": "Bearer \(token)", "Idempotency-Key": key,
        ], body: try JSONSerialization.data(withJSONObject: [
            "atomic": true, "dryRun": dryRun, "operations": operations.isEmpty ? [operation] : operations,
            "order": ["deckId": deck.id.uuidString.lowercased(), "expectedItems": expected,
                      "orderedItemIds": ids.map { $0.uuidString.lowercased() }],
        ], options: [.sortedKeys])))
    }
    let expected = [value(id: originalID, front: "Original")]
    let cursor = try await store.currentChangeCursor()
    let orderedDryRun = try await send(dryRun: true, expected: expected, ids: [openingID, originalID])
    #expect(orderedDryRun.status == 200, "\(String(decoding: orderedDryRun.body, as: UTF8.self))")
    #expect(try await store.currentChangeCursor() == cursor)
    #expect(try await store.itemRecords().count == 1)
    #expect(try await send(dryRun: true, expected: expected, ids: [openingID, originalID, originalID]).status == 422)
    #expect(try await send(dryRun: true, expected: expected, ids: [originalID]).status == 422)
    for dry in [true, false] {
        let stale = try await send(dryRun: dry, expected: [value(id: originalID, front: "Stale")], ids: [openingID, originalID], key: "stale-\(dry)")
        #expect(stale.status == 409)
        #expect(try jsonObject(stale)["code"] as? String == "ordered_deck_conflict")
        #expect(try await store.itemRecords().count == 1)
    }
    // A late invalid member prevents all changes, including the opener.
    var invalid = value(id: UUID(), front: "Invalid")
    invalid["fields"] = []
    let rejected = try await send(dryRun: false, expected: expected, ids: [openingID, originalID], operations: [operation,
        ["operationId": "invalid", "action": "create", "item": invalid],
    ], key: "invalid-ordered")
    #expect(rejected.status == 422)
    #expect(try await store.itemRecords().count == 1)
    let committed = try await send(dryRun: false, expected: expected, ids: [openingID, originalID])
    #expect(committed.status == 200)
    let replay = try await send(dryRun: false, expected: expected, ids: [openingID, originalID])
    #expect(replay.body == committed.body)
    let final = try await store.itemRecordsPage(offset: 0, limit: 200)
    #expect(final.map { $0.item.id } == [openingID, originalID])
    #expect(final.last?.createdAt == record.createdAt)
    #expect(try await store.card(id: learnedID) == learned)
    #expect(try await store.reviewLogCount(for: learnedID) == 1)
    let openapi = await api.handle(.init(method: .get, path: "/v1/openapi.json", headers: ["Host": "127.0.0.1:8766"]))
    let document = try jsonObject(openapi)
    let components = try #require(document["components"] as? [String: Any])
    let schemas = try #require(components["schemas"] as? [String: Any])
    #expect(schemas["OrderedItemsInput"] != nil)
}

@Test func itemTypeScopeRoutesKeepDeckDefinitionsOutOfGlobalAuthoring() async throws {
    let (api, store) = try await makeAPIAndStore()
    let deck = try await store.createDeck(Deck(name: "Human Body"))
    let type = try await store.createItemType(BuiltInItemTypes.basic.duplicated(name: "Organ"), deckID: deck.id, availableEverywhere: false)
    let token = try await pair(api, scopes: ["library.read", "schemas.write"])
    let headers = ["Authorization": "Bearer \(token)"]
    let global = await api.handle(request(.get, "/v1/item-types", headers: headers))
    #expect(global.status == 200)
    let globalRows = try #require(try jsonObject(global)["data"] as? [[String: Any]])
    #expect(!globalRows.contains { $0["name"] as? String == "Organ" })
    let scoped = await api.handle(APIRequest(method: .get, path: "/v1/item-types", query: ["deckId": [deck.id.uuidString.lowercased()]], headers: headers.merging(["Host": "127.0.0.1:8766"]) { _, new in new }))
    #expect(scoped.status == 200)
    let scopedRows = try #require(try jsonObject(scoped)["data"] as? [[String: Any]])
    #expect(scopedRows.map { $0["name"] as? String } == ["Organ"])
    let override = await api.handle(request(.put, "/v1/decks/\(deck.id.uuidString.lowercased())/item-type-policy", headers: headers,
        body: """
        {"inherits":false,"itemTypeIds":["\(type.id.uuidString.lowercased())"],"defaultItemTypeId":"\(type.id.uuidString.lowercased())"}
        """))
    #expect(override.status == 200)
    #expect(try await store.authoringItemTypes(for: deck.id).defaultItemTypeID == type.id)
    let share = await api.handle(request(.put, "/v1/item-types/\(type.id.uuidString.lowercased())/availability", headers: headers,
        body: "{\"availableEverywhere\":true}"))
    #expect(share.status == 200)
    #expect(try await store.authoringItemTypes(for: nil).itemTypes.contains { $0.id == type.id })
    let empty = await api.handle(request(.put, "/v1/decks/\(deck.id.uuidString.lowercased())/item-type-policy", headers: headers,
        body: "{\"inherits\":false,\"itemTypeIds\":[]}"))
    #expect(empty.status == 200)
    #expect(try await store.authoringItemTypes(for: deck.id).usesSharedFallback)
}
