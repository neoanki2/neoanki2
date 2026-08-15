import Foundation

package enum APIOpenAPI {
    package static let document: Data = {
        let publicSecurity: [[String: [String]]] = []
        var paths: [String: Any] = [:]

        func group(for path: String) -> APIEndpointGroup {
            if ["/health", "/v1/meta", "/v1/openapi.json"].contains(path) {
                return .discovery
            }
            if path == "/v1/pairings" || path.hasPrefix("/v1/clients/") {
                return .authentication
            }
            if path.hasPrefix("/v1/deck") { return .decks }
            if path.hasPrefix("/v1/item-types") { return .itemTypes }
            if path.hasPrefix("/v1/items") || path.hasPrefix("/v1/tags")
                || path == "/v1/tag-renames"
            {
                return .items
            }
            if path.hasPrefix("/v1/cards") || path.hasPrefix("/v1/study-sessions")
                || path.hasPrefix("/v1/reviews")
            {
                return .study
            }
            if path.hasPrefix("/v1/scheduling") { return .scheduling }
            if path.hasPrefix("/v1/study-responses") || path.hasPrefix("/v1/media") {
                return .responses
            }
            if path.hasPrefix("/v1/vocabulary") { return .vocabulary }
            if path.hasPrefix("/v1/imports") || path.hasPrefix("/v1/exports") {
                return .transfers
            }
            return .events
        }

        func summary(for operationID: String) -> String {
            var words = ""
            for character in operationID {
                if character.isUppercase, !words.isEmpty { words.append(" ") }
                words.append(character.lowercased())
            }
            return words.prefix(1).uppercased() + words.dropFirst()
        }

        func parameterDescription(_ name: String, location: String) -> String {
            switch (location, name) {
            case ("path", "id"): "Resource identifier."
            case ("path", "fileId"): "Staged file identifier."
            case ("path", "reviewLogId"): "Review-log identifier."
            case ("path", "sha256"): "Lowercase SHA-256 content digest."
            case ("query", "cursor"): "Opaque cursor returned by the preceding page."
            case ("query", "limit"): "Maximum number of results to return."
            case ("query", "after"): "Return durable changes after this cursor."
            case ("query", "query"): "Search text."
            default: "The \(name) \(location) parameter."
            }
        }

        func add(
            _ path: String,
            _ method: APIHTTPMethod,
            _ handler: APIEndpointHandler,
            authorization: APIEndpointAuthorization = .publicAccess,
            success: Int = 200,
            request: String? = nil,
            response: String? = "Resource",
            requestContentType: String = "application/json",
            responseContentType: String = "application/json",
            query: [String] = [],
            requiredQuery: Set<String> = [],
            successHeaders: [String: Any] = [:]
        ) {
            let operationID = handler.rawValue
            let methodName = method.rawValue.lowercased()
            let scope = authorization.requiredScope
            let isProtectedMutation = authorization.isProtected
                && [.post, .put, .patch, .delete].contains(method)
            var operationResponses = responses(
                success: success,
                schema: response,
                contentType: responseContentType
            )
            var responseHeaders = successHeaders
            if isProtectedMutation {
                responseHeaders["X-NeoAnki-Change-Cursor"] = [
                    "description": "Last durable cursor when the operation committed library changes.",
                    "required": false,
                    "schema": ["type": "integer", "minimum": 1],
                ]
            }
            if !responseHeaders.isEmpty,
               var successResponse = operationResponses[String(success)] as? [String: Any]
            {
                successResponse["headers"] = responseHeaders
                operationResponses[String(success)] = successResponse
            }
            var operation: [String: Any] = [
                "operationId": operationID,
                "summary": summary(for: operationID),
                "description": "\(summary(for: operationID)) through the loopback-only NeoAnki API.",
                "tags": [group(for: path).rawValue],
                "responses": operationResponses,
                "security": scope == nil ? publicSecurity : [["bearerAuth": []]],
                "x-codeSamples": [[
                    "lang": "Shell",
                    "label": "curl",
                    "source": "curl --request \(method.rawValue) http://127.0.0.1:8766\(path)",
                ]],
            ]
            if let scope { operation["x-required-scope"] = scope }
            if let request {
                operation["requestBody"] = [
                    "required": true,
                    "description": "Request payload for \(summary(for: operationID).lowercased()).",
                    "content": [requestContentType: ["schema": reference(request)]],
                ]
            }
            let names = path.split(separator: "{").dropFirst().compactMap {
                $0.split(separator: "}").first.map(String.init)
            }
            var parameters: [[String: Any]] = names.map { name in
                    let schema: [String: Any]
                    switch name {
                    case "id" where path.contains("/vocabulary-packs/"):
                        schema = ["type": "string", "minLength": 1, "maxLength": 65_536]
                    case "entryId":
                        schema = ["type": "string", "minLength": 1, "maxLength": 65_536]
                    case "id", "fileId", "reviewLogId":
                        schema = [
                            "type": "string", "format": "uuid",
                            "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                        ]
                    case "sha256":
                        schema = ["type": "string", "pattern": "^[0-9a-f]{64}$"]
                    default:
                        schema = ["type": "string"]
                    }
                    return [
                        "name": name, "in": "path", "required": true,
                        "description": parameterDescription(name, location: "path"),
                        "schema": schema,
                    ] as [String: Any]
                }
            parameters += query.map { name in
                var schema: [String: Any] = ["type": "string"]
                if name == "limit" {
                    schema = [
                        "type": "integer", "minimum": 1,
                        "maximum": path == "/v1/changes" ? 1_000
                            : path.contains("/vocabulary-packs/{id}/entries") ? 500 : 200,
                    ]
                }
                if name == "mode" {
                    schema = ["type": "string", "enum": ["exact", "prefix"]]
                }
                if ["query", "language", "path"].contains(name) {
                    schema["minLength"] = 1
                    schema["maxLength"] = 65_536
                }
                if ["includeDescendants", "isSuspended"].contains(name) {
                    schema = ["type": "boolean"]
                }
                return [
                    "name": name, "in": "query",
                    "description": parameterDescription(name, location: "query"),
                    "required": requiredQuery.contains(name), "schema": schema,
                ]
            }
            if isProtectedMutation {
                let required = [
                    "POST /v1/items", "POST /v1/items/bulk", "POST /v1/reviews",
                    "POST /v1/media", "POST /v1/cards/{id}/resets",
                    "DELETE /v1/study-responses/{id}",
                    "POST /v1/deck-deletion-plans/{id}/commits",
                    "POST /v1/deck-reset-plans/{id}/commits",
                    "POST /v1/imports/{id}/commits",
                    "POST /v1/vocabulary-pack-imports/{id}/commits",
                ].contains("\(method.rawValue) \(path)")
                parameters.append([
                    "name": "Idempotency-Key", "in": "header", "required": required,
                    "description": "Caller-generated key used to replay a mutation safely.",
                    "schema": ["type": "string", "minLength": 1, "maxLength": 256],
                ])
            }
            let needsIfMatch = scope != nil && (
                [.put, .patch, .delete].contains(method)
                    || path.hasSuffix("/resets")
                    || path.hasSuffix("/commits")
                    || path == "/v1/tag-renames"
                    || path.hasSuffix("/reverts")
            )
            if needsIfMatch {
                parameters.append([
                    "name": "If-Match", "in": "header", "required": true,
                    "description": "Current quoted resource revision.",
                    "schema": ["type": "string", "pattern": "^\\\"revision-[0-9]+\\\"$"],
                ])
            }
            if path == "/v1/item-types/{id}", method == .put {
                parameters.append([
                    "name": "NeoAnki-Impact-Token", "in": "header", "required": false,
                    "description": "Confirmation token returned after inspecting a destructive schema edit.",
                    "schema": ["type": "string"],
                ])
            }
            if path == "/v1/media", method == .post {
                parameters += [
                    ["name": "NeoAnki-Media-Kind", "in": "header", "required": true,
                     "description": "Declared kind of the uploaded media.",
                     "schema": ["type": "string", "enum": ["audio", "image", "gif", "video"]]],
                    ["name": "NeoAnki-Alt-Text", "in": "header", "required": false,
                     "description": "Accessible description stored with the media.",
                     "schema": ["type": "string"]],
                ]
            }
            if path == "/v1/events" {
                parameters.append([
                    "name": "Last-Event-ID", "in": "header", "required": false,
                    "description": "Last durable event cursor received by an SSE client.",
                    "schema": ["type": "integer", "minimum": 0],
                ])
            }
            if !parameters.isEmpty {
                operation["parameters"] = parameters
            }
            var pathItem = paths[path] as? [String: Any] ?? [:]
            pathItem[methodName] = operation
            paths[path] = pathItem
        }

        let vocabularyETagHeader: [String: Any] = [
            "description": "Current immutable pack or import-job revision.",
            "required": true,
            "schema": ["type": "string", "pattern": "^\\\"revision-[0-9]+\\\"$"],
        ]
        let vocabularyLocationHeader: [String: Any] = [
            "description": "Canonical relative URL of the created job or installed pack.",
            "required": true,
            "schema": ["type": "string"],
        ]
        let vocabularyMediaHeaders: [String: Any] = [
            "Content-Length": [
                "description": "Validated media byte count.", "required": true,
                "schema": ["type": "integer", "minimum": 0],
            ],
            "Digest": [
                "description": "Validated vocabulary manifest SHA-256 digest.", "required": true,
                "schema": ["type": "string", "pattern": "^sha-256=[0-9a-f]{64}$"],
            ],
            "Accept-Ranges": [
                "description": "Vocabulary media is not range-addressable.", "required": true,
                "schema": ["type": "string", "const": "none"],
            ],
        ]
        let contractHeaders: [String: Any] = [
            "ETag": [
                "description": "Strong validator derived from the exact OpenAPI bytes.",
                "required": true,
                "schema": ["type": "string"],
            ],
            "X-NeoAnki-Contract-Digest": [
                "description": "SHA-256 digest shared by runtime and published API artifacts.",
                "required": true,
                "schema": ["type": "string", "pattern": "^sha256:[0-9a-f]{64}$"],
            ],
        ]

        add("/health", .get, .health, success: 200, response: "Health")
        add("/v1/meta", .get, .meta, response: "Meta")
        add(
            "/v1/openapi.json", .get, .openapi,
            response: "OpenAPIDocument", successHeaders: contractHeaders
        )
        add("/v1/pairings", .post, .pair, success: 201, request: "PairingInput", response: "PairingResult")
        add("/v1/clients/current", .get, .currentClient, authorization: .authenticated, response: "Client")
        add("/v1/clients/current", .delete, .revokeCurrentClient, authorization: .authenticated, success: 204, response: nil)

        add("/v1/decks", .get, .listDecks, authorization: .scope(.libraryRead), response: "DeckCollection", query: ["cursor", "limit"])
        add("/v1/decks", .post, .createDeck, authorization: .scope(.decksWrite), success: 201, request: "CreateDeckInput", response: "Deck")
        add("/v1/decks/{id}", .get, .getDeck, authorization: .scope(.libraryRead), response: "Deck")
        add("/v1/decks/{id}", .patch, .updateDeck, authorization: .scope(.decksWrite), request: "UpdateDeckInput", response: "Deck")
        add("/v1/deck-deletion-plans", .post, .createDeckDeletionPlan, authorization: .scope(.decksWrite), success: 201, request: "CreateDeckDeletionPlanInput", response: "DeckDeletionPlan")
        add("/v1/deck-deletion-plans/{id}/commits", .post, .commitDeckDeletionPlan, authorization: .scope(.decksWrite), request: "ConfirmInput", response: "DeckDeletionCommitResult")
        add("/v1/deck-reset-plans", .post, .createDeckResetPlan, authorization: .scope(.studyReview), success: 201, request: "DeckIdentifierInput", response: "DeckResetPlan")
        add("/v1/deck-reset-plans/{id}/commits", .post, .commitDeckResetPlan, authorization: .scope(.studyReview), request: "RequiredConfirmInput", response: "DeckResetCommitResult")
        add("/v1/decks/{id}/item-type-policy", .get, .deckItemTypePolicy, authorization: .scope(.libraryRead), response: "ItemTypePolicy")

        add("/v1/item-types", .get, .listItemTypes, authorization: .scope(.libraryRead), response: "ItemTypeCollection", query: ["cursor", "limit"])
        add("/v1/item-types", .post, .createItemType, authorization: .scope(.schemasWrite), success: 201, request: "ItemTypeInput", response: "ItemType")
        add("/v1/item-types/validate", .post, .validateItemType, authorization: .scope(.schemasWrite), success: 204, request: "ItemTypeInput", response: nil)
        add("/v1/item-types/{id}", .get, .getItemType, authorization: .scope(.libraryRead), response: "ItemType")
        add("/v1/item-types/{id}", .put, .replaceItemType, authorization: .scope(.schemasWrite), request: "ItemTypeInput", response: "ItemType")
        add("/v1/item-types/{id}", .delete, .deleteItemType, authorization: .scope(.schemasWrite), success: 204, response: nil)
        add("/v1/item-types/{id}/duplicate", .post, .duplicateItemType, authorization: .scope(.schemasWrite), success: 201, request: "DuplicateItemTypeInput", response: "ItemType")

        add("/v1/items", .get, .listItems, authorization: .scope(.libraryRead), response: "ItemCollection", query: ["cursor", "limit", "deckId", "includeDescendants", "itemTypeId", "tag", "text", "schedulePhase", "dueBefore", "createdAfter", "updatedAfter"])
        add("/v1/items", .post, .createItem, authorization: .scope(.itemsWrite), success: 201, request: "CreateItemInput", response: "Item")
        add("/v1/items/validate", .post, .validateItem, authorization: .scope(.itemsWrite), success: 204, request: "CreateItemInput", response: nil)
        add("/v1/items/bulk", .post, .bulkItems, authorization: .scope(.itemsWrite), request: "BulkItemsInput", response: "BulkItemsResult")
        add("/v1/items/{id}", .get, .getItem, authorization: .scope(.libraryRead), response: "Item")
        add("/v1/items/{id}", .put, .replaceItem, authorization: .scope(.itemsWrite), request: "ReplaceItemInput", response: "Item")
        add("/v1/items/{id}", .delete, .deleteItem, authorization: .scope(.itemsWrite), success: 204, response: nil)
        add("/v1/items/{id}/duplicate-checks", .post, .duplicateChecks, authorization: .scope(.libraryRead), request: "EmptyObject", response: "DuplicateCheckResult")
        add("/v1/tags", .get, .listTags, authorization: .scope(.libraryRead), response: "TagCollection", query: ["cursor", "limit"])
        add("/v1/tag-renames", .post, .renameTag, authorization: .scope(.itemsWrite), request: "RenameTagInput", response: "MutationCount")
        add("/v1/tags/{encodedTag}", .delete, .removeTag, authorization: .scope(.itemsWrite), success: 204, response: nil)

        add("/v1/cards", .get, .listCards, authorization: .scope(.libraryRead), response: "CardCollection", query: ["cursor", "limit", "itemId", "deckId", "includeDescendants", "templateId", "phase", "isSuspended", "dueBefore"])
        add("/v1/cards/{id}", .get, .getCard, authorization: .scope(.libraryRead), response: "Card")
        add("/v1/cards/{id}", .patch, .patchCard, authorization: .scope(.studyReview), request: "PatchCardInput", response: "Card")
        add("/v1/cards/{id}/content", .get, .cardContent, authorization: .scope(.libraryRead), response: "StudyCard")
        add("/v1/cards/{id}/review-preview", .get, .reviewPreview, authorization: .scope(.libraryRead), response: "RatingPreviewArray")
        add("/v1/cards/{id}/scheduling-explanation", .get, .schedulingExplanation, authorization: .scope(.libraryRead), response: "SchedulingExplanation")
        add("/v1/cards/{id}/resets", .post, .resetCard, authorization: .scope(.studyReview), request: "RequiredConfirmInput", response: "Card")
        add("/v1/scheduling/health", .get, .schedulingHealth, authorization: .scope(.libraryRead), response: "SchedulingHealth")
        add("/v1/scheduling/parameter-sets", .get, .listSchedulingParameterSets, authorization: .scope(.libraryRead), response: "FSRSParameterSetArray")
        add("/v1/scheduling/optimization-runs", .get, .listSchedulingOptimizationRuns, authorization: .scope(.libraryRead), response: "FSRSOptimizationRunArray", query: ["limit"])
        add("/v1/scheduling/default-restores", .post, .restoreDefaultScheduling, authorization: .scope(.settingsWrite), request: "RequiredConfirmInput", response: "SchedulingHealth")
        add("/v1/scheduling/rollbacks", .post, .rollbackScheduling, authorization: .scope(.settingsWrite), request: "SchedulingRollbackInput", response: "SchedulingHealth")

        add("/v1/study-sessions", .post, .createStudySession, authorization: .scope(.studyReview), success: 201, request: "CreateStudySessionInput", response: "StudySession")
        add("/v1/study-sessions/{id}", .get, .getStudySession, authorization: .scope(.studyReview), response: "StudySession")
        add("/v1/study-sessions/{id}", .delete, .endStudySession, authorization: .scope(.studyReview), success: 204, response: nil)
        add("/v1/study-sessions/{id}/next", .post, .nextStudyCard, authorization: .scope(.studyReview), response: "StudyCard")
        add("/v1/study-sessions/{id}/skips", .post, .skipStudyCard, authorization: .scope(.studyReview), success: 204, request: "SkipStudyCardInput", response: nil)
        add("/v1/reviews", .post, .submitReview, authorization: .scope(.studyReview), success: 201, request: "SubmitReviewInput", response: "ReviewResult")
        add("/v1/reviews/{reviewLogId}/reverts", .post, .revertReview, authorization: .scope(.studyReview), success: 204, response: nil)

        add("/v1/study-responses", .get, .listStudyResponses, authorization: .scope(.studyResponsesRead), response: "StudyResponseCollection", query: ["cursor", "limit", "cardId", "itemId", "tag", "createdAfter"])
        add("/v1/study-responses/{id}", .get, .getStudyResponse, authorization: .scope(.studyResponsesRead), response: "StudyResponse")
        add("/v1/study-responses/{id}", .delete, .deleteStudyResponse, authorization: .scope(.studyResponsesDelete), success: 204, response: nil)
        add("/v1/study-responses/{id}/content", .get, .downloadStudyResponse, authorization: .scope(.studyResponsesRead), response: "Binary", responseContentType: "audio/mp4")
        add("/v1/study-responses/{id}/content", .head, .headStudyResponse, authorization: .scope(.studyResponsesRead), response: nil, responseContentType: "audio/mp4")

        add("/v1/media", .post, .uploadMedia, authorization: .scope(.mediaWrite), success: 201, request: "Binary", response: "MediaReservation", requestContentType: "application/octet-stream")
        add("/v1/media/{sha256}", .head, .headMedia, authorization: .scope(.libraryRead), response: nil, responseContentType: "application/octet-stream")
        add("/v1/media/{sha256}", .get, .downloadMedia, authorization: .scope(.libraryRead), response: "Binary", responseContentType: "application/octet-stream")
        add("/v1/media/{sha256}/metadata", .get, .mediaMetadata, authorization: .scope(.libraryRead), response: "MediaMetadata")

        add("/v1/vocabulary-packs", .get, .listVocabularyPacks, authorization: .scope(.vocabularyRead), response: "VocabularyPackCollection")
        add("/v1/vocabulary-packs/{id}", .get, .getVocabularyPack, authorization: .scope(.vocabularyRead), response: "VocabularyPack", successHeaders: ["ETag": vocabularyETagHeader])
        add("/v1/vocabulary-packs/{id}", .delete, .deleteVocabularyPack, authorization: .scope(.vocabularyWrite), success: 204, response: nil)
        add("/v1/vocabulary-packs/{id}/entries", .get, .searchVocabularyEntries, authorization: .scope(.vocabularyRead), response: "LexicalEntryCollection", query: ["query", "mode", "limit", "language"], requiredQuery: ["query"])
        add("/v1/vocabulary-packs/{id}/entries/{entryId}", .get, .getVocabularyEntry, authorization: .scope(.vocabularyRead), response: "LexicalEntry")
        add("/v1/vocabulary-packs/{id}/media", .get, .downloadVocabularyMedia, authorization: .scope(.vocabularyRead), response: "Binary", responseContentType: "application/octet-stream", query: ["path"], requiredQuery: ["path"], successHeaders: vocabularyMediaHeaders)
        add("/v1/vocabulary-packs/{id}/media", .head, .headVocabularyMedia, authorization: .scope(.vocabularyRead), response: nil, responseContentType: "application/octet-stream", query: ["path"], requiredQuery: ["path"], successHeaders: vocabularyMediaHeaders)

        add("/v1/vocabulary-pack-imports", .post, .createVocabularyPackImport, authorization: .scope(.vocabularyWrite), success: 201, request: "CreateVocabularyPackImportInput", response: "VocabularyPackImport", successHeaders: ["ETag": vocabularyETagHeader, "Location": vocabularyLocationHeader])
        add("/v1/vocabulary-pack-imports/{id}", .get, .getVocabularyPackImport, authorization: .scope(.vocabularyWrite), response: "VocabularyPackImport", successHeaders: ["ETag": vocabularyETagHeader])
        add("/v1/vocabulary-pack-imports/{id}", .delete, .deleteVocabularyPackImport, authorization: .scope(.vocabularyWrite), success: 204, response: nil)
        add("/v1/vocabulary-pack-imports/{id}/files/{fileId}", .put, .uploadVocabularyPackFile, authorization: .scope(.vocabularyWrite), request: "Binary", response: "VocabularyPackImport", requestContentType: "application/octet-stream", successHeaders: ["ETag": vocabularyETagHeader])
        add("/v1/vocabulary-pack-imports/{id}/validations", .post, .validateVocabularyPackImport, authorization: .scope(.vocabularyWrite), response: "VocabularyPackImport", successHeaders: ["ETag": vocabularyETagHeader])
        add("/v1/vocabulary-pack-imports/{id}/commits", .post, .commitVocabularyPackImport, authorization: .scope(.vocabularyWrite), response: "VocabularyPackImport", successHeaders: ["ETag": vocabularyETagHeader, "Location": vocabularyLocationHeader])

        add("/v1/imports", .post, .createImport, authorization: .scope(.libraryImport), success: 201, request: "CreateImportInput", response: "ImportJob")
        add("/v1/imports/{id}", .get, .getImport, authorization: .scope(.libraryImport), response: "ImportJob")
        add("/v1/imports/{id}", .delete, .deleteImport, authorization: .scope(.libraryImport), success: 204, response: nil)
        add("/v1/imports/{id}/files/{fileId}", .put, .uploadImportFile, authorization: .scope(.libraryImport), success: 204, request: "Binary", response: nil, requestContentType: "application/octet-stream")
        add("/v1/imports/{id}/validations", .post, .validateImport, authorization: .scope(.libraryImport), response: "ImportJob")
        add("/v1/imports/{id}/commits", .post, .commitImport, authorization: .scope(.libraryImport), request: "CommitImportInput", response: "ImportJob")
        add("/v1/exports", .post, .createExport, authorization: .scope(.libraryExport), success: 201, request: "CreateExportInput", response: "ExportJob")
        add("/v1/exports/{id}", .get, .getExport, authorization: .scope(.libraryExport), response: "ExportJob")
        add("/v1/exports/{id}", .delete, .deleteExport, authorization: .scope(.libraryExport), success: 204, response: nil)
        add("/v1/exports/{id}/content", .get, .exportContent, authorization: .scope(.libraryExport), response: "Binary", responseContentType: "application/vnd.neoanki.portable-deck")

        add("/v1/changes", .get, .changes, authorization: .anyOf([.libraryRead, .studyResponsesRead]), response: "ChangeCollection", query: ["after", "limit"])
        add("/v1/events", .get, .events, authorization: .anyOf([.libraryRead, .studyResponsesRead]), response: "EventStream", responseContentType: "text/event-stream", query: ["after"])

        let document: [String: Any] = [
            "openapi": "3.1.0",
            "info": [
                "title": "NeoAnki Local Automation API",
                "version": "1.0.0",
                "description": "Loopback-only local automation API. It is not a synchronization or remote-access protocol.",
            ],
            "servers": [["url": "http://127.0.0.1:8766"]],
            "security": [["bearerAuth": []]],
            "paths": paths,
            "components": [
                "securitySchemes": [
                    "bearerAuth": ["type": "http", "scheme": "bearer", "bearerFormat": "opaque"],
                ],
                "schemas": schemas,
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    }()

    package static let contractDigest = "sha256:" + APICrypto.sha256Hex(document)

    package static let endpoints: [APIEndpointDefinition] = {
        guard
            let object = try? JSONSerialization.jsonObject(with: document) as? [String: Any],
            let paths = object["paths"] as? [String: Any]
        else {
            preconditionFailure("The generated OpenAPI document must contain paths.")
        }

        func referencedSchema(_ value: Any?) -> String? {
            guard let dictionary = value as? [String: Any],
                  let reference = dictionary["$ref"] as? String
            else { return nil }
            return reference.split(separator: "/").last.map(String.init)
        }

        var result: [APIEndpointDefinition] = []
        for (path, rawPathItem) in paths {
            guard let pathItem = rawPathItem as? [String: Any] else { continue }
            for (methodName, rawOperation) in pathItem {
                guard let method = APIHTTPMethod(rawValue: methodName.uppercased()),
                      let operation = rawOperation as? [String: Any],
                      let operationID = operation["operationId"] as? String,
                      let handler = APIEndpointHandler(rawValue: operationID),
                      let tags = operation["tags"] as? [String],
                      let groupName = tags.first,
                      let group = APIEndpointGroup(rawValue: groupName),
                      let summary = operation["summary"] as? String,
                      let description = operation["description"] as? String,
                      let responses = operation["responses"] as? [String: Any],
                      let successStatus = responses.keys.compactMap(Int.init)
                        .filter({ (200 ..< 300).contains($0) }).sorted().first
                else {
                    preconditionFailure("Every OpenAPI operation must have typed registry metadata.")
                }
                let parameters = (operation["parameters"] as? [[String: Any]] ?? []).compactMap {
                    parameter -> APIEndpointParameter? in
                    guard let name = parameter["name"] as? String,
                          let location = parameter["in"] as? String
                    else { return nil }
                    return APIEndpointParameter(
                        name: name,
                        location: location,
                        isRequired: parameter["required"] as? Bool ?? false,
                        description: parameter["description"] as? String ?? ""
                    )
                }
                let requestBody = operation["requestBody"] as? [String: Any]
                let requestContent = requestBody?["content"] as? [String: Any]
                let requestMedia = requestContent?.values.first as? [String: Any]
                let successResponse = responses[String(successStatus)] as? [String: Any]
                let responseContent = successResponse?["content"] as? [String: Any]
                let responseMedia = responseContent?.values.first as? [String: Any]
                let successHeaders = (successResponse?["headers"] as? [String: Any])?.keys
                    .sorted() ?? []
                let errorResponses = responses.keys.filter {
                    $0 == "default" || Int($0).map { !(200 ..< 300).contains($0) } == true
                }.sorted()
                result.append(APIEndpointDefinition(
                    pathTemplate: path,
                    method: method,
                    handler: handler,
                    group: group,
                    summary: summary,
                    description: description,
                    requiredScope: operation["x-required-scope"] as? String,
                    parameters: parameters,
                    acceptsRequestBody: requestBody != nil,
                    successStatus: successStatus,
                    requestSchema: referencedSchema(requestMedia?["schema"]),
                    responseSchema: referencedSchema(responseMedia?["schema"]),
                    successHeaders: successHeaders,
                    errorResponses: errorResponses
                ))
            }
        }
        return result.sorted {
            if $0.pathTemplate != $1.pathTemplate { return $0.pathTemplate < $1.pathTemplate }
            return $0.method.rawValue < $1.method.rawValue
        }
    }()

    package static func endpoint(
        for requestPath: String,
        method: APIHTTPMethod
    ) -> APIEndpointDefinition? {
        endpoints.first { $0.method == method && $0.matches(path: requestPath) }
    }

    /// Resolves a concrete request path against the paths declared by the
    /// shipped contract. Browser preflight uses this rather than a second,
    /// independently maintained route list.
    static func documentedMethods(for requestPath: String) -> Set<APIHTTPMethod> {
        Set(endpoints.lazy.filter { $0.matches(path: requestPath) }.map(\.method))
    }

    static func documentedQueryParameters(
        for requestPath: String,
        method: APIHTTPMethod
    ) -> Set<String> {
        endpoint(for: requestPath, method: method)?.queryParameters ?? []
    }

    static func acceptsRequestBody(
        for requestPath: String,
        method: APIHTTPMethod
    ) -> Bool {
        endpoint(for: requestPath, method: method)?.acceptsRequestBody ?? false
    }

    private static func reference(_ name: String) -> [String: Any] {
        ["$ref": "#/components/schemas/\(name)"]
    }

    private static func responses(
        success: Int,
        schema: String?,
        contentType: String
    ) -> [String: Any] {
        var successResponse: [String: Any] = ["description": "Success"]
        if let schema {
            successResponse["content"] = [contentType: ["schema": reference(schema)]]
        }
        return [
            String(success): successResponse,
            "default": [
                "description": "Problem details",
                "content": ["application/problem+json": ["schema": reference("Problem")]],
            ],
        ]
    }

    private static var schemas: [String: Any] {
        let uuid: [String: Any] = [
            "type": "string", "format": "uuid",
            "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
        ]
        let nullableUUID: [String: Any] = ["oneOf": [uuid, ["type": "null"]]]
        let timestamp: [String: Any] = ["type": "string", "format": "date-time"]
        let nonnegative: [String: Any] = ["type": "integer", "minimum": 0]
        let revision: [String: Any] = ["type": "integer", "minimum": 1]
        let sha256: [String: Any] = ["type": "string", "pattern": "^[0-9a-f]{64}$"]
        func object(_ required: [String], _ properties: [String: Any]) -> [String: Any] {
            [
                "type": "object", "additionalProperties": false,
                "required": required, "properties": properties,
            ]
        }
        func array(_ schema: [String: Any], min: Int? = nil, max: Int? = nil) -> [String: Any] {
            var result: [String: Any] = ["type": "array", "items": schema]
            if let min { result["minItems"] = min }
            if let max { result["maxItems"] = max }
            return result
        }
        func collection(_ resource: String) -> [String: Any] {
            object(["data", "page"], [
                "data": array(reference(resource)),
                "page": reference("PageInfo"),
            ])
        }
        let scope = [
            "type": "string",
            "enum": [
                "library.read", "items.write", "decks.write", "schemas.write",
                "study.review", "study.responses.read", "study.responses.delete",
                "media.write", "library.import", "library.export",
                "vocabulary.read", "vocabulary.write",
                "settings.write", "ui.control",
            ],
        ] as [String: Any]
        let contentValue: [String: Any] = [
            "oneOf": [
                object(["type"], ["type": ["type": "string", "const": "empty"]]),
                object(["type", "text"], [
                    "type": ["type": "string", "const": "text"],
                    "text": ["type": "string"], "lang": ["type": "string"],
                ]),
                object(["type", "spans"], [
                    "type": ["type": "string", "const": "rich"],
                    "spans": array(reference("RichSpan")),
                ]),
                object(["type", "mediaId", "kind", "sha256", "fileExtension"], [
                    "type": ["type": "string", "const": "media"],
                    "mediaId": uuid,
                    "kind": ["type": "string", "enum": ["audio", "image", "gif", "video"]],
                    "sha256": sha256, "fileExtension": ["type": "string"],
                    "durationMs": nonnegative, "altText": ["type": "string"],
                    "reservationId": uuid,
                ]),
                object(["type", "text", "blanks"], [
                    "type": ["type": "string", "const": "cloze"],
                    "text": ["type": "string"], "blanks": array(reference("ClozeSpan"), min: 1),
                ]),
                object(["type", "number"], [
                    "type": ["type": "string", "const": "number"],
                    "number": ["type": "number"],
                ]),
            ],
        ]
        let itemInputProperties: [String: Any] = [
            "id": uuid, "itemTypeId": uuid, "deckId": nullableUUID,
            "fields": array(reference("FieldValue")),
            "tags": ["type": "array", "maxItems": 256, "uniqueItems": true,
                     "items": ["type": "string", "minLength": 1, "maxLength": 1024]],
        ]
        let itemTypeInputProperties: [String: Any] = [
            "id": uuid, "name": ["type": "string", "minLength": 1],
            "fields": array(reference("FieldDefinition"), min: 1),
            "templates": array(reference("TemplateDefinition"), min: 1),
        ]

        return [
            "Binary": ["type": "string", "contentMediaType": "application/octet-stream"],
            "OpenAPIDocument": ["type": "object", "additionalProperties": true],
            "EventStream": ["type": "string"],
            "EmptyObject": object([], [:]),
            "PageInfo": object(["limit"], [
                "nextCursor": ["type": ["string", "null"]],
                "limit": ["type": "integer", "minimum": 1, "maximum": 200],
            ]),
            "Health": object(["status"], ["status": ["type": "string", "const": "ok"]]),
            "Meta": object(
                ["apiVersion", "applicationVersion", "serverInstanceId", "pairingAvailable", "capabilities"],
                [
                    "apiVersion": ["type": "integer", "const": 1],
                    "applicationVersion": ["type": "string"], "serverInstanceId": uuid,
                    "pairingAvailable": ["type": "boolean"],
                    "capabilities": array(["type": "string"]),
                ]
            ),
            "PairingInput": object(["displayName", "requestedScopes"], [
                "displayName": ["type": "string", "minLength": 1, "maxLength": 256],
                "requestedScopes": ["type": "array", "items": scope, "minItems": 1,
                                    "uniqueItems": true],
                "origin": ["type": ["string", "null"]],
            ]),
            "PairingResult": object(["client", "token"], [
                "client": reference("Client"), "token": ["type": "string", "minLength": 43],
            ]),
            "Client": object(["id", "displayName", "scopes", "createdAt", "revision"], [
                "id": uuid, "displayName": ["type": "string"],
                "origin": ["type": ["string", "null"]], "scopes": array(scope, min: 1),
                "createdAt": timestamp, "revision": revision,
            ]),
            "VocabularyProvenance": object(["sourceId"], [
                "sourceId": ["type": "string"],
                "sourceName": ["type": ["string", "null"]],
                "recordId": ["type": ["string", "null"]],
                "attribution": ["type": ["string", "null"]],
                "license": ["type": ["string", "null"]],
                "sourceUrl": ["type": ["string", "null"]],
            ]),
            "VocabularyPack": object([
                "id", "revision", "title", "languages", "capabilities", "entryCount",
                "databaseSha256", "mediaFileCount", "mediaByteCount",
            ], [
                "id": ["type": "string", "minLength": 1, "maxLength": 65_536],
                "revision": ["type": "integer", "const": 1],
                "title": ["type": "string"], "summary": ["type": ["string", "null"]],
                "languages": array(["type": "string"]),
                "capabilities": array(["type": "string", "enum": [
                    "lexicon", "pronunciation", "morphology", "corpus", "frequency",
                ]]),
                "provenance": ["oneOf": [reference("VocabularyProvenance"), ["type": "null"]]],
                "entryCount": nonnegative, "databaseSha256": sha256,
                "mediaFileCount": nonnegative, "mediaByteCount": nonnegative,
            ]),
            "VocabularyPackCollection": object(["data"], [
                "data": array(reference("VocabularyPack"), max: 1_000),
            ]),
            "LocalizedVocabularyText": object(["value"], [
                "value": ["type": "string"], "language": ["type": ["string", "null"]],
            ]),
            "LexicalEntry": [
                "type": "object", "additionalProperties": false,
                "required": ["id", "language", "canonicalForm", "forms", "pronunciations", "senses"],
                "properties": [
                    "id": ["type": "string"], "language": ["type": "string"],
                    "canonicalForm": ["type": "object", "additionalProperties": true],
                    "forms": array(["type": "object", "additionalProperties": true]),
                    "pronunciations": array(["type": "object", "additionalProperties": true]),
                    "senses": array(["type": "object", "additionalProperties": true]),
                    "frequency": ["type": ["number", "null"]],
                    "provenance": ["oneOf": [reference("VocabularyProvenance"), ["type": "null"]]],
                ],
            ],
            "LexicalEntryCollection": object(["data"], [
                "data": array(reference("LexicalEntry"), max: 500),
            ]),
            "VocabularyPackImportFileInput": object(["id", "path", "byteSize", "sha256"], [
                "id": uuid, "path": ["type": "string", "minLength": 1, "maxLength": 65_536],
                "byteSize": [
                    "type": "integer", "minimum": 0,
                    "maximum": APIVocabularyLibrary.maximumFileBytes,
                ],
                "sha256": sha256,
            ]),
            "CreateVocabularyPackImportInput": object(["files"], [
                "files": array(reference("VocabularyPackImportFileInput"), min: 2, max: 100_002),
            ]),
            "VocabularyPackImportFile": object(["id", "path", "byteSize", "sha256", "uploaded"], [
                "id": uuid, "path": ["type": "string"], "byteSize": nonnegative,
                "sha256": sha256, "uploaded": ["type": "boolean"],
            ]),
            "VocabularyPackImport": object([
                "id", "revision", "state", "files", "createdAt", "updatedAt",
            ], [
                "id": uuid, "revision": revision,
                "state": ["type": "string", "enum": ["awaitingFiles", "ready", "validated", "completed"]],
                "files": array(reference("VocabularyPackImportFile"), min: 2, max: 100_002),
                "pack": ["oneOf": [reference("VocabularyPack"), ["type": "null"]]],
                "createdAt": timestamp, "updatedAt": timestamp,
            ]),
            "CreateDeckInput": object(["name"], [
                "id": uuid, "name": ["type": "string", "minLength": 1],
                "parentId": nullableUUID,
                "newCardsPerDay": ["type": ["integer", "null"], "minimum": 0],
            ]),
            "UpdateDeckInput": object([], [
                "name": ["type": "string", "minLength": 1], "parentId": nullableUUID,
                "newCardsPerDay": ["type": ["integer", "null"], "minimum": 0],
            ]),
            "Deck": object(
                ["id", "revision", "name", "directItemCount",
                 "recursiveItemCount", "dueCount", "childIds"],
                [
                    "id": uuid, "revision": revision, "name": ["type": "string"],
                    "parentId": nullableUUID,
                    "newCardsPerDay": ["type": ["integer", "null"], "minimum": 0],
                    "directItemCount": nonnegative, "recursiveItemCount": nonnegative,
                    "dueCount": nonnegative, "childIds": array(uuid),
                ]
            ),
            "DeckCollection": collection("Deck"),
            "DeckIdentifierInput": object(["deckId"], ["deckId": uuid]),
            "ConfirmInput": object([], ["confirm": ["type": "boolean"]]),
            "RequiredConfirmInput": object(["confirm"], ["confirm": ["type": "boolean"]]),
            "CreateDeckDeletionPlanInput": object(["deckId", "policy"], [
                "deckId": uuid,
                "policy": ["type": "string", "enum": ["rejectIfNonempty", "unassignItems",
                                                             "moveItemsToParent", "deleteSubtreeAndItems"]],
            ]),
            "DeckDeletionImpact": object(
                ["deckCount", "itemCount", "cardCount", "reviewLogCount", "mediaReferenceCount", "studyResponseCount"],
                ["deckCount": nonnegative, "itemCount": nonnegative, "cardCount": nonnegative,
                 "reviewLogCount": nonnegative, "mediaReferenceCount": nonnegative,
                 "studyResponseCount": nonnegative]
            ),
            "DeckResetImpact": object(["deckCount", "cardCount", "reviewLogCount"], [
                "deckCount": nonnegative, "cardCount": nonnegative, "reviewLogCount": nonnegative,
            ]),
            "DeckDeletionPlan": object(
                ["id", "revision", "deckId", "policy", "impact", "deckRevision", "dependencyChangeCursor", "expiresAt"],
                ["id": uuid, "revision": revision, "deckId": uuid,
                 "policy": ["type": "string", "enum": ["rejectIfNonempty", "unassignItems",
                                                            "moveItemsToParent", "deleteSubtreeAndItems"]],
                 "impact": reference("DeckDeletionImpact"), "deckRevision": revision,
                 "dependencyChangeCursor": nonnegative,
                 "expiresAt": timestamp]
            ),
            "DeckResetPlan": object(
                ["id", "revision", "deckId", "impact", "deckRevision", "dependencyChangeCursor", "expiresAt"],
                ["id": uuid, "revision": revision, "deckId": uuid, "impact": reference("DeckResetImpact"),
                 "deckRevision": revision, "dependencyChangeCursor": nonnegative, "expiresAt": timestamp]
            ),
            "DeckDeletionCommitResult": object(["planId", "committed", "impact"], [
                "planId": uuid, "committed": ["type": "boolean"],
                "impact": reference("DeckDeletionImpact"),
            ]),
            "DeckResetCommitResult": object(["planId", "committed", "impact"], [
                "planId": uuid, "committed": ["type": "boolean"],
                "impact": reference("DeckResetImpact"),
            ]),
            "FieldDefinition": object(["id", "name", "type", "isRequired"], [
                "id": uuid, "name": ["type": "string"],
                "type": ["type": "string", "enum": ["text", "richText", "audio", "image",
                                                          "gif", "video", "number", "cloze"]],
                "isRequired": ["type": "boolean"],
            ]),
            "Skill": object(["input", "output", "operation"], [
                "input": ["type": "string"], "output": ["type": "string"],
                "operation": ["type": "string"],
            ]),
            "SlotSource": object(["kind"], [
                "kind": ["type": "string", "enum": ["field", "literal"]],
                "fieldId": uuid, "text": ["type": "string"],
            ]),
            "Presentation": object(["reveal", "media"], [
                "reveal": ["type": "string", "enum": ["always", "hiddenUntilAnswer", "blurred"]],
                "media": ["type": "string", "enum": ["default", "autoplay", "playOnTap", "loop"]],
            ]),
            "Slot": object(["source", "presentation"], [
                "source": reference("SlotSource"), "presentation": reference("Presentation"),
            ]),
            "Condition": object(["kind"], [
                "kind": ["type": "string", "enum": ["fieldNotEmpty", "fieldEmpty", "all", "any"]],
                "fieldId": uuid, "conditions": array(reference("Condition")),
            ]),
            "TemplateDefinition": object(
                ["id", "name", "prompt", "answer", "interaction", "skill"],
                ["id": uuid, "name": ["type": "string"], "prompt": array(reference("Slot")),
                 "answer": array(reference("Slot")),
                 "interaction": ["type": "string", "enum": ["reveal", "type", "choose", "record", "audioSubmission", "cloze", "arrange"]],
                 "skill": reference("Skill"), "generateWhen": reference("Condition")]
            ),
            "ItemTypeInput": object(["name", "fields", "templates"], itemTypeInputProperties),
            "DuplicateItemTypeInput": object(["name"], ["name": ["type": "string", "minLength": 1]]),
            "ItemType": object(
                ["id", "revision", "name", "fields", "templates", "provenance", "itemCount"],
                itemTypeInputProperties.merging([
                    "revision": revision, "provenance": ["type": "string"], "itemCount": nonnegative,
                ]) { _, new in new }
            ),
            "ItemTypeCollection": collection("ItemType"),
            "ItemTypePolicy": object(["sourceDeckId", "defaultItemTypeId", "itemTypeIds"], [
                "sourceDeckId": nullableUUID, "defaultItemTypeId": nullableUUID,
                "itemTypeIds": array(uuid),
            ]),
            "RichSpan": object(["text", "styles"], [
                "text": ["type": "string"],
                "styles": ["type": "array", "uniqueItems": true,
                           "items": ["type": "string", "enum": ["bold", "italic", "underline",
                               "strikethrough", "highlight", "code", "superscript", "subscript"]]],
                "textColor": ["type": "string"], "textSize": ["type": "string", "enum": ["small", "large"]],
                "link": ["type": "string", "format": "uri"],
            ]),
            "ClozeSpan": object(["group", "start", "length"], [
                "group": ["type": "integer"], "start": nonnegative, "length": nonnegative,
                "hint": ["type": "string"],
            ]),
            "ContentValue": contentValue,
            "FieldValue": object(["fieldId", "value"], [
                "fieldId": uuid, "value": reference("ContentValue"),
            ]),
            "CreateItemInput": object(["itemTypeId", "fields", "tags"], itemInputProperties),
            "ReplaceItemInput": object(["itemTypeId", "deckId", "fields", "tags"], itemInputProperties),
            "Item": object(
                ["id", "revision", "itemTypeId", "fields", "tags", "createdAt", "updatedAt", "cardIds"],
                itemInputProperties.merging([
                    "revision": revision, "createdAt": timestamp, "updatedAt": timestamp,
                    "cardIds": array(uuid),
                ]) { _, new in new }
            ),
            "ItemCollection": collection("Item"),
            "BulkItemOperation": object(["operationId", "action"], [
                "operationId": ["type": "string"],
                "action": ["type": "string", "enum": ["create", "replace", "delete"]],
                "item": reference("CreateItemInput"), "itemId": uuid,
            ]),
            "BulkItemsInput": object(["atomic", "dryRun", "operations"], [
                "atomic": ["type": "boolean", "const": true], "dryRun": ["type": "boolean"],
                "operations": array(reference("BulkItemOperation"), min: 1, max: 500),
            ]),
            "BulkItemsResult": object(["dryRun", "results", "impact"], [
                "dryRun": ["type": "boolean"], "results": array(reference("BulkItemResult")),
                "impact": reference("BulkItemImpact"),
            ]),
            "BulkItemResult": object(["operationId", "action", "itemId", "cardIds"], [
                "operationId": ["type": "string"], "action": ["type": "string"],
                "itemId": uuid, "cardIds": array(uuid),
            ]),
            "BulkItemImpact": object(
                ["createdItemCount", "replacedItemCount", "deletedItemCount", "resultingCardCount"],
                ["createdItemCount": nonnegative, "replacedItemCount": nonnegative,
                 "deletedItemCount": nonnegative, "resultingCardCount": nonnegative]
            ),
            "DuplicateCheckResult": object(["candidates"], [
                "candidates": array(reference("DuplicateCandidate")),
            ]),
            "DuplicateCandidate": object(["itemId", "reasonCodes"], [
                "itemId": uuid, "reasonCodes": array(["type": "string"]),
            ]),
            "Tag": object(["name", "itemCount", "revision"], [
                "name": ["type": "string"], "itemCount": nonnegative, "revision": revision,
            ]),
            "TagCollection": collection("Tag"),
            "RenameTagInput": object(["from", "to"], ["from": ["type": "string"], "to": ["type": "string"]]),
            "MutationCount": object(["updatedItemCount"], ["updatedItemCount": nonnegative]),
            "Memory": object(
                ["stabilityDays", "difficulty", "dueAt", "repetitions", "lapses", "phase"],
                ["stabilityDays": ["type": "number"], "difficulty": ["type": "number"],
                 "dueAt": timestamp, "lastReviewedAt": ["oneOf": [timestamp, ["type": "null"]]],
                 "repetitions": nonnegative, "lapses": nonnegative, "phase": ["type": "string"],
                 "stepIndex": ["type": ["integer", "null"]]]
            ),
            "Card": object(
                ["id", "revision", "itemId", "templateId", "skill", "isSuspended", "memory"],
                ["id": uuid, "revision": revision, "itemId": uuid, "templateId": uuid,
                 "deckId": nullableUUID, "clozeGroup": ["type": ["integer", "null"]],
                 "skill": reference("Skill"), "isSuspended": ["type": "boolean"],
                 "memory": reference("Memory")]
            ),
            "CardCollection": collection("Card"),
            "PatchCardInput": object(["isSuspended"], ["isSuspended": ["type": "boolean"]]),
            "ResolvedSlot": object(["value", "presentation"], [
                "value": reference("ContentValue"), "presentation": reference("Presentation"),
            ]),
            "StudyCard": object(
                ["id", "revision", "itemId", "templateId", "interaction", "prompt", "answer", "memory"],
                ["id": uuid, "revision": revision, "itemId": uuid, "templateId": uuid,
                 "deckId": nullableUUID, "clozeGroup": ["type": ["integer", "null"]],
                 "interaction": ["type": "string"], "prompt": array(reference("ResolvedSlot")),
                 "answer": array(reference("ResolvedSlot")), "memory": reference("Memory")]
            ),
            "RatingPreviewArray": array(reference("RatingPreview")),
            "RatingPreview": object(["rating", "reviewedAt", "intervalSeconds", "rawIntervalDays", "operationalIntervalSeconds", "memoryBefore", "memoryAfter", "memory", "predictedRetrievability", "modelVersion", "timingPolicyVersion", "intervalPolicyVersion", "finalDueAt"], [
                "rating": ["type": "string", "enum": ["again", "hard", "good", "easy"]],
                "reviewedAt": timestamp,
                "intervalSeconds": ["type": "number", "minimum": 0],
                "rawIntervalDays": ["type": "number", "minimum": 0],
                "operationalIntervalSeconds": nonnegative,
                "memoryBefore": reference("Memory"),
                "memoryAfter": reference("Memory"),
                "memory": reference("Memory"),
                "predictedRetrievability": ["type": "number", "minimum": 0, "maximum": 1],
                "presetId": nullableUUID, "parameterSetId": nullableUUID,
                "modelVersion": ["type": "string"],
                "timingPolicyVersion": ["type": "string"],
                "intervalPolicyVersion": ["type": "string"],
                "finalDueAt": timestamp,
                "constraintReason": ["type": ["string", "null"]],
            ]),
            "SchedulingExplanation": object(
                ["cardId", "reviewedAt", "elapsedSeconds", "elapsedModelDays", "previousMemory", "desiredRetention", "modelIdentifier", "elapsedTimePolicy", "intervalPolicy", "ratings"],
                ["cardId": uuid, "reviewedAt": timestamp,
                 "elapsedSeconds": ["type": "number", "minimum": 0],
                 "elapsedModelDays": nonnegative, "previousMemory": reference("Memory"),
                 "desiredRetention": ["type": "number", "minimum": 0, "maximum": 1],
                 "modelIdentifier": ["type": "string"], "elapsedTimePolicy": ["type": "string"],
                 "intervalPolicy": ["type": "string"], "presetId": nullableUUID,
                 "parameterSetId": nullableUUID, "ratings": reference("RatingPreviewArray")]
            ),
            "SchedulingHealth": object(
                ["modelIdentifier", "desiredRetention", "maximumIntervalDays", "automaticOptimizationEnabled", "parameterCount", "parameterSource", "optimizerParityVerified", "optimizerStatus", "personalizationStatus", "legacyParametersQuarantined", "canRestoreDefaults", "canRollback"],
                ["modelIdentifier": ["type": "string"],
                 "desiredRetention": ["type": "number", "minimum": 0, "maximum": 1],
                 "maximumIntervalDays": nonnegative, "automaticOptimizationEnabled": ["type": "boolean"],
                 "parameterCount": nonnegative,
                 "parameterSource": ["type": "string", "enum": ["populationDefaults", "personalized"]],
                 "activeParameterSetId": nullableUUID,
                 "activeParameterSource": ["type": ["string", "null"], "enum": ["populationDefault", "optimized", "imported", "legacyQuarantine", NSNull()]],
                 "optimizerParityVerified": ["type": "boolean"],
                 "optimizerStatus": ["type": "string", "enum": ["parityVerificationPending", "notRun", "promoted", "held", "rejected", "notEnoughData", "failed"]],
                 "personalizationStatus": ["type": "string", "enum": ["populationDefaults", "personalized", "unavailablePendingVerification"]],
                 "lastOptimizationDecision": ["type": ["string", "null"]],
                 "lastOptimizationReason": ["type": ["string", "null"]],
                 "lastOptimizationCompletedAt": ["oneOf": [timestamp, ["type": "null"]]],
                 "migrationStatus": ["type": ["string", "null"]],
                 "legacyParametersQuarantined": ["type": "boolean"],
                 "canRestoreDefaults": ["type": "boolean"], "canRollback": ["type": "boolean"]]
            ),
            "FSRSParameterSetArray": array(reference("FSRSParameterSet")),
            "FSRSParameterSet": object(
                ["id", "isActive", "weights", "modelVersion", "upstreamCommit", "sourceChecksum", "scope", "source", "metrics", "createdAt"],
                ["id": uuid, "isActive": ["type": "boolean"], "weights": array(["type": "number"]),
                 "modelVersion": ["type": "string"], "upstreamCommit": ["type": "string"],
                 "sourceChecksum": ["type": "string"], "fixtureChecksum": ["type": ["string", "null"]],
                 "scope": ["type": "string"],
                 "source": ["type": "string", "enum": ["populationDefault", "optimized", "imported", "legacyQuarantine"]],
                 "inputFingerprint": ["type": ["string", "null"]],
                 "trainingCutoff": ["oneOf": [timestamp, ["type": "null"]]],
                 "metrics": ["type": "object", "additionalProperties": ["type": "number"]],
                 "previousParameterSetId": nullableUUID, "createdAt": timestamp]
            ),
            "FSRSOptimizationRunArray": array(reference("FSRSOptimizationRun")),
            "FSRSOptimizationRun": object(
                ["id", "presetId", "startedAt", "completedAt", "trainingCutoff", "inputFingerprint", "eligibleTargetCount", "distinctCardCount", "failureCount", "studyDayCount", "excludedCounts", "foldCount", "metrics", "decision"],
                ["id": uuid, "presetId": uuid, "startedAt": timestamp, "completedAt": timestamp,
                 "trainingCutoff": timestamp, "inputFingerprint": ["type": "string"],
                 "eligibleTargetCount": nonnegative, "distinctCardCount": nonnegative,
                 "failureCount": nonnegative, "studyDayCount": nonnegative,
                 "excludedCounts": ["type": "object", "additionalProperties": nonnegative],
                 "foldCount": nonnegative,
                 "metrics": ["type": "object", "additionalProperties": ["type": "number"]],
                 "decision": ["type": "string", "enum": ["promoted", "held", "rejected", "notEnoughData", "failed"]],
                 "reason": ["type": ["string", "null"]], "candidateParameterSetId": nullableUUID]
            ),
            "SchedulingRollbackInput": object(["confirm"], [
                "confirm": ["type": "boolean"], "parameterSetId": nullableUUID,
            ]),
            "StudyScope": object(["kind"], [
                "kind": ["type": "string", "enum": ["allDecks", "unassigned", "deck"]],
                "deckId": uuid, "includeDescendants": ["type": "boolean"],
            ]),
            "CreateStudySessionInput": object(["scope"], ["scope": reference("StudyScope")]),
            "StudySession": object(
                ["id", "revision", "scope", "state", "createdAt", "lastActivityAt"],
                ["id": uuid, "revision": revision, "scope": reference("StudyScope"),
                 "state": ["type": "string"], "currentCardId": nullableUUID,
                 "createdAt": timestamp, "lastActivityAt": timestamp]
            ),
            "SkipStudyCardInput": object(["cardId"], ["cardId": uuid]),
            "SubmitReviewInput": object(["sessionId", "cardId", "rating", "durationMs"], [
                "sessionId": uuid, "cardId": uuid,
                "rating": ["type": "string", "enum": ["again", "hard", "good", "easy"]],
                "durationMs": nonnegative,
            ]),
            "ReviewResult": object(
                ["reviewLogId", "revision", "previousPhase", "resultingPhase", "memory", "changeCursor"],
                ["reviewLogId": uuid, "revision": revision, "previousPhase": ["type": "string"],
                 "resultingPhase": ["type": "string"], "memory": reference("Memory"),
                 "changeCursor": nonnegative]
            ),
            "StudyResponse": object(
                ["id", "revision", "cardId", "itemId", "assetHash", "contentType", "fileExtension", "byteSize", "durationMs", "capturedAt", "submittedAt", "sourceTitle"],
                ["id": uuid, "revision": revision, "cardId": uuid, "itemId": uuid,
                 "assetHash": sha256, "contentType": ["type": "string", "const": "audio/mp4"],
                 "fileExtension": ["type": "string", "const": "m4a"], "byteSize": nonnegative,
                 "durationMs": ["type": "integer", "minimum": 1, "maximum": 1_800_000],
                 "capturedAt": timestamp, "submittedAt": timestamp, "sourceTitle": ["type": "string"]]
            ),
            "StudyResponseCollection": collection("StudyResponse"),
            "MediaReservation": object(
                ["assetHash", "kind", "fileExtension", "byteSize", "reservationId", "reservationExpiresAt"],
                ["assetHash": sha256, "kind": ["type": "string", "enum": ["audio", "image", "gif", "video"]],
                 "fileExtension": ["type": "string"], "byteSize": nonnegative,
                 "reservationId": uuid, "reservationExpiresAt": timestamp]
            ),
            "MediaMetadata": object(
                ["assetHash", "kind", "fileExtension", "byteSize", "referenceCount"],
                ["assetHash": sha256, "kind": ["type": "string"], "fileExtension": ["type": "string"],
                 "byteSize": nonnegative, "referenceCount": nonnegative]
            ),
            "ImportFileDeclaration": object(["relativePath", "byteSize", "sha256"], [
                "relativePath": ["type": "string"], "byteSize": nonnegative, "sha256": sha256,
            ]),
            "CreateImportInput": object(["format", "files"], [
                "format": ["type": "string", "enum": ["json", "csv", "authoredDeck", "portableDeck"]],
                "itemTypeId": uuid, "csvItemTypeName": ["type": "string"],
                "destinationDeckId": uuid, "files": array(reference("ImportFileDeclaration"), min: 1),
            ]),
            "ImportFile": object(["id", "relativePath", "byteSize", "sha256", "uploaded"], [
                "id": uuid, "relativePath": ["type": "string"], "byteSize": nonnegative,
                "sha256": sha256, "uploaded": ["type": "boolean"],
            ]),
            "TransferReport": object(
                ["itemCount", "deckCount", "createdItemTypeCount", "reusedItemTypeCount", "warnings"],
                ["itemCount": nonnegative, "deckCount": nonnegative,
                 "createdItemTypeCount": nonnegative, "reusedItemTypeCount": nonnegative,
                 "warnings": array(["type": "string"])]
            ),
            "ImportJob": object(
                ["id", "revision", "format", "state", "files", "createdAt", "updatedAt"],
                ["id": uuid, "revision": revision, "format": ["type": "string"],
                 "state": ["type": "string"], "files": array(reference("ImportFile")),
                 "report": ["oneOf": [reference("TransferReport"), ["type": "null"]]],
                 "planToken": ["type": ["string", "null"]], "createdAt": timestamp, "updatedAt": timestamp]
            ),
            "CommitImportInput": object(["planToken"], ["planToken": ["type": "string"]]),
            "CreateExportInput": object(["format", "deckId"], [
                "format": ["type": "string", "const": "portableDeck"], "deckId": uuid,
            ]),
            "ExportJob": object(
                ["id", "revision", "format", "deckId", "state", "createdAt", "updatedAt"],
                ["id": uuid, "revision": revision, "format": ["type": "string", "const": "portableDeck"],
                 "deckId": uuid, "state": ["type": "string"],
                 "byteSize": ["type": ["integer", "null"], "minimum": 0],
                 "sha256": ["oneOf": [sha256, ["type": "null"]]],
                 "createdAt": timestamp, "updatedAt": timestamp]
            ),
            "Change": object(
                ["cursor", "transactionId", "sequence", "type", "resourceType", "resourceId", "revision", "tombstone", "occurredAt"],
                ["cursor": nonnegative, "transactionId": uuid, "sequence": nonnegative,
                 "type": ["type": "string"], "resourceType": ["type": "string"],
                 "resourceId": ["type": "string"], "revision": revision,
                 "tombstone": ["type": "boolean"], "occurredAt": timestamp]
            ),
            "ChangeCollection": collection("Change"),
            "ValidationError": object(["pointer", "code"], [
                "pointer": ["type": "string"], "code": ["type": "string"],
            ]),
            "ImpactSummary": object(
                ["affectedItemCount", "affectedCardCount", "affectedStudyResponseCount"],
                ["affectedItemCount": nonnegative, "affectedCardCount": nonnegative,
                 "affectedStudyResponseCount": nonnegative]
            ),
            "Problem": object(
                ["type", "title", "status", "code", "detail", "requestId"],
                ["type": ["type": "string", "format": "uri"], "title": ["type": "string"],
                 "status": ["type": "integer", "minimum": 400, "maximum": 599],
                 "code": ["type": "string"], "detail": ["type": "string"],
                 "requestId": uuid, "errors": array(reference("ValidationError")),
                 "requiredScope": ["type": "string"],
                 "impact": reference("ImpactSummary"),
                 "impactToken": ["type": "string"]]
            ),
        ]
    }
}
